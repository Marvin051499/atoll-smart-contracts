pragma solidity ^0.8.26;

import {aero_base_ateth_test_base_clp} from "./test_initialize_base_aerodrome.t.sol";
import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract Test_satETH is aero_base_ateth_test_base_clp {
    function setUp() public override {
        vm.setEnv("DEBUG_SETUP", "false");
        super.setUp();
        _transfer_ownership(false);
    }

    function test_satETH() public {
        console2.log("=== Testing satETH ===");

        // owner mint some atETH to user
        vm.startPrank(multiSig);
        ateth.ownerMint(user, 100e18);
        vm.stopPrank();

        // user deposit atETH to stakedToken
        uint256 exchangeRate = sateth.exchangeRate();
        console2.log("exchangeRate: %s", exchangeRate);
        vm.startPrank(user);
        IERC20(address(ateth)).approve(address(sateth), 100e18);
        sateth.deposit(100e18, user);
        uint256 balance = IERC20(address(sateth)).balanceOf(user);
        console2.log("user deposit %d atETH, get %d satETH", 100e18, balance);
        vm.stopPrank();


        // one year later
        vm.warp(block.timestamp + 365 days);
        vm.roll(block.number + 1000000);
        exchangeRate = sateth.exchangeRate();
        console2.log("exchangeRate: %s", exchangeRate);
        // withdraw all satETH
        vm.startPrank(user);
        sateth.redeem(balance, user, user);
        uint256 atethBalance = IERC20(address(ateth)).balanceOf(user);
        console2.log("user withdraw %d satETH, get %d atETH", balance, atethBalance);
        vm.stopPrank();
    }
}