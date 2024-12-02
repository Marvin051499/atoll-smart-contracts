// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

// import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {console2} from "forge-std/console2.sol"; 
import {aero_base_ateth_test_base_clp} from "./test_initialize_base_aerodrome.t.sol";
import {IVelodromeRouter, ISolidlyPair, IVelodromeGauge, ISwapRouterCLP} from "../../src/interfaces/IVelodrome.sol";
import "../../src/interfaces/IAdapter.sol";
import {PsmAMO} from "../../src/PsmAMO.sol";

contract Rebalance_amo_operations is aero_base_ateth_test_base_clp {
    event PegCoinBought(uint256 amountStable, uint256 amountPeg);
    event PegCoinSold(uint256 amountPeg, uint256 amountStable);
    event LiquidityAdded(uint256 amountPeg, uint256 amountStable, uint256 amountLP);
    event LiquidityRemoved(uint256 amountLP, uint256 amountPeg, uint256 amountStable);
    event RewardsCollected(address to);
    event Paused();
    event Unpaused();

    function setUp() public override {
        vm.setEnv("DEBUG_SETUP", "false");
        super.setUp();
        _transfer_ownership(false);
    }

    function test_initialState() public {
        console2.log("=== Testing RebalanceAMO initial state ===");
        assertEq(amo.owner(), multiSig, "Initial owner should be multiSig");
        assertEq(amo.paused(), 0, "AMO should not be paused initially");
        assertEq(amo.pegCoin(), address(ateth), "Peg coin should be atETH");
        assertEq(amo.stableCoin(), WETH, "Stable coin should be WETH");
        assertEq(amo.coolDown(), 600, "Cool down should be 600 seconds");
        assertEq(amo.buySlippage(), 1e18 * 997 / 1000, "Buy slippage should be 0.3%");
        assertEq(amo.sellSlippage(), 1e18 * 997 / 1000, "Sell slippage should be 0.3%");
    }

    function test_configSecurity() public {
        console2.log("=== Testing RebalanceAMO configSecurity function ===");
        address newManager = address(0x123);
        address newSecurityManager = address(0x456);
        address newProfitManager = address(0x789);
        uint256 newCoolDown = 1200;
        uint256 newBuySlippage = 1e18 * 99 / 100;
        uint256 newSellSlippage = 1e18 * 98 / 100;

        vm.startPrank(multiSig);
        amo.configSecurity(newManager, newSecurityManager, newProfitManager, newCoolDown, newBuySlippage, newSellSlippage);
        vm.stopPrank();

        assertEq(amo.manager(), newManager, "Manager should be updated");
        assertEq(amo.securityManager(), newSecurityManager, "Security manager should be updated");
        assertEq(amo.profitManager(), newProfitManager, "Profit manager should be updated");
        assertEq(amo.coolDown(), newCoolDown, "Cool down should be updated");
        assertEq(amo.buySlippage(), newBuySlippage, "Buy slippage should be updated");
        assertEq(amo.sellSlippage(), newSellSlippage, "Sell slippage should be updated");
    }

    function test_sell_add_CLP() public {
        // 1. user use WETH to buy atETH
        vm.startPrank(user, user);

        IERC20(WETH).approve(address(veloRouterCLP), type(uint256).max);
        uint amountOut = ISwapRouterCLP(veloRouterCLP).exactInputSingle(
            ISwapRouterCLP.ExactInputSingleParams({
                tokenIn: address(WETH),
                tokenOut: address(ateth),
                tickSpacing: 50,
                recipient: user,
                deadline: type(uint256).max,
                amountIn: 20 ether,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
        );
        console2.log("[+] swapping %s WETH to %s atETH", 20 ether, amountOut);
        logBalanceSheet();

        // now atETH price is very high, need to sell atETH to get WETH back
        console2.log("[-] Testing not manager to sell atETH");
        vm.expectRevert("AMO: Not Manager");
        amo.sellPegCoinAMO(15 ether, 15 ether);
        console2.log("\tSuccess! AMO can't sell atETH");
        vm.startPrank(manager, manager);
        uint balOfWETHInAMOBefore = IERC20(WETH).balanceOf(address(amo));
        amo.sellPegCoinAMO(15 ether, 15 ether);
        console2.log("[+] AMO selling %s atETH to get %s WETH", 15 ether,IERC20(WETH).balanceOf(address(amo)) - balOfWETHInAMOBefore);
        logBalanceSheet();
        console2.log("[-] Testing swap with cooling down");
        vm.expectRevert("AMO: swap Cooling Down");
        amo.sellPegCoinAMO(5 ether, 5 ether);
        console2.log("\tSuccess! AMO can't sell atETH");
        vm.roll(block.number + 10);
        vm.warp(block.timestamp + 11 minutes);
        balOfWETHInAMOBefore = IERC20(WETH).balanceOf(address(amo));
        amo.sellPegCoinAMO(5 ether, 4.99 ether);
        console2.log("[+] AMO selling %s atETH to get %s WETH", 5 ether,IERC20(WETH).balanceOf(address(amo)) - balOfWETHInAMOBefore);
        logBalanceSheet();

        // now, add liquidity
        {
        uint balOfLPBefore = IAdapter(adapter).balanceLP();
        console2.log("[+] Testing add liquidity");
        uint stableBalance = IERC20(address(WETH)).balanceOf(address(amo));
        (uint amountPeg, uint amountStable, uint minLP) = (10 ether, 2.5 ether, 0 ether);
        vm.startPrank(user, user);
        console2.log("[-] Testing not manager to sell atETH");
        vm.expectRevert("AMO: Not Manager");
        amo.addLiquidityAMO(amountPeg, amountStable, minLP);
        console2.log("\tSuccess! AMO can't add liquidity");
        vm.startPrank(manager, manager);
        amo.addLiquidityAMO(amountPeg, amountStable, minLP);
        console2.log("[+] AMO add liquidity with %s WETH and %s atETH", amountStable, amountPeg);
        logBalanceSheet();
        console2.log("[+] adapter LP balance change: %s", IAdapter(adapter).balanceLP() - balOfLPBefore);
        }
    }

    function test_remove_buy_CLP() public {
        // 0. give user some atETH
        vm.startPrank(multiSig, multiSig);
        ateth.ownerMint(user, 40 ether);

        // 1. user use WETH to buy atETH
        vm.startPrank(user, user);
        IERC20(ateth).approve(address(veloRouterCLP), type(uint256).max);
        uint amountOut = ISwapRouterCLP(veloRouterCLP).exactInputSingle(
            ISwapRouterCLP.ExactInputSingleParams({
                tokenIn: address(ateth),
                tokenOut: address(WETH),
                tickSpacing: 50,
                recipient: user,
                deadline: type(uint256).max,
                amountIn: 10 ether,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
        );
        console2.log("[+] swapping %s atETH to %s WETH", 10 ether, amountOut);
        logBalanceSheet();

        // now atETH price is low, we need to remove liquidity and buy atETH
        // remove liquidity
        uint balOfLPBefore = IAdapter(adapter).balanceLP();
        uint balOfAtETHInAMOBefore = IERC20(address(ateth)).balanceOf(address(amo));
        uint balOfWETHInAMOBefore = IERC20(WETH).balanceOf(address(amo));
        uint amountToBuyStable = 5 ether;
        (uint amountLP, uint minAmountStable, uint minAmountPeg) = (10000 ether, 2.99 ether, 20 ether);
        vm.startPrank(user, user);
        console2.log("[-] Testing not manager to remove liquidity");
        vm.expectRevert("AMO: Not Manager");
        amo.removeLiquidityAMO(amountLP, minAmountPeg, minAmountStable);
        console2.log("\tSuccess! AMO can't remove liquidity");
        vm.startPrank(manager, manager);
        console2.log("[+] Testing remove liquidity");
        amo.removeLiquidityAMO(amountLP, minAmountPeg, minAmountStable);
        logBalanceSheet();
        console2.log("[+] adapter LP balance change: -%s", balOfLPBefore - IAdapter(adapter).balanceLP() );
        console2.log("[+] amo atETH balance change: %s", IERC20(address(ateth)).balanceOf(address(amo)) - balOfAtETHInAMOBefore);
        console2.log("[+] amo WETH balance change: %s", IERC20(WETH).balanceOf(address(amo)) - balOfWETHInAMOBefore);
        
        // buy atETH
        console2.log("[-] Testing not manager to buy atETH");
        vm.startPrank(user, user);
        vm.expectRevert("AMO: Not Manager");
        amo.buyPegCoinAMO(5 ether, 4.99 ether);
        console2.log("\tSuccess! AMO can't buy atETH");
        vm.startPrank(manager, manager);
        uint balOfatETHInAMOBefore = IERC20(ateth).balanceOf(address(amo));
        amo.buyPegCoinAMO(5 ether, 4.99 ether);
        console2.log("[+] AMO buying %s atETH with %s WETH",IERC20(ateth).balanceOf(address(amo)) - balOfatETHInAMOBefore, 5 ether);
        logBalanceSheet();

        console2.log("[-] Testing swap with cooling down");
        vm.expectRevert("AMO: swap Cooling Down");
        amo.buyPegCoinAMO(5 ether, 4.99 ether);
        console2.log("\tSuccess! AMO can't sell atETH");
        vm.roll(block.number + 10);
        vm.warp(block.timestamp + 11 minutes);
        balOfatETHInAMOBefore = IERC20(ateth).balanceOf(address(amo));
        amo.buyPegCoinAMO(5 ether, 4.99 ether);
        console2.log("[+] AMO buying %s atETH with %s WETH", IERC20(ateth).balanceOf(address(amo)) - balOfatETHInAMOBefore, 5 ether);
        logBalanceSheet();
    }

    function test_buyPegCoinAMO_CLP() public {
        console2.log("=== Testing RebalanceAMO buyPegCoinAMO function ===");
        // user sell atETH
        logBalanceSheet();
        vm.startPrank(user, user);
        // user sell atETH
        IERC20(WETH).approve(address(psm), type(uint256).max);
        PsmAMO(psm).mint(20 ether, user);
        console2.log("[+] user convert %s WETH to %s atETH", 20 ether, IERC20(ateth).balanceOf(user));
        logBalanceSheet();
        IERC20(ateth).approve(address(veloRouterCLP), type(uint256).max);
        uint amountOut = ISwapRouterCLP(veloRouterCLP).exactInputSingle(
            ISwapRouterCLP.ExactInputSingleParams({
                tokenIn: address(ateth),
                tokenOut: address(WETH),
                tickSpacing: 50,
                recipient: user,
                deadline: type(uint256).max,
                amountIn: 10 ether,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
        );
        console2.log("[+] swapping %s atETH to %s WETH", 10 ether, amountOut);
        logBalanceSheet();
        deal(WETH, address(amo), 15 ether);
        uint256 buyAmount = 5 ether;
        uint256 minPegCoin = 4.985 ether;
        vm.startPrank(manager);
        uint balOfatETHInAMOBefore = IERC20(address(ateth)).balanceOf(address(amo));
        amo.buyPegCoinAMO(buyAmount, minPegCoin);

        // Check balances
        assertGe(IERC20(address(ateth)).balanceOf(address(amo)) - balOfatETHInAMOBefore, minPegCoin, "AMO should have received at least minPegCoin");

        // Test cool down
        vm.startPrank(manager);
        vm.expectRevert("AMO: swap Cooling Down");
        amo.buyPegCoinAMO(1 ether, 0.997 ether);

        // Advance time
        vm.warp(block.timestamp + 601);

        // Should work now
        vm.startPrank(manager);
        amo.buyPegCoinAMO(1 ether, 0.997 ether);
    }

    function test_sellPegCoinAMO() public {
        console2.log("=== Testing RebalanceAMO sellPegCoinAMO function ===");
        uint256 sellAmount = 1 ether;
        uint256 minStable = 0.998 ether;

        uint balOfWETHInAMOBefore = IERC20(WETH).balanceOf(address(amo));
        vm.startPrank(manager);
        amo.sellPegCoinAMO(sellAmount, minStable);

        // Check balances
        assertGe(IERC20(WETH).balanceOf(address(amo)) - balOfWETHInAMOBefore, minStable, "AMO should have received at least minStable");

        // Test cool down
        vm.startPrank(manager);
        vm.expectRevert("AMO: swap Cooling Down");
        amo.sellPegCoinAMO(1 ether, 0.998 ether);

        // Advance time
        vm.warp(block.timestamp + 601);

        // Should work now
        vm.startPrank(manager);
        balOfWETHInAMOBefore = IERC20(WETH).balanceOf(address(amo));
        amo.sellPegCoinAMO(1 ether, 0.998 ether);
        assertGe(IERC20(WETH).balanceOf(address(amo)) - balOfWETHInAMOBefore, minStable, "AMO should have received at least minStable");
    }

    function test_addLiquidityAMO() public {
        console2.log("=== Testing RebalanceAMO addLiquidityAMO function ===");
        uint256 amountPeg = 10 ether;
        uint256 amountStable = 2.5 ether;
        uint256 minAmountLP = 9.9 ether;

        vm.startPrank(manager);
        deal(WETH, address(amo), 20 ether);
        amo.addLiquidityAMO(amountPeg, amountStable, minAmountLP);

        // Check LP balance
        assertGe(IAdapter(adapter).balanceLP(), minAmountLP, "AMO should have received at least minAmountLP");

        // Test cool down
        vm.startPrank(manager);
        vm.expectRevert("AMO: liquidity Cooling Down");
        amo.addLiquidityAMO(1 ether, 0.25 ether, 1 ether);

        // Advance time
        vm.warp(block.timestamp + 601);

        // Should work now
        vm.startPrank(manager);
        amo.addLiquidityAMO(1 ether, 0.25 ether, 1 ether);
    }

    function test_removeLiquidityAMO_CLP() public {
        console2.log("=== Testing RebalanceAMO removeLiquidityAMO function ===");
        uint256 amountLP = 10000 ether;
        uint256 minPegCoin = 0 ether;
        uint256 minStable = 0 ether;

        vm.startPrank(manager);
        console2.log("[+] AMO LP balance: %s", IAdapter(adapter).balanceLP());
        uint256 balOfLPBefore = IAdapter(adapter).balanceLP();
        uint256 balOfatETHBefore = IERC20(address(ateth)).balanceOf(address(amo));
        uint256 balOfWETHBefore = IERC20(WETH).balanceOf(address(amo));
        amo.removeLiquidityAMO(amountLP, minPegCoin, minStable);
        console2.log("[+] AMO LP balance change: -%s", balOfLPBefore - IAdapter(adapter).balanceLP());
        console2.log("[+] AMO atETH balance change: %s", IERC20(address(ateth)).balanceOf(address(amo)) - balOfatETHBefore);
        console2.log("[+] AMO WETH balance change: %s", IERC20(WETH).balanceOf(address(amo)) - balOfWETHBefore);

        // Check balances
        assertGe(IERC20(address(ateth)).balanceOf(address(amo)), minPegCoin, "AMO should have received at least minPegCoin");
        assertGe(IERC20(WETH).balanceOf(address(amo)), minStable, "AMO should have received at least minStable");

        // Test cool down
        vm.startPrank(manager);
        vm.expectRevert("AMO: liquidity Cooling Down");
        amo.removeLiquidityAMO(10000 ether, 19.9 ether, 4.99 ether);

        // Advance time
        vm.warp(block.timestamp + 601);

        // Should work now
        vm.startPrank(manager);
        balOfLPBefore = IAdapter(adapter).balanceLP();
        balOfatETHBefore = IERC20(address(ateth)).balanceOf(address(amo));
        balOfWETHBefore = IERC20(WETH).balanceOf(address(amo));
        amo.removeLiquidityAMO(10000 ether, 19.9 ether, 4.99 ether);
        console2.log("[+] AMO LP balance change: -%s", balOfLPBefore - IAdapter(adapter).balanceLP());
        console2.log("[+] AMO atETH balance change: %s", IERC20(address(ateth)).balanceOf(address(amo)) - balOfatETHBefore);
        console2.log("[+] AMO WETH balance change: %s", IERC20(WETH).balanceOf(address(amo)) - balOfWETHBefore);
    }

    function test_collectRewards_CLP() public {
        console2.log("=== Testing RebalanceAMO collectRewards function ===");
        vm.startPrank(manager);
        vm.expectEmit(true, false, false, true);
        emit RewardsCollected(amo.profitManager());
        amo.collectRewards();
        console2.log("[+] AMO collected rewards, now profitManager has %s AERO", IERC20(AERO).balanceOf(address(amo.profitManager())));
        require(IERC20(AERO).balanceOf(address(amo.profitManager())) > 0, "AMO should have received AERO");
    }

    function test_withdrawTokens() public {
        console2.log("=== Testing RebalanceAMO withdrawTokens function ===");
        // Simulate tokens in adapter
        deal(address(ateth), adapter, 5 ether);
        deal(WETH, adapter, 5 ether);

        uint256 initialBalOfatETH = IERC20(address(ateth)).balanceOf(address(amo));
        uint256 initialBalOfWETH = IERC20(WETH).balanceOf(address(amo));

        vm.startPrank(manager);
        amo.withdrawTokens();

        assertEq(IERC20(address(ateth)).balanceOf(address(amo)) - initialBalOfatETH, 5 ether, "AMO should have received atETH from adapter");
        assertEq(IERC20(WETH).balanceOf(address(amo)) - initialBalOfWETH, 5 ether, "AMO should have received WETH from adapter");
    }

    function test_RescueTokenToAMO() public {
        console2.log("=== Testing RebalanceAMO RescueTokenToAMO function ===");

        // rescue atETH
        deal(address(ateth), adapter, 5 ether);
        vm.startPrank(multiSig);
        uint balOfatETH = IERC20(address(ateth)).balanceOf(address(adapter));
        uint initialBalOfatETH = IERC20(address(ateth)).balanceOf(address(amo));
        amo.RescueTokenToAMO(address(ateth), balOfatETH);   
        assertEq(IERC20(address(ateth)).balanceOf(address(amo)) - initialBalOfatETH, balOfatETH, "AMO should have received atETH from adapter");

        // rescue WETH
        deal(WETH, adapter, 5 ether);
        vm.startPrank(multiSig);
        uint balOfWETH = IERC20(WETH).balanceOf(address(adapter));
        uint initialBalOfWETH = IERC20(WETH).balanceOf(address(amo));
        amo.RescueTokenToAMO(WETH, balOfWETH);
        assertEq(IERC20(WETH).balanceOf(address(amo)) - initialBalOfWETH, balOfWETH, "AMO should have received WETH from adapter");

        // rescue ETH
        vm.startPrank(multiSig);
        uint initialBalOfETH = address(amo).balance;
        vm.deal(address(adapter), 1 ether);
        amo.RescueTokenToAMO(address(0), 1 ether);
        assertEq(address(amo).balance - initialBalOfETH, 1 ether, "AMO should have received ETH from adapter");
    }

    function test_rescue() public {
        console2.log("=== Testing RebalanceAMO rescue function ===");
        vm.deal(address(amo), 1 ether); // Give AMO some ETH

        vm.startPrank(multiSig);
        amo.rescue(multiSig, 0.5 ether, "");

        assertEq(address(multiSig).balance, 0.5 ether, "Owner should have received 0.5 ETH");
        assertEq(address(amo).balance, 0.5 ether, "AMO should have 0.5 ETH left");
    }

    function test_pause_unpause() public {
        console2.log("=== Testing RebalanceAMO pause and unpause functions ===");

        vm.startPrank(securityManager);
        vm.expectEmit(false, false, false, true);
        emit Paused();
        amo.pause();
        assertEq(amo.paused(), 1, "AMO should be paused");

        vm.startPrank(manager);
        deal(WETH, address(amo), 20 ether);
        vm.expectRevert("AMO: Paused");
        amo.buyPegCoinAMO(1 ether, 0.998 ether);

        vm.startPrank(multiSig);
        vm.expectEmit(false, false, false, true);
        emit Unpaused();
        amo.unpause();
        assertEq(amo.paused(), 0, "AMO should be unpaused");

        vm.startPrank(manager);
        amo.buyPegCoinAMO(1 ether, 0.998 ether);
    }
    
    function test_auth_functions() public {
        console2.log("=== Testing RebalanceAMO authorization functions ===");

        vm.startPrank(user);
        
        vm.expectRevert("AMO: Not Manager");
        amo.buyPegCoinAMO(1 ether, 0.99 ether);

        vm.expectRevert("AMO: Not Manager");
        amo.sellPegCoinAMO(1 ether, 0.99 ether);

        vm.expectRevert("AMO: Not Manager");
        amo.addLiquidityAMO(1 ether, 1 ether, 0.99 ether);

        vm.expectRevert("AMO: Not Manager");
        amo.removeLiquidityAMO(1 ether, 0.99 ether, 0.99 ether);

        vm.expectRevert("AMO: Not Manager");
        amo.collectRewards();

        vm.expectRevert("AMO: Not Manager");
        amo.withdrawTokens();

        vm.expectRevert("AMO: Not Security Manager");
        amo.pause();

        vm.expectRevert();
        amo.unpause();

        vm.expectRevert();
        amo.configSecurity(address(0), address(0), address(0), 0, 0, 0);

        vm.expectRevert();
        amo.configAddress(address(0), address(0), address(0), address(0));

        vm.expectRevert();
        amo.RescueTokenToAMO(address(0), 0);

        vm.expectRevert();
        amo.rescue(address(0), 0, "");

        vm.stopPrank();

        console2.log("All unauthorized actions correctly reverted");
    }

    function test_slippage_protection() public {
        console2.log("=== Testing RebalanceAMO slippage protection ===");


        // Test buy slippage protection
        deal(WETH, address(amo), 10 ether);

        vm.startPrank(manager);
        vm.expectRevert("AMO: Slippage too low");
        amo.buyPegCoinAMO(10 ether, 9.96 ether); // Expecting more than possible

        // Test sell slippage protection
        deal(address(ateth), address(amo), 10 ether);

        vm.startPrank(manager);
        vm.expectRevert("AMO: Slippage too low");
        amo.sellPegCoinAMO(10 ether, 9.96 ether); // Expecting more than possible
    }

    function test_edge_cases() public {
        console2.log("=== Testing RebalanceAMO edge cases ===");

        // Test with zero amounts
        vm.startPrank(manager);
        vm.expectRevert("AMO: Amount must be positive");
        amo.buyPegCoinAMO(0, 0);

        vm.startPrank(manager);
        vm.expectRevert("AMO: Amount must be positive");
        amo.sellPegCoinAMO(0, 0);

        vm.startPrank(manager);
        vm.expectRevert("AMO: Amount must be positive");
        amo.removeLiquidityAMO(0, 0, 0);

        // Test with insufficient balance
        vm.startPrank(manager);
        vm.expectRevert("AMO: Insufficient stableCoin");
        amo.buyPegCoinAMO(1000000 ether, 1000000 ether);

        vm.startPrank(manager);
        vm.expectRevert("AMO: Insufficient pegCoin");
        amo.sellPegCoinAMO(1000000 ether, 1000000 ether);

        vm.startPrank(manager);
        vm.expectRevert("Insufficient pegCoin");
        amo.addLiquidityAMO(1000000 ether, 1000000 ether, 0);

        vm.startPrank(manager);
        vm.expectRevert("AMO: Insufficient LP");
        amo.removeLiquidityAMO(1000000 ether, 0, 0);
    }

    function test_emergency_functions_CLP() public {
        console2.log("=== Testing RebalanceAMO emergency functions ===");

        // 1. call amo.pause()
        vm.startPrank(securityManager);
        amo.pause();
        assertEq(amo.paused(), 1, "AMO should be paused");

        // 2. call adapter.withdrawAllToAMO()
        vm.startPrank(owner);
        uint balOfLPBefore = IAdapter(adapter).balanceLP();
        uint atETHOwnerBalBefore = IERC20(address(ateth)).balanceOf(address(amo));
        uint wETHOwnerBalBefore = IERC20(WETH).balanceOf(address(amo));
        IAdapter(adapter).withdrawAllToAMO();
        console2.log("[+] amo received %s atETH and %s WETH", IERC20(address(ateth)).balanceOf(address(amo)) - atETHOwnerBalBefore, IERC20(WETH).balanceOf(address(amo)) - wETHOwnerBalBefore);
        uint balOfLP = IAdapter(adapter).balanceLP();
        console2.log("[+] adapter LP balance change: %s", balOfLPBefore - balOfLP);
        console2.log("now adapter has %s LP", balOfLP);
        logBalanceSheet();

        // 3. call amo.RescueTokenToOwner()
        vm.startPrank(multiSig);
        {
        uint balOfatETH = IERC20(address(ateth)).balanceOf(address(multiSig));
        amo.RescueTokenToOwner(address(ateth));
        console2.log("[+] AMO rescued %s atETH to owner", IERC20(address(ateth)).balanceOf(address(multiSig)) - balOfatETH);
        }
        {
        uint balOfWETH = IERC20(WETH).balanceOf(address(multiSig));
        amo.RescueTokenToOwner(WETH);
        console2.log("[+] AMO rescued %s WETH to owner", IERC20(WETH).balanceOf(address(multiSig)) - balOfWETH);
        }

        // 4. call PSM.RescueTokenToOwner
        {
        uint balOfatETH = IERC20(address(ateth)).balanceOf(address(multiSig));
        psm.RescueTokenToOwner(address(ateth));
        console2.log("[+] psm rescued %s atETH to owner", IERC20(address(ateth)).balanceOf(address(multiSig)) - balOfatETH);
        }
        {
        uint balOfWETH = IERC20(WETH).balanceOf(address(multiSig));
        psm.RescueTokenToOwner(WETH);
        console2.log("[+] psm rescued %s WETH to owner", IERC20(WETH).balanceOf(address(multiSig)) - balOfWETH);
        }
        
        // 5. call satETH.RescueTokenToOwner
        {
        uint balOfatETH = IERC20(address(ateth)).balanceOf(address(multiSig));
        sateth.RescueTokenToOwner(address(ateth));
        console2.log("[+] stakedToken rescued %s atETH to owner", IERC20(address(ateth)).balanceOf(address(multiSig)) - balOfatETH);
        }
        {
        uint balOfWETH = IERC20(WETH).balanceOf(address(multiSig));
        sateth.RescueTokenToOwner(WETH);
        console2.log("[+] stakedToken rescued %s WETH to owner", IERC20(WETH).balanceOf(address(multiSig)) - balOfWETH);
        }

        logBalanceSheet();
    }
}
