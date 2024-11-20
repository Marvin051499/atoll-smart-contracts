// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;
import "@openzeppelin/contracts/access/Ownable2Step.sol";

interface IERC20Decimals {
    function decimals() external view returns(uint8);
}
contract ManualOracle is Ownable2Step {
    uint256 internal exchangeRate;
    event PriceChanged(uint256 newPrice);

    constructor(uint256 _exchangeRate) Ownable(msg.sender) {
        exchangeRate = _exchangeRate;
    }

    function getPrice() external view returns (uint256) {
        return exchangeRate;
    }

    function setPrice(uint256 _exchangeRate) external onlyOwner {
        exchangeRate = _exchangeRate;
        emit PriceChanged(_exchangeRate);
    }
}