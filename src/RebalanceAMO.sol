// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./interfaces/IAdapter.sol";
import "./interfaces/IOracle.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";

contract RebalanceAMO is Ownable2Step {
    using SafeERC20 for IERC20;
    // === MANAGEMENT ===
    address public manager;
    address public securityManager;
    address public profitManager;
    uint256 public paused; // 0 for not paused, 1 for paused
    uint256 public coolDown = 600; // At least 10 minutes between two manager functions
    uint256 public lastCallSwap = 0;
    uint256 public lastCallLiquidity = 0;
    
    constructor() Ownable(msg.sender) {}

    modifier onlyManager {
        require(msg.sender == manager || msg.sender == owner(), "AMO: Not Manager");
        _;
    }

    modifier onlySecurityManager {
        require(msg.sender == securityManager || msg.sender == manager || msg.sender == owner(), "AMO: Not Security Manager"); // Changed PSM to AMO for consistency
        _;
    }

    modifier onlySwapCoolDown {
        require(block.timestamp >= lastCallSwap + coolDown, "AMO: swap Cooling Down");
        _;
        lastCallSwap = block.timestamp;
    }

    modifier onlyLiquidityCoolDown {
        require(block.timestamp >= lastCallLiquidity + coolDown, "AMO: liquidity Cooling Down");
        _;
        lastCallLiquidity = block.timestamp;
    }

    modifier whenNotPaused {
        require(paused == 0, "AMO: Paused");
        _;
    }

    function pause() external onlySecurityManager {
        require(paused == 0, "AMO: Already paused");
        paused = 1;
        emit Paused();
    }

    function unpause() external onlyOwner {
        require(paused == 1, "AMO: Already unpaused");
        paused = 0;
        emit Unpaused();
    }

    function configSecurity(address _manager, address _securityManager, address _profitManager, uint256 _coolDown, uint256 _buySlippage, uint256 _sellSlippage) external onlyOwner {
        require(_manager != address(0) && _securityManager != address(0) && _profitManager != address(0), "AMO: Zero address"); // Added zero address checks
        require(_coolDown > 60, "AMO: Invalid cooldown"); // Added validation
        require(_buySlippage <= ONE && _sellSlippage <= ONE, "AMO: Invalid slippage"); // Added slippage validation
        manager = _manager;
        securityManager = _securityManager;
        profitManager = _profitManager;
        coolDown = _coolDown;
        buySlippage = _buySlippage;
        sellSlippage = _sellSlippage;
    }

    // === TOKENS ===
    address public pegCoin; // atToken
    address public stableCoin; // The stable coin that forms the pair with our token
    address public adapter; // the dex adapter implementing our interface
    address public oracle; // the oracle to read the price between pegCoin and stableCoin
    // @audit: one-shot address configuration
    bool _addressConfiged;

    function configAddress(address _pegCoin, address _stableCoin, address _adapter, address _oracle) external onlyOwner {
        // @audit: one-shot address configuration
        require(!_addressConfiged, "Address already configured");
        _addressConfiged = true;
        require(_pegCoin != address(0) && _stableCoin != address(0) && _adapter != address(0), "AMO: Zero address"); // Added zero address checks
        pegCoin = _pegCoin;
        stableCoin = _stableCoin;
        adapter = _adapter;
        oracle = _oracle; // Oracle can be zero address
    }

    // === SLIPPAGE CONTROL === 
    uint256 immutable public ONE = 1e18;
    uint256 public buySlippage = 1e18 * 997 / 1000; // 0.3%
    uint256 public sellSlippage = 1e18 * 997 / 1000; // 0.3%

    // === EVENTS ===
    event PegCoinBought(uint256 amountStable, uint256 amountPeg);
    event PegCoinSold(uint256 amountPeg, uint256 amountStable);
    event LiquidityAdded(uint256 amountPeg, uint256 amountStable, uint256 amountLP);
    event LiquidityRemoved(uint256 amountLP, uint256 amountPeg, uint256 amountStable);
    event RewardsCollected(address to);
    event Paused();
    event Unpaused();

    // === MAIN FUNCTIONS ===
    function buyPegCoinAMO(
        uint256 _amountStable, // The amount of stableCoin to sell
        uint256 _minPegCoin // The minimum amount of pegCoin to receive
    ) external onlyManager onlySwapCoolDown whenNotPaused {
        address _adapter = adapter; address _stableCoin = stableCoin; address _pegCoin = pegCoin; // cache
        { // input verifications, use curly braces to limit the scope of the variables and avoid stack-too-deep error
        require(_amountStable > 0, "AMO: Amount must be positive");
        // This price is only for slippage check, it is okay to be inaccurate
        // `1e18` amount of pegCoin = `price` amount of stablecoin, we already consider decimals in getPrice
        // e.g., if the decimals of stablecoin is 18, then price = 1e18; if the decimals of stablecoin is 6, then price = 1e6
        uint price = getPrice();
        uint outputAmountAtExpectedPrice = _amountStable * ONE / price;
        require(_minPegCoin >= outputAmountAtExpectedPrice * buySlippage / ONE, "AMO: Slippage too low");
        require(IERC20(_stableCoin).balanceOf(address(this)) >= _amountStable, "AMO: Insufficient stableCoin");
        }
        // transfer stableCoin to adapter
        IERC20(_stableCoin).safeTransfer(_adapter, _amountStable);
        uint256 beforeSwap = IERC20(_pegCoin).balanceOf(address(this));
        // Let the adapter buy pegCoin (note that the peg coin should be transferred back)
        IAdapter(_adapter).buyPegCoin(_amountStable, _minPegCoin);
        uint256 swapAmount = IERC20(_pegCoin).balanceOf(address(this)) - beforeSwap;
        require(swapAmount >= _minPegCoin, "AMO: insufficient peg coin"); // slippage constriant
        emit PegCoinBought(_amountStable, swapAmount);
    }

    function getPrice() internal view returns (uint) {
        if (oracle == address(0)) {
            return 1e18;
        } else {
            return IOracle(oracle).getPrice();
        }
    }

    function sellPegCoinAMO(
        uint256 _amountPegCoin, // The amount of pegCoin to sell
        uint256 _minStable // The minimum amount of stableCoin to receive
    ) external onlyManager onlySwapCoolDown whenNotPaused {
        address _adapter = adapter; address _stableCoin = stableCoin; address _pegCoin = pegCoin; // cache
        { // input verifications, use curly braces to limit the scope of the variables and avoid stack-too-deep error
        require(_amountPegCoin > 0, "AMO: Amount must be positive");
        uint price = getPrice();
        uint outputAmountAtExpectedPrice = _amountPegCoin * price / ONE;
        require(_minStable >= outputAmountAtExpectedPrice * sellSlippage / ONE, "AMO: Slippage too low");
        require(IERC20(_pegCoin).balanceOf(address(this)) >= _amountPegCoin, "AMO: Insufficient pegCoin");
        }
        // transfer pegCoin to adapter
        IERC20(_pegCoin).safeTransfer(_adapter, _amountPegCoin);
        uint256 beforeSwap = IERC20(_stableCoin).balanceOf(address(this));
        // Let the adapter sell pegCoin (note that the peg coin should be transferred back)
        IAdapter(_adapter).sellPegCoin(_amountPegCoin, _minStable);
        uint256 swapAmount = IERC20(_stableCoin).balanceOf(address(this)) - beforeSwap;
        // slippage constraint
        require(swapAmount >= _minStable, "AMO: insufficient stable coin");
        emit PegCoinSold(_amountPegCoin, swapAmount);
    }

    function addLiquidityAMO(
        uint256 _amountPeg, // The amount of pegCoin to add liquidity
        uint256 _amountStable, // The amount of stableCoin to add liquidity
        uint256 _minAmountLP // The minimum amount of LP to be minted
    ) external onlyManager onlyLiquidityCoolDown whenNotPaused {
        address _adapter = adapter; address _stableCoin = stableCoin; address _pegCoin = pegCoin; // cache
        require(IERC20(_pegCoin).balanceOf(address(this)) >= _amountPeg, "Insufficient pegCoin");
        require(IERC20(_stableCoin).balanceOf(address(this)) >= _amountStable, "Insufficient stableCoin");
        // transfer pegCoin and stableCoin to adapter
        IERC20(_pegCoin).safeTransfer(_adapter, _amountPeg);
        IERC20(_stableCoin).safeTransfer(_adapter, _amountStable);
        // Let the adapter add liquidity
        // !!!WARNING: the adapter MUST perform SLIPPAGE CHECKS
        uint256 beforeSwap = IAdapter(_adapter).balanceLP();
        IAdapter(_adapter).addLiquidity(_amountPeg, _amountStable, _minAmountLP);
        uint256 addAmount = IAdapter(_adapter).balanceLP() - beforeSwap;
        require(addAmount >= _minAmountLP, "AMO: insufficient LP");
        emit LiquidityAdded(_amountPeg, _amountStable, addAmount);
    }

    function removeLiquidityAMO(
        uint256 _amountLP, // The amount of LP token to withdraw
        uint256 _minPegCoin, // The minimum amount of pegCoin to receive
        uint256 _minStable // The minimum amount of stableCoin to receive
    ) external onlyManager onlyLiquidityCoolDown whenNotPaused {
        address _adapter = adapter; address _stableCoin = stableCoin; address _pegCoin = pegCoin; // cache
        // input verifications
        require(_amountLP > 0, "AMO: Amount must be positive");
        require(IAdapter(_adapter).balanceLP() >= _amountLP, "AMO: Insufficient LP");

        uint256 beforeSwapPeg = IERC20(_pegCoin).balanceOf(address(this));
        uint256 beforeSwapStable = IERC20(_stableCoin).balanceOf(address(this));
        // Let the adapter remove liquidity (note that the peg/stable coin should be transferred back)
        IAdapter(_adapter).removeLiquidity(_amountLP, _minPegCoin, _minStable);
        uint256 swapAmountPeg = IERC20(_pegCoin).balanceOf(address(this)) - beforeSwapPeg;
        uint256 swapAmountStable = IERC20(_stableCoin).balanceOf(address(this)) - beforeSwapStable;
        // slippage constraint
        require(swapAmountPeg >= _minPegCoin, "AMO: insufficient peg coin");
        require(swapAmountStable >= _minStable, "AMO: insufficient stable coin");
        emit LiquidityRemoved(_amountLP, swapAmountPeg, swapAmountStable);
    }

    // This is called to collect rewards and send to profitManager.
    function collectRewards() external onlyManager whenNotPaused {
        require(profitManager != address(0), "AMO: ProfitManager not configured");
        IAdapter(adapter).getReward(profitManager);
        emit RewardsCollected(profitManager);
    }

    // The adapter should only contain LP token
    // When there are pegcoin or stablecoin in the adapter, we withdraw them to AMO
    function withdrawTokens() external onlyManager {
        uint256 pegBal = IERC20(pegCoin).balanceOf(adapter);
        if(pegBal > 0){
            IAdapter(adapter).withdrawERC20ToAMO(pegCoin, pegBal);
        }
        uint256 stableBal = IERC20(stableCoin).balanceOf(adapter);
        if(stableBal > 0){
            IAdapter(adapter).withdrawERC20ToAMO(stableCoin, stableBal);
        }
    }

    // === GOVERNANCE FUNCTIONS & EMERGENCY FUNCTIONS ===
    function RescueTokenToAMO(address tokenAddress, uint256 tokenAmount) external onlyOwner {
        if(tokenAddress == address(0)){
            IAdapter(adapter).withdrawEtherToAMO(tokenAmount);
        } else {
            IAdapter(adapter).withdrawERC20ToAMO(tokenAddress, tokenAmount);
        }
    }

    function RescueTokenToOwner(address tokenAddress) external onlyOwner {
        if(tokenAddress == address(0)){
            payable(owner()).call{value: address(this).balance}("");
        } else {
            if (IERC20(tokenAddress).balanceOf(address(this)) > 0) {
                IERC20(tokenAddress).safeTransfer(owner(), IERC20(tokenAddress).balanceOf(address(this)));
            }
        }
    }

    // This function can only be called by the multi sig owner in emergency.
    // It is to avoid using proxy contract and in case any assets are stuck in the contract.
    function rescue(address target, uint256 value, bytes calldata data) external onlyOwner {
        (bool success, ) = target.call{value: value}(data);
        require(success, "Rescue: Call failed");
    }

    receive() external payable {}
}