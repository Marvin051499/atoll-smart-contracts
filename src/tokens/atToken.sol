// SPDX-License-Identifier: BUSL-1.1s
pragma solidity ^0.8.26;
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";

contract AtToken is ERC20, Ownable2Step {
    constructor(
        string memory name,
        string memory symbol
    ) ERC20(name, symbol) Ownable(msg.sender) {}

    // Note: that the owner (multisig) can mint tokens.
    // We need this function to distribute tokens to the AMO, PSM, and DAO.
    function ownerMint(address _to, uint256 _amount) external onlyOwner {
        _mint(_to, _amount);
    }
}