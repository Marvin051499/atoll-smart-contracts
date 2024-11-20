pragma solidity ^0.8.26;

import {aero_base_ateth_test_base} from "./test_initialize_base_aerodrome.t.sol";
import {Test, console2} from "forge-std/Test.sol";

contract Auth_test is aero_base_ateth_test_base {
    function setUp() public override {
        vm.setEnv("DEBUG_SETUP", "true");
        super.setUp();
    }

    function test_initialize() public pure {
        console2.log("Tested initialize");
    }
}
