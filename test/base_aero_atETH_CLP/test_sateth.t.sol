pragma solidity ^0.8.26;

import {aero_base_ateth_test_base_clp} from "./test_initialize_base_aerodrome.t.sol";
import {Test, console2} from "forge-std/Test.sol";

contract Auth_test is aero_base_ateth_test_base_clp {
    function setUp() override public {
        vm.setEnv("DEBUG_SETUP", "false");
        super.setUp();
    }

    function test_ownership_transfer() public {
        _transfer_ownership(true);
    }

    function test_auth() public {
        _transfer_ownership(false);
        // Rebalance AMO admin functions
        console2.log("1. Rebalance AMO admin functions");
        vm.startPrank(owner);
        vm.expectRevert();
        amo.configSecurity(manager, securityManager, profitManager, 600, 1e18, 997 * 1e18 / 1000);
        vm.startPrank(multiSig);
        amo.configSecurity(manager, securityManager, profitManager, 600, 1e18, 997 * 1e18 / 1000);
        vm.assertEq(amo.manager(), manager);
        vm.assertEq(amo.securityManager(), securityManager);
        vm.assertEq(amo.profitManager(), profitManager);
        vm.assertEq(amo.coolDown(), 600);
        vm.assertEq(amo.buySlippage(), 1e18);
        vm.assertEq(amo.sellSlippage(), 997 * 1e18 / 1000);
        console2.log("[Rebalance AMO] configSecurity tested");
        vm.startPrank(owner);
        vm.expectRevert();
        amo.configAddress(address(ateth), address(WETH), address(adapter), address(oracle));
    }


}