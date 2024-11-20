// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {PsmAMO} from "./PsmAMO.sol";

interface IWETH {
    function deposit() external payable;
}

contract WethRouter {
    address public immutable PSM;
    IWETH public immutable WETH;

    constructor(address psm, address weth) {
        PSM = psm;
        WETH = IWETH(weth);
        IERC20(weth).approve(PSM, type(uint).max);
    }

    function doConvert(uint256 amount, address receiver) internal {
        WETH.deposit{value: amount}();
        PsmAMO(PSM).mint(amount, receiver);
    }

    // just a bundler
    function mint(address receiver) external payable {
        doConvert(msg.value, receiver);
    }

    fallback() external payable {
        doConvert(msg.value, msg.sender);
    }

    receive() external payable {
        doConvert(msg.value, msg.sender);
    }
}
