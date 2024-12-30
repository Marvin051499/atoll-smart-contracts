// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../interfaces/IichiSwapX.sol";
import "../interfaces/IAdapter.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";

contract IchiSwapXCLPAdapter is IAdapter, Ownable2Step {
    using SafeERC20 for IERC20;

    // === Security
    constructor() Ownable(msg.sender) {}

    address public AMO;

    modifier onlyAMO() {
        require(msg.sender == AMO, "Not AMO");
        _;
    }

    uint256 public constant ONE = 1e18;
    uint256 public addLiquiditySlippage = (1e18 * 998) / 1000; // 0.2%
    uint256 public buySlippage = (1e18 * 997) / 1000; // 0.3%
    uint256 public sellSlippage = (1e18 * 997) / 1000; // 0.3%

    function configSecurity(
        uint256 _addLiquiditySlippage,
        uint256 _buySlippage,
        uint256 _sellSlippage
    ) external onlyOwner {
        addLiquiditySlippage = _addLiquiditySlippage;
        buySlippage = _buySlippage;
        sellSlippage = _sellSlippage;
    }

    // === Velodrome/Aerodrome Adapter ===
    address public pegCoin;
    address public stableCoin;
    bool pegIsZero; // if true, pegCoin is token0 of the pair
    uint256 decimalDiff;

    address public pool;
    address public vault;
    address public gauge;
    address public router;
    address public rewardToken;
    // @audit: one-shot address configuration
    bool _addressConfiged;
    
    function configAddress(
        address _AMO,
        address _pegCoin,
        address _stableCoin,
        address _pool,
        address _vault,
        address _gauge,
        address _router,
        address _rewardToken
    ) external onlyOwner {
        // @audit: one-shot address configuration
        require(!_addressConfiged, "Address already configured");
        _addressConfiged = true;
        AMO = _AMO;
        pegCoin = _pegCoin;
        stableCoin = _stableCoin;
        pool = _pool;
        vault = _vault;
        gauge = _gauge;
        router = _router;
        rewardToken = _rewardToken;

        address token0 = IichiSwapXPool(pool).token0();
        address token1 = IichiSwapXPool(pool).token1();
        if (token0 == pegCoin) {
            pegIsZero = true;
            require(token1 == stableCoin, "Invalid Pair");
        } else if (token1 == pegCoin) {
            pegIsZero = false;
            require(token0 == stableCoin, "Invalid Pair");
        } else {
            revert("Invalid Pair");
        }

        uint8 decimalsPeg = ERC20(pegCoin).decimals();
        uint8 decimalsStable = ERC20(stableCoin).decimals();
        decimalDiff = 10 ** (decimalsPeg - decimalsStable);
    }

    function _setAllowanceToZero(address token, address spender) internal {
        uint256 allowance = IERC20(token).allowance(address(this), spender);
        if (allowance > 0) {
            IERC20(token).safeDecreaseAllowance(spender, allowance);
        }
    }

    function _transferTokenTo(address token, address recipient) internal {
        uint balance = IERC20(token).balanceOf(address(this));
        if (balance > 0) IERC20(token).safeTransfer(recipient, balance);
    }

    function _transferPegAndStableToAMO() internal {
        _transferTokenTo(pegCoin, AMO);
        _transferTokenTo(stableCoin, AMO);
    }

    int24 public tickLower;
    int24 public tickUpper;

    function configTickParams(int24 _tickLower, int24 _tickUpper) external onlyOwner {
        tickLower = _tickLower;
        tickUpper = _tickUpper;
    }

    modifier onlyCalm() {
        (,int24 tick,,,,,) = IichiSwapXPool(pool).globalState();
        require(tick >= tickLower && tick <= tickUpper, "Not in the tick");
        _;
    }

    // Add liquidity to the ichi vault
    function addLiquidity(uint256 _amountPeg, uint256 _amountStable, uint256 _minAmountLP) external override onlyAMO onlyCalm {
        // 0 - input validation
        require(IERC20(pegCoin).balanceOf(address(this)) >= _amountPeg, "No Enough PegCoin");
        require(IERC20(stableCoin).balanceOf(address(this)) >= _amountStable, "No Enough StableCoin");
        uint256 _minAmountPeg = (_amountPeg * addLiquiditySlippage) / ONE;
        uint256 _minAmountStable = (_amountStable * addLiquiditySlippage) / ONE;

        // 1 - approve to vault
        if (_amountStable > 0) IERC20(stableCoin).safeIncreaseAllowance(vault, _amountStable);
        if (_amountPeg > 0) IERC20(pegCoin).safeIncreaseAllowance(vault, _amountPeg);

        // 2 - deposit into ICHI vault
        uint balOfLPBefore = IERC20(vault).balanceOf(address(this));
        if (pegIsZero) {
            IichiVault(vault).deposit(_amountPeg, _amountStable, address(this));
        } else {
            IichiVault(vault).deposit(_amountStable, _amountPeg, address(this));
        }
        uint balOfLPAfter = IERC20(vault).balanceOf(address(this));
        uint amountLP = balOfLPAfter - balOfLPBefore;
        require(amountLP >= _minAmountLP, "AMO: Insufficient LP");

        // stake into gauge
        IERC20(vault).safeIncreaseAllowance(gauge, balOfLPAfter);
        ISwapXGauge(gauge).deposit(balOfLPAfter);
        _transferPegAndStableToAMO();
        // @audit: decrease allowance for the router
        _setAllowanceToZero(stableCoin, vault);
        _setAllowanceToZero(pegCoin, vault);
        _setAllowanceToZero(vault, gauge);
    }

    // We do not need to check slippage when redeeming.
    function removeLiquidity(uint256 _amountLP, uint256 _minPeg, uint256 _minStable) external override onlyAMO {
        require(_amountLP > 0, "Invalid Amounts");
        _redeemLiquidity(_amountLP, _minPeg, _minStable);
        _transferPegAndStableToAMO();
    }

    function _redeemLiquidity(uint256 _amountLP, uint256 _minPeg, uint256 _minStable) internal {
        // step - 1: check LP (liquidity) balance
        require(balanceLP() >= _amountLP, "AMO: Insufficient LP");

        // step - 2: withdraw vault token from gauge
        ISwapXGauge(gauge).withdraw(_amountLP);
        // step - 3: remove liquidity
        IichiVault(vault).withdraw(_amountLP, AMO);
        // @note: token balance slippage is checked in the AMO
    }

    function buyPegCoin(uint256 amountStable, uint256 minAmountPeg) external override onlyAMO {
        // step - 0: input validation
        require(amountStable > 0, "Invalid Amounts");
        require(minAmountPeg >= amountStable * decimalDiff * buySlippage / ONE, "Invalid Min Amount");
        require(IERC20(stableCoin).balanceOf(address(this)) >= amountStable, "No Enough StableCoin");
        // step - 1: approve
        IERC20(stableCoin).safeIncreaseAllowance(router, amountStable);
        // step - 2: swap
        ISwapRouterCLP.ExactInputSingleParams memory params = ISwapRouterCLP.ExactInputSingleParams({
            tokenIn: stableCoin,
            tokenOut: pegCoin,
            recipient: AMO,
            deadline: block.timestamp,
            amountIn: amountStable,
            amountOutMinimum: minAmountPeg,
            limitSqrtPrice: 0
        });
        ISwapRouterCLP(router).exactInputSingle(params);
        // @audit: decrease allowance for the router
        _setAllowanceToZero(stableCoin, router);
    }

    function sellPegCoin(uint256 amountPeg, uint256 minAmounStable) external override onlyAMO {
        // step - 0: input validation
        require(amountPeg > 0, "Invalid Amounts");
        require(minAmounStable * decimalDiff >= amountPeg * sellSlippage / ONE, "Invalid Min Amount");
        require(IERC20(pegCoin).balanceOf(address(this)) >= amountPeg, "Not Enough PegCoin");
        // step - 1: approve
        IERC20(pegCoin).safeIncreaseAllowance(router, amountPeg);
        // step - 2: swap
        ISwapRouterCLP.ExactInputSingleParams memory params = ISwapRouterCLP.ExactInputSingleParams({
            tokenIn: pegCoin,
            tokenOut: stableCoin,
            recipient: AMO,
            deadline: block.timestamp,
            amountIn: amountPeg,
            amountOutMinimum: minAmounStable,
            limitSqrtPrice: 0
        });
        ISwapRouterCLP(router).exactInputSingle(params);
        // @audit: decrease allowance for the router
        _setAllowanceToZero(pegCoin, router);
    }

    function getReward(address profitManager) external override onlyAMO {
        ISwapXGauge(gauge).getReward();
        _transferTokenTo(rewardToken, profitManager);
    }

    // == GOVERNANCE ==
    function withdrawERC20ToAMO(address token, uint256 amount) external override {
        require(msg.sender == AMO || msg.sender == owner(), "Not AMO or owner");
        uint balance = IERC20(token).balanceOf(address(this));
        if (balance >= amount) {
            IERC20(token).safeTransfer(AMO, amount);
        } else {
            IERC20(token).safeTransfer(AMO, balance);
        }
    }

    function withdrawEtherToAMO(uint256 amount) external override {
        require(msg.sender == AMO || msg.sender == owner(), "Not AMO or owner");
        payable(AMO).transfer(amount);
    }

    function withdrawAllToAMO() external override onlyOwner {
        _redeemLiquidity(balanceLP(), 0, 0);
        _transferPegAndStableToAMO();
    }

    // This function can only be called by the multi sig owner in emergency.
    // It is to avoid using proxy contract and in case any assets are stuck in the contract. 
    function rescue(address target, uint256 value, bytes calldata data) external onlyOwner {
        (bool success,) = target.call{value: value}(data);
        require(success, "Rescue: Call failed");
    }

    // === VIEW FUNCTIONS ===
    function balanceLP() public view override returns (uint256) {
       return IERC20(vault).balanceOf(address(this)) + IERC20(gauge).balanceOf(address(this));
    }
}