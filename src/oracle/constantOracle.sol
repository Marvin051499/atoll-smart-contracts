// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

interface IERC20Decimals {
    function decimals() external view returns(uint8);
}
contract ConstantOracle {
    uint256 immutable exchangeRate;

    constructor(uint _exchangeRate) {
        exchangeRate = _exchangeRate;
    }

    function getPrice() external view returns (uint256) {
        return exchangeRate;
    }
}