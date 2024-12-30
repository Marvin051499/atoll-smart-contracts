// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;


interface ISwapRouterCLP {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 limitSqrtPrice;
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
}

interface IichiSwapXPool {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function globalState()external view returns (
      uint160 price,
      int24 tick,
      uint16 fee,
      uint16 timepointIndex,
      uint8 communityFeeToken0,
      uint8 communityFeeToken1,
      bool unlocked
    );
}

interface IichiVault {
    function deposit(uint256 deposit0, uint256 deposit1, address to) external;
    function withdraw(uint256 shares, address to) external;
}

interface ISwapXGauge {
    function deposit(uint256 amount) external;
    function withdraw(uint256 amount) external;
    function getReward() external;
}