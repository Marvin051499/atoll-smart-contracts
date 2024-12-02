// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../interfaces/IVelodrome.sol";
import "../interfaces/IAdapter.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";

contract VelodromeCLPAdapter is IAdapter, Ownable2Step {
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

    address public veloPair;
    address public veloGauge;
    address public veloRouter;
    address public veloFactory;
    address public nftManager;
    address[] public veloRewardToken;
    // @audit: one-shot address configuration
    bool _addressConfiged;
    
    function configAddress(
        address _AMO,
        address _pegCoin,
        address _stableCoin,
        address _veloPair,
        address _veloGauge,
        address _veloRouter,
        address _veloFactory,
        address _nftManager,
        address[] memory _veloRewardToken
    ) external onlyOwner {
        // @audit: one-shot address configuration
        require(!_addressConfiged, "Address already configured");
        _addressConfiged = true;
        AMO = _AMO;
        pegCoin = _pegCoin;
        stableCoin = _stableCoin;
        veloPair = _veloPair;
        veloGauge = _veloGauge;
        veloRouter = _veloRouter;
        veloFactory = _veloFactory;
        nftManager = _nftManager;
        veloRewardToken = new address[](_veloRewardToken.length);
        for (uint256 i = 0; i < _veloRewardToken.length; i++) {
            veloRewardToken[i] = _veloRewardToken[i];
        }

        address token0 = ISolidlyPair(veloPair).token0();
        address token1 = ISolidlyPair(veloPair).token1();
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

    uint256 public isTickInitialized; // make sure the nft tick is only initialized once
    uint256 public nftID;
    int24 public tickSpacing;
    int24 public tickLower;
    int24 public tickUpper;

    // all these parameters should only be set once

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

    function configTickParams(int24 _tickSpacing, int24 _tickLower, int24 _tickUpper) external onlyOwner {
        require(isTickInitialized == 0, "Tick already initialized");
        tickSpacing = _tickSpacing;
        tickLower = _tickLower;
        tickUpper = _tickUpper;
        isTickInitialized = 1;
    }

    modifier onlyCalm() {
        (,int24 tick,,,,) = IVeloPoolCLP(veloPair).slot0();
        require(tick >= tickLower && tick <= tickUpper, "Not in the tick");
        _;
    }

    function _mintPosition(uint256 _amount0, uint256 _amount1, uint256 _minAmount0, uint256 _minAmount1) internal {
        require(nftID == 0, "NFT already minted");
        address token0; address token1;
        if (pegIsZero) {
            token0 = pegCoin;
            token1 = stableCoin;
        } else {
            token0 = stableCoin;
            token1 = pegCoin;
        }
        IVelodromeNFTManager.MintParams memory mintParams = IVelodromeNFTManager.MintParams({
            token0: token0,
            token1: token1,
            tickSpacing: tickSpacing,
            tickLower: tickLower,
            tickUpper: tickUpper,
            amount0Desired: _amount0,
            amount1Desired: _amount1,
            amount0Min: _minAmount0,
            amount1Min: _minAmount1,
            recipient: address(this),
            deadline: block.timestamp,
            sqrtPriceX96: 0
        });
        // mint position
        (uint256 nftIDCached,,,) = IVelodromeNFTManager(nftManager).mint(mintParams);
        IERC721(nftManager).setApprovalForAll(veloGauge, true);
        nftID = nftIDCached;
    }

    function addLiquidity(uint256 _amountPeg, uint256 _amountStable, uint256 _minAmountLP) external override onlyAMO onlyCalm {
        // 0 - input validation
        require(IERC20(pegCoin).balanceOf(address(this)) >= _amountPeg, "No Enough PegCoin");
        require(IERC20(stableCoin).balanceOf(address(this)) >= _amountStable, "No Enough StableCoin");
        uint256 _minAmountPeg = (_amountPeg * addLiquiditySlippage) / ONE;
        uint256 _minAmountStable = (_amountStable * addLiquiditySlippage) / ONE;

        // 1 - approve
        if (_amountStable > 0) IERC20(stableCoin).safeIncreaseAllowance(nftManager, _amountStable);
        if (_amountPeg > 0) IERC20(pegCoin).safeIncreaseAllowance(nftManager, _amountPeg);

        // 2 - mint NFT or perform add liquidity
        if (nftID == 0) {
            _mintPosition(_amountPeg, _amountStable, _minAmountPeg, _minAmountStable);
        } else {
            // withdraw the NFT from gauge
            IVelodromeGaugeCLP(veloGauge).withdraw(nftID);
            IVelodromeNFTManager.IncreaseLiquidityParams memory increaseLiquidityParams = IVelodromeNFTManager.IncreaseLiquidityParams({
                tokenId: nftID,
                amount0Desired: _amountPeg,
                amount1Desired: _amountStable,
                amount0Min: _minAmountPeg,
                amount1Min: _minAmountStable,
                deadline: block.timestamp
            });
            IVelodromeNFTManager(nftManager).increaseLiquidity(increaseLiquidityParams);
        }
        // stake into gauge
        IVelodromeGaugeCLP(veloGauge).deposit(nftID);   
        _transferPegAndStableToAMO();
        // @audit: decrease allowance for the router
        _setAllowanceToZero(stableCoin, veloRouter);
        _setAllowanceToZero(pegCoin, veloRouter);
    }

    // We do not need to check slippage when redeeming.
    function removeLiquidity(uint256 _amountLP, uint256 _minPeg, uint256 _minStable) external override onlyAMO {
        require(_amountLP > 0, "Invalid Amounts");
        _redeemLiquidity(_amountLP, _minPeg, _minStable);
        IVelodromeGaugeCLP(veloGauge).deposit(nftID);
        _transferPegAndStableToAMO();
    }

    function _redeemLiquidity(uint256 _amountLP, uint256 _minPeg, uint256 _minStable) internal {
        uint256 nftIdCached = nftID;
        require(nftIdCached > 0, "NFT not minted");
        // step - 1: check LP (liquidity) balance
        require(balanceLP() >= _amountLP, "AMO: Insufficient LP");

        // step - 2: withdraw NFT from gauge
        IVelodromeGaugeCLP(veloGauge).withdraw(nftID);
        // step - 3: remove liquidity
        IVelodromeNFTManager.DecreaseLiquidityParams memory decreaseLiquidityParams = IVelodromeNFTManager.DecreaseLiquidityParams({
            tokenId: nftIdCached,
            liquidity: uint128(_amountLP),
            amount0Min: _minPeg,
            amount1Min: _minStable,
            deadline: block.timestamp
        });
        IVelodromeNFTManager(nftManager).decreaseLiquidity(decreaseLiquidityParams);

        // step - 4: collect tokens
        IVelodromeNFTManager.CollectParams memory collectParams = IVelodromeNFTManager.CollectParams({
            tokenId: nftIdCached,
            recipient: address(this),
            amount0Max: type(uint128).max,
            amount1Max: type(uint128).max
        });
        IVelodromeNFTManager(nftManager).collect(collectParams);
    }

    function buyPegCoin(uint256 amountStable, uint256 minAmountPeg) external override onlyAMO {
        // step - 0: input validation
        require(amountStable > 0, "Invalid Amounts");
        require(minAmountPeg >= amountStable * decimalDiff * buySlippage / ONE, "Invalid Min Amount");
        require(IERC20(stableCoin).balanceOf(address(this)) >= amountStable, "No Enough StableCoin");
        // step - 1: approve
        IERC20(stableCoin).safeIncreaseAllowance(veloRouter, amountStable);
        // step - 2: swap
        ISwapRouterCLP.ExactInputSingleParams memory params = ISwapRouterCLP.ExactInputSingleParams({
            tokenIn: stableCoin,
            tokenOut: pegCoin,
            tickSpacing: tickSpacing,
            recipient: AMO,
            deadline: block.timestamp,
            amountIn: amountStable,
            amountOutMinimum: minAmountPeg,
            sqrtPriceLimitX96: 0
        });
        ISwapRouterCLP(veloRouter).exactInputSingle(params);
        // @audit: decrease allowance for the router
        _setAllowanceToZero(stableCoin, veloRouter);
    }

    function sellPegCoin(uint256 amountPeg, uint256 minAmounStable) external override onlyAMO {
        // step - 0: input validation
        require(amountPeg > 0, "Invalid Amounts");
        require(minAmounStable * decimalDiff >= amountPeg * sellSlippage / ONE, "Invalid Min Amount");
        require(IERC20(pegCoin).balanceOf(address(this)) >= amountPeg, "Not Enough PegCoin");
        // step - 1: approve
        IERC20(pegCoin).safeIncreaseAllowance(veloRouter, amountPeg);
        // step - 2: swap
        ISwapRouterCLP.ExactInputSingleParams memory params = ISwapRouterCLP.ExactInputSingleParams({
            tokenIn: pegCoin,
            tokenOut: stableCoin,
            tickSpacing: tickSpacing,
            recipient: AMO,
            deadline: block.timestamp,
            amountIn: amountPeg,
            amountOutMinimum: minAmounStable,
            sqrtPriceLimitX96: 0
        });
        ISwapRouterCLP(veloRouter).exactInputSingle(params);
        // @audit: decrease allowance for the router
        _setAllowanceToZero(pegCoin, veloRouter);
    }

    function getReward(address profitManager) external override onlyAMO {
        IVelodromeGaugeCLP(veloGauge).getReward(nftID);
        for (uint256 i = 0; i < veloRewardToken.length; i++) {
            _transferTokenTo(veloRewardToken[i], profitManager);
        }
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
        if (nftID == 0) return 0;
        (,,,,,,,uint128 liquidity,,,,) = IVelodromeNFTManager(nftManager).positions(nftID);
        return liquidity;
    }

    function onERC721Received(address, address, uint256, bytes calldata) external returns (bytes4) {
        return this.onERC721Received.selector;
    }
}