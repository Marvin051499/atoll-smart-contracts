// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

interface IAdapter {
    function balanceLP() external view returns (uint256);
    function addLiquidity(
        uint256 _amountPeg, uint256 _amountStable,uint256 _minAmountLP
    ) external;
    function removeLiquidity(uint256 amountLP, uint256 minPeg, uint256 minStable) external;
    function buyPegCoin(uint256 amountStable,uint256 minAmountPeg) external;
    function sellPegCoin(uint256 amountPeg, uint256 minAmounStable) external;
    function getReward(address profitManager) external;
    function withdrawERC20ToAMO(address token, uint256 amount) external;
    function withdrawEtherToAMO(uint256 amount) external;
    function withdrawAllToAMO() external;
}