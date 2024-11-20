// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";

contract GovToken is ERC20, Ownable2Step {
    constructor() ERC20("Atoll", "ATO") Ownable(msg.sender) {}

    // Note that the owner (multisig) can mint tokens.
    function ownerMint(address _to, uint256 _amount) external onlyOwner {
        _mint(_to, _amount);
    }
}