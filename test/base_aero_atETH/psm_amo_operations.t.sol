// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {aero_base_ateth_test_base} from "./test_initialize_base_aerodrome.t.sol";

contract PSM_AMO_Test is aero_base_ateth_test_base {
    event Paused();
    event Unpaused();
    event SecurityConfigured(address manager, address securityManager);
    event Deposited(uint256 amountIn, uint256 amountOut);
    event TransferedToReceipt(address receipt, uint256 amountStable); 
    event AddressConfigured(address peg, address stable, address[] AMO, uint256 fee);

    function setUp() public override {
        vm.setEnv("DEBUG_SETUP", "false");
        super.setUp();
        _transfer_ownership(false);
    }

    function test_initialState() public {
        console2.log("=== Testing PSM initial state ===");
        assertEq(psm.owner(), multiSig, "Initial owner should be multiSig");
        assertEq(psm.paused(), 0, "PSM should not be paused initially");
        assertEq(psm.pegCoin(), address(ateth), "Peg coin should be atETH");
        assertEq(psm.stableCoin(), WETH, "Stable coin should be WETH");
        assertEq(psm.fee(), 0, "Initial fee should be 0");
    }

    function test_configSecurity() public {
        console2.log("=== Testing PSM configSecurity function ===");
        address newManager = address(0x123);
        address newSecurityManager = address(0x456);

        vm.expectEmit(true, true, false, true);
        emit SecurityConfigured(newManager, newSecurityManager);

        vm.startPrank(multiSig);
        psm.configSecurity(newManager, newSecurityManager);
        vm.stopPrank();
        assertEq(psm.manager(), newManager, "Manager should be updated");
        assertEq(psm.securityManager(), newSecurityManager, "Security manager should be updated");
    }

    function test_configAddress() public {
        console2.log("=== Testing PSM configAddress function ===");
        address newPeg = address(ateth);
        address newStable = address(WETH);
        address[] memory newAMOs = new address[](2);
        newAMOs[0] = address(0xdef);
        newAMOs[1] = address(0x123);
        uint256 newFee = 1e16; // 1%

        vm.expectEmit(true, true, true, true);
        emit AddressConfigured(newPeg, newStable, newAMOs, newFee);

        vm.startPrank(multiSig);
        psm.configAddress(newPeg, newStable, newAMOs, newFee);
        vm.stopPrank();

        assertEq(psm.pegCoin(), newPeg, "Peg coin should be updated");
        assertEq(psm.stableCoin(), newStable, "Stable coin should be updated");
        assertEq(psm.receipts(0), newAMOs[0], "First AMO should be updated");
        assertEq(psm.receipts(1), newAMOs[1], "Second AMO should be updated");
        assertEq(psm.fee(), newFee, "Fee should be updated");
    }

    function test_mint() public {
        console2.log("=== Testing PSM convert function ===");
        
        uint256 convertAmount = 10 ether;
        uint256 initialUserWETHBalance = IERC20(WETH).balanceOf(user);
        uint256 initialUserAtETHBalance = IERC20(address(ateth)).balanceOf(user);
        uint256 initialPSMWETHBalance = IERC20(WETH).balanceOf(address(psm));
        uint256 initialPSMAtETHBalance = IERC20(address(ateth)).balanceOf(address(psm));

        vm.startPrank(user);
        IERC20(WETH).approve(address(psm), convertAmount);
        
        vm.expectEmit(true, true, false, true);
        emit Deposited(convertAmount, convertAmount);

        psm.mint(convertAmount, user);

        uint256 finalUserWETHBalance = IERC20(WETH).balanceOf(user);
        uint256 finalUserAtETHBalance = IERC20(address(ateth)).balanceOf(user);
        uint256 finalPSMWETHBalance = IERC20(WETH).balanceOf(address(psm));
        uint256 finalPSMAtETHBalance = IERC20(address(ateth)).balanceOf(address(psm));

        assertEq(initialUserWETHBalance - finalUserWETHBalance, convertAmount, "User should have spent correct WETH");
        assertEq(finalUserAtETHBalance - initialUserAtETHBalance, convertAmount, "User should have received correct atETH");
        assertEq(finalPSMWETHBalance - initialPSMWETHBalance, convertAmount, "PSM should have received correct WETH");
        assertEq(initialPSMAtETHBalance - finalPSMAtETHBalance, convertAmount, "PSM should have sent correct atETH");

        vm.stopPrank();
    }

    function test_sendToAMO() public {
        console2.log("=== Testing PSM sendToAMO function ===");

        uint256 sendAmount = 5 ether;
        vm.startPrank(user);
        IERC20(WETH).approve(address(psm), sendAmount * 2);
        psm.mint(sendAmount * 2, user);
        vm.stopPrank();

        uint256 initialPSMWETHBalance = IERC20(WETH).balanceOf(address(psm));
        uint256 initialAMOWETHBalance = IERC20(WETH).balanceOf(address(amo));

        vm.expectEmit(true, false, false, true);
        emit TransferedToReceipt(address(amo), sendAmount);

        vm.startPrank(manager);
        psm.sendToAMO(sendAmount, 0);
        vm.stopPrank();

        uint256 finalPSMWETHBalance = IERC20(WETH).balanceOf(address(psm));
        uint256 finalAMOWETHBalance = IERC20(WETH).balanceOf(address(amo));

        assertEq(initialPSMWETHBalance - finalPSMWETHBalance, sendAmount, "PSM should have sent correct WETH");
        assertEq(finalAMOWETHBalance - initialAMOWETHBalance, sendAmount, "AMO should have received correct WETH");
    }

    function test_withdrawCoins() public {
        console2.log("=== Testing PSM withdrawCoins function ===");

        uint256 depositAmount = 10 ether;
        vm.startPrank(user);
        IERC20(WETH).approve(address(psm), depositAmount);
        psm.mint(depositAmount, user);
        vm.stopPrank();

        uint256 initialPSMWETHBalance = IERC20(WETH).balanceOf(address(psm));
        uint256 initialPSMAtETHBalance = IERC20(address(ateth)).balanceOf(address(psm));
        uint256 initialOwnerWETHBalance = IERC20(WETH).balanceOf(multiSig);
        uint256 initialOwnerAtETHBalance = IERC20(address(ateth)).balanceOf(multiSig);

        vm.startPrank(manager);
        psm.withdrawStableCoins();
        vm.stopPrank();

        uint256 finalPSMWETHBalance = IERC20(WETH).balanceOf(address(psm));
        uint256 finalPSMAtETHBalance = IERC20(address(ateth)).balanceOf(address(psm));
        uint256 finalOwnerWETHBalance = IERC20(WETH).balanceOf(multiSig);
        uint256 finalOwnerAtETHBalance = IERC20(address(ateth)).balanceOf(multiSig);

        assertEq(finalPSMWETHBalance, 0, "PSM should have 0 WETH after withdrawal");
        assertEq(finalOwnerWETHBalance - initialOwnerWETHBalance, initialPSMWETHBalance, "Owner should have received all WETH from PSM");
    }

    function test_withdrawStableCoins() public {
        console2.log("=== Testing PSM withdrawStableCoins function ===");

        uint256 depositAmount = 10 ether;
        vm.startPrank(user);
        IERC20(WETH).approve(address(psm), depositAmount);
        psm.mint(depositAmount, user);
        vm.stopPrank();

        uint256 initialPSMWETHBalance = IERC20(WETH).balanceOf(address(psm));
        uint256 initialOwnerWETHBalance = IERC20(WETH).balanceOf(multiSig);

        vm.startPrank(multiSig);
        psm.withdrawStableCoins();
        vm.stopPrank();

        uint256 finalPSMWETHBalance = IERC20(WETH).balanceOf(address(psm));
        uint256 finalOwnerWETHBalance = IERC20(WETH).balanceOf(multiSig);

        assertEq(initialPSMWETHBalance - finalPSMWETHBalance, initialPSMWETHBalance, "PSM should have sent correct WETH");
        assertEq(finalOwnerWETHBalance - initialOwnerWETHBalance, initialPSMWETHBalance, "Owner should have received correct WETH");
    }

    function test_pause_unpause() public {
        console2.log("=== Testing PSM pause and unpause functions ===");

        vm.startPrank(securityManager);
        vm.expectEmit(false, false, false, true);
        emit Paused();
        psm.pause();
        assertEq(psm.paused(), 1, "PSM should be paused");
        vm.stopPrank();

        vm.startPrank(user);
        vm.expectRevert("PSM: Paused");
        psm.mint(1 ether, user);
        vm.stopPrank();

        vm.startPrank(multiSig);
        vm.expectEmit(false, false, false, true);
        emit Unpaused();
        psm.unpause();
        assertEq(psm.paused(), 0, "PSM should be unpaused");
        vm.stopPrank();
        vm.startPrank(user);
        IERC20(WETH).approve(address(psm), 1 ether);
        psm.mint(1 ether, user);
        vm.stopPrank();
    }

    function test_auth_functions() public {
        console2.log("=== Testing PSM authorization functions ===");

        vm.startPrank(user);
        
        vm.expectRevert("PSM: Not Manager");
        psm.sendToAMO(1 ether, 0);

        vm.expectRevert("PSM: Not Manager");
        psm.withdrawStableCoins();

        vm.expectRevert();
        psm.withdrawStableCoins();

        vm.expectRevert("PSM: Not Security Manager");
        psm.pause();

        vm.expectRevert();
        psm.unpause();

        vm.expectRevert();
        psm.configSecurity(address(0), address(0));

        vm.expectRevert();
        address[] memory emptyArray;
        psm.configAddress(address(0), address(0), emptyArray, 0);

        vm.stopPrank();
    }

    function test_rescue() public {
        console2.log("=== Testing PSM rescue function ===");

        vm.deal(address(psm), 1 ether);
        uint256 initialBalance = address(multiSig).balance;

        vm.startPrank(multiSig);
        psm.rescue(multiSig, 0.5 ether, "");
        vm.stopPrank();

        uint256 finalBalance = address(multiSig).balance;

        assertEq(finalBalance - initialBalance, 0.5 ether, "Owner should have received 0.5 ETH");
        assertEq(address(psm).balance, 0.5 ether, "PSM should have 0.5 ETH left");
    }

    function test_fee_mechanism() public {
        console2.log("=== Testing PSM fee mechanism ===");

        uint256 newFee = 1e16; // 1%
        address[] memory currentAMOs = new address[](1);
        currentAMOs[0] = address(amo);

        vm.startPrank(multiSig);
        psm.configAddress(psm.pegCoin(), psm.stableCoin(), currentAMOs, newFee);
        vm.stopPrank();

        uint256 convertAmount = 100 ether;
        uint256 expectedOutput = convertAmount * (1e18 - newFee) / 1e18;

        vm.startPrank(user);
        IERC20(WETH).approve(address(psm), convertAmount);
        
        vm.expectEmit(true, true, false, true);
        emit Deposited(convertAmount, expectedOutput);

        psm.mint(convertAmount, user);

        uint256 userAtETHBalance = IERC20(address(ateth)).balanceOf(user);
        assertEq(userAtETHBalance, expectedOutput, "User should have received correct amount of atETH after fee");

        vm.stopPrank();
    }

    function test_multiple_AMOs() public {
        console2.log("=== Testing PSM with multiple AMOs ===");

        address newAMO = address(0x123);
        address[] memory newAMOs = new address[](2);
        newAMOs[0] = address(amo);
        newAMOs[1] = newAMO;

        vm.startPrank(multiSig);
        psm.configAddress(psm.pegCoin(), psm.stableCoin(), newAMOs, 0);
        vm.stopPrank();

        uint256 sendAmount = 5 ether;
        vm.startPrank(user);
        IERC20(WETH).approve(address(psm), sendAmount * 2);
        psm.mint(sendAmount * 2, user);
        vm.stopPrank();

        vm.startPrank(manager);
        psm.sendToAMO(sendAmount, 0);
        psm.sendToAMO(sendAmount, 1);
        vm.stopPrank();

        assertEq(IERC20(WETH).balanceOf(address(amo)), sendAmount, "First AMO should have received correct WETH");
        assertEq(IERC20(WETH).balanceOf(newAMO), sendAmount, "Second AMO should have received correct WETH");
    }
}