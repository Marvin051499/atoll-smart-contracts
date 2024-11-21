// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../interfaces/IVelodrome.sol";
import "../interfaces/IAdapter.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";

contract VelodromeDexAdapter is IAdapter, Ownable2Step {
    using SafeERC20 for IERC20;

    // === Security
    constructor() Ownable(msg.sender) {}

    address public AMO;

    modifier onlyAMO() {
        require(msg.sender == AMO, "Not AMO");
        _;
    }

    uint256 public constant ONE = 1e18;
    uint256 public addLiquidReserveUpperBond = 15e17;
    uint256 public addLiquidReserveLowerBond = 1e18;
    uint256 public addLiquiditySlippage = (1e18 * 999) / 1000; // 0.1%
    uint256 public buySlippage = (1e18 * 997) / 1000; // 0.3%
    uint256 public sellSlippage = (1e18 * 997) / 1000; // 0.3%
    bool public isStable = true;
    bool public enableSwap = true;

    function config(bool _isStable, bool _enableSwap) external onlyOwner {
        isStable = _isStable;
        enableSwap = _enableSwap;
    }

    function configSecurity(
        uint256 _addLiquidReserveUpperBond,
        uint256 _addLiquidReserveLowerBond,
        uint256 _addLiquiditySlippage,
        uint256 _buySlipage,
        uint256 _sellSlipage
    ) external onlyOwner {
        addLiquidReserveUpperBond = _addLiquidReserveUpperBond;
        addLiquidReserveLowerBond = _addLiquidReserveLowerBond;
        addLiquiditySlippage = _addLiquiditySlippage;
        buySlippage = _buySlipage;
        sellSlippage = _sellSlipage;
    }

    // === Velodrome/Aerodrome Adapter ===
    address public pegCoin;
    address public stableCoin;
    bool public pegIsZero; // if true, pegCoin is token0 of the pair
    uint256 public decimalDiff;

    address veloPair;
    address veloGauge;
    address veloRouter;
    address veloFactory;
    address[] veloRewardToken;

    function configAddress(
        address _AMO,
        address _pegCoin,
        address _stableCoin,
        address _veloPair,
        address _veloGauge,
        address _veloRouter,
        address _veloFactory,
        address[] memory _veloRewardToken
    ) external onlyOwner {
        AMO = _AMO;
        pegCoin = _pegCoin;
        stableCoin = _stableCoin;
        veloPair = _veloPair;
        veloGauge = _veloGauge;
        veloRouter = _veloRouter;
        veloFactory = _veloFactory;
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

    function _transferTokenTo(address token, address recipient) internal {
        uint balance = IERC20(token).balanceOf(address(this));
        if (balance > 0) IERC20(token).safeTransfer(recipient, balance);
    }

    function _transferPegAndStableToAMO() internal {
        _transferTokenTo(pegCoin, AMO);
        _transferTokenTo(stableCoin, AMO);
    }

    modifier onlyCalm() {
        (uint256 rPeg, uint256 rStable,) = ISolidlyPair(veloPair).getReserves();
        if (!pegIsZero) {
            (rPeg, rStable) = (rStable, rPeg);
        }
        require(rPeg > 0 && rStable > 0, "No Reserve");
        rStable = rStable * decimalDiff;
        uint256 reserveDiv = (rPeg * ONE) / rStable;
        require(
            reserveDiv >= addLiquidReserveLowerBond && reserveDiv <= addLiquidReserveUpperBond,
            "Pair Reserve Not In Range"
        );
        _;
    }

    function addLiquidity(uint256 _amountPeg, uint256 _amountStable, uint256 _minAmountLP) external override onlyAMO onlyCalm {
        // 0 - input validation
        require(_amountPeg > 0 && _amountStable > 0, "Invalid Amounts");
        require(IERC20(pegCoin).balanceOf(address(this)) >= _amountPeg, "No Enough PegCoin");
        require(IERC20(stableCoin).balanceOf(address(this)) >= _amountStable, "No Enough StableCoin");
        uint256 _minAmountPeg = (_amountPeg * addLiquiditySlippage) / ONE;
        uint256 _minAmountStable = (_amountStable * addLiquiditySlippage) / ONE;

        // 1 - approve
        IERC20(stableCoin).safeIncreaseAllowance(veloRouter, _amountStable);
        IERC20(pegCoin).safeIncreaseAllowance(veloRouter, _amountPeg);

        // 2 - perform add liquidity
        IVelodromeRouter(veloRouter).addLiquidity(
            pegCoin,
            stableCoin,
            isStable,
            _amountPeg,
            _amountStable,
            _minAmountPeg,
            _minAmountStable,
            address(this),
            block.timestamp
        );

        // 3 - deposit LP tokens to gauge
        uint256 balLP = IERC20(veloPair).balanceOf(address(this));
        IERC20(veloPair).safeIncreaseAllowance(veloGauge, balLP);
        IVelodromeGauge(veloGauge).deposit(balLP, address(this));
        _transferPegAndStableToAMO();
        // After return, AMO will check the received amount of LP tokens
    }

    // We do not need to check slippage when redeeming. Note that we do not add `onlyCalm` modifier here.
    function removeLiquidity(uint256 _amountLP, uint256 _minPeg, uint256 _minStable) external override onlyAMO {
        require(_amountLP > 0, "Invalid Amounts");
        _redeemLiquidity(_amountLP, _minPeg, _minStable);
        _transferPegAndStableToAMO();
    }

    function _redeemLiquidity(uint256 _amountLP, uint256 _minPeg, uint256 _minStable) internal {
        // step - 1: check LP balance
        uint256 stakedLPamount = IVelodromeGauge(veloGauge).balanceOf(address(this));
        uint256 balLP = IERC20(veloPair).balanceOf(address(this));
        require(stakedLPamount + balLP >= _amountLP, "AMO: Insufficient LP");

        // step - 2: unstake LP from velo gauge
        if (_amountLP > balLP) {
            IVelodromeGauge(veloGauge).withdraw(_amountLP - balLP);
        }
        // step - 3: remove liquidity
        balLP = IERC20(veloPair).balanceOf(address(this));
        if (balLP < _amountLP) {
            _amountLP = balLP;
        }
        IERC20(veloPair).safeIncreaseAllowance(veloRouter, _amountLP);
        IVelodromeRouter(veloRouter).removeLiquidity(
            pegCoin, stableCoin, isStable, _amountLP, _minPeg, _minStable, AMO, block.timestamp
        );
        // deposit the rest of LP tokens
        uint256 LPBal = IERC20(veloPair).balanceOf(address(this));
        if (LPBal > 0) {
            IERC20(veloPair).safeIncreaseAllowance(veloGauge, LPBal);
            IVelodromeGauge(veloGauge).deposit(LPBal, address(this));
        }
    }

    function buyPegCoin(uint256 amountStable, uint256 minAmountPeg) external override onlyAMO {
        require(enableSwap, "Swap Disabled");
        // step - 0: input validation
        require(amountStable > 0, "Invalid Amounts");
        require(minAmountPeg >= amountStable * decimalDiff * buySlippage / ONE, "Invalid Min Amount");
        require(IERC20(stableCoin).balanceOf(address(this)) >= amountStable, "No Enough StableCoin");
        // step - 1: approve
        IERC20(stableCoin).safeIncreaseAllowance(veloRouter, amountStable);
        // step - 2: swap
        IVelodromeRouter.Route[] memory routes = new IVelodromeRouter.Route[](1);
        routes[0] = IVelodromeRouter.Route({
            from: stableCoin,
            to: pegCoin,
            stable: isStable,
            factory: veloFactory
        });
        IVelodromeRouter(veloRouter).swapExactTokensForTokens(
            amountStable, minAmountPeg, routes, AMO, block.timestamp
        );
    }

    function sellPegCoin(uint256 amountPeg, uint256 minAmounStable) external override onlyAMO {
        require(enableSwap, "Swap Disabled");
        // step - 0: input validation
        require(amountPeg > 0, "Invalid Amounts");
        require(minAmounStable * decimalDiff >= amountPeg * sellSlippage / ONE, "Invalid Min Amount");
        require(IERC20(pegCoin).balanceOf(address(this)) >= amountPeg, "Not Enough PegCoin");
        // step - 1: approve
        IERC20(pegCoin).safeIncreaseAllowance(veloRouter, amountPeg);
        // step - 2: swap
        IVelodromeRouter.Route[] memory routes = new IVelodromeRouter.Route[](1);
        routes[0] = IVelodromeRouter.Route({
            from: pegCoin,
            to: stableCoin,
            stable: isStable,
            factory: veloFactory
        });
        IVelodromeRouter(veloRouter).swapExactTokensForTokens(
            amountPeg, minAmounStable, routes, AMO, block.timestamp
        );
    }

    function getReward(address profitManager) external override onlyAMO {
        IVelodromeGauge(veloGauge).getReward(address(this));
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
        return IVelodromeGauge(veloGauge).balanceOf(address(this)) + IERC20(veloPair).balanceOf(address(this));
    }
}
