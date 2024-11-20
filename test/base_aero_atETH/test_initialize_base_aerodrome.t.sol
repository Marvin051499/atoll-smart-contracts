// SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Test, console2} from "forge-std/Test.sol";
import {RebalanceAMO} from "../../src/RebalanceAMO.sol";
import {PsmAMO} from "../../src/PsmAMO.sol";
import {StakedToken} from "../../src/StakedToken.sol";
import {GovToken} from "../../src/tokens/GovToken.sol";
import {AtToken} from "../../src/tokens/atToken.sol";
import {VelodromeDexAdapter} from "../../src/dex/VelodromeAdapter.sol";
import {IVelodromeRouter, ISolidlyPair, IVelodromeGauge} from "../../src/interfaces/IVelodrome.sol";
import {Config} from "../test_config.t.sol";
import {ConstantOracle} from "../../src/oracle/constantOracle.sol";

contract aero_base_ateth_test_base is Test, Config {
    // Atoll components
    AtToken public ateth;
    PsmAMO public psm;
    RebalanceAMO public amo;
    address public adapter;
    StakedToken public sateth;
    ConstantOracle public oracle;
    GovToken public ato;

    // tokens
    address WETH = 0x4200000000000000000000000000000000000006;
    address AERO = 0x940181a94A35A4569E4529A3CDfB74e38FD98631;

    // DEX related
    address pair;
    address gauge;
    address public veloFactory = 0x420DD381b31aEf6683db6B902084cB0FFECe40Da;
    address public veloGaugeFactory = 0x16613524e02ad97eDfeF371bC883F2F5d6C480A5;
    address public veloRouter = 0xcF77a3Ba9A5CA399B7c97c74d54e5b1Beb874E43;

    // addresses to prank
    address public veloAdmin = 0xE6A41fE61E7a1996B59d508661e3f524d6A32075;
    address public veNFTHolder = 0x586CF50c2874f3e3997660c0FD0996B090FB9764;

    function setUp() public virtual {
        bool debug = vm.envBool("DEBUG_SETUP");
        // set fork url and block
        vm.createSelectFork(vm.envString("BASE_RPC"), vm.envUint("BASE_FORK_BLOCK"));
        if (debug) {
            console2.log("FORKING on Base chain with rpc: %s, block: %d", vm.envString("BASE_RPC"), block.number);
            console2.log("=== setUp (block number: %d)====", block.number);
        }
        vm.deal(owner, 1100 ether);
        vm.deal(manager, 1100 ether);
        vm.deal(profitManager, 1100 ether);
        vm.deal(user, 1100 ether);
        if (debug) {
            console2.log("[+] owner: %s, funded %d eth", owner, address(owner).balance / 1e18);
            console2.log("[+] manager: %s, funded %d eth", manager, address(manager).balance / 1e18);
            console2.log("[+] profitManager: %s, funded %d eth", profitManager, address(profitManager).balance / 1e18);
            console2.log("[+] user: %s, funded %d eth", user, address(user).balance / 1e18);
        }
        vm.startPrank(manager);
        IWETH(WETH).deposit{value: 1000 ether}();
        vm.startPrank(profitManager);
        IWETH(WETH).deposit{value: 1000 ether}();
        vm.startPrank(user);
        IWETH(WETH).deposit{value: 1000 ether}();
        vm.startPrank(owner);
        IWETH(WETH).deposit{value: 1000 ether}();

        // deploy Atoll token
        ateth = new AtToken("Atoll ETH", "atETH");
        if (debug) {
            console2.log("[+] Atoll ETH deployed at %s", address(ateth));
        }

        // creat pair
        pair = IVeloFactory(veloFactory).createPool(WETH, address(ateth), true);
        vm.startPrank(veloAdmin);
        IVeloGaugeFactory(veloGaugeFactory).whitelistToken(address(ateth), true);
        gauge = IVeloGaugeFactory(veloGaugeFactory).createGauge(veloFactory, pair);
        if (debug) {
            console2.log("[+] weth-ateth pair created at %s", pair);
            console2.log("[+] weth-ateth gauge created at %s", address(gauge));
        }

        // deploy AMO and adapter
        vm.startPrank(owner);
        amo = new RebalanceAMO();
        psm = new PsmAMO();
        oracle = new ConstantOracle(1e18);
        adapter = address(new VelodromeDexAdapter());
        sateth = new StakedToken(ateth, "Staked Atoll ETH", "satETH");
        ato = new GovToken();

        // config AMO
        amo.configSecurity(manager, securityManager, profitManager, 600, 1e18 * 997 / 1000, 1e18 * 997 / 1000);
        amo.configAddress(address(ateth), WETH, address(adapter), address(oracle));

        // config PSM
        psm.configSecurity(manager, securityManager);
        address[] memory AMOs = new address[](1);
        AMOs[0] = address(amo);
        psm.configAddress(address(ateth), WETH, AMOs, 0);

        // config adapter
        address[] memory veloRewardTokens = new address[](1);
        veloRewardTokens[0] = AERO;
        VelodromeDexAdapter(adapter).configAddress(
            address(amo),
            address(ateth),
            WETH,
            address(pair),
            address(gauge),
            address(veloRouter),
            address(veloFactory),
            veloRewardTokens
        );
        // config sateth
        sateth.configSecurity(manager, securityManager);
        sateth.setMarketCapacity(1000 ether);
        sateth.setRateWithAPR(1e17); // set 10% apr

        if (debug) {
            console2.log("[+] AMO deployed and configed at %s", address(amo));
            console2.log("[+] Adapter deployed and configed at %s", adapter);
            console2.log("[+] PSM deployed and configed at %s", address(psm));
            console2.log("[+] v-ateth deployed at %s", address(sateth));
        }

        // mint to amo, psm, sateth
        ateth.ownerMint(address(amo), 1_000 ether);
        assertEq(ateth.balanceOf(address(amo)), 1_000 ether);
        assertEq(ateth.totalSupply(), 1_000 ether);
        ateth.ownerMint(address(psm), 1_000 ether);
        assertEq(ateth.balanceOf(address(psm)), 1_000 ether);
        assertEq(ateth.totalSupply(), 2_000 ether);
        ateth.ownerMint(address(sateth), 1_000 ether);
        assertEq(ateth.balanceOf(address(sateth)), 1_000 ether);
        assertEq(ateth.totalSupply(), 3_000 ether);
        if (debug) {
            console2.log("[+] %d Atoll ETH minted to amo", ateth.balanceOf(address(amo)) / 1e18);
            console2.log("[+] %d Atoll ETH minted to psm", ateth.balanceOf(address(psm)) / 1e18);
            console2.log("[+] %d Atoll ETH minted to sat", ateth.balanceOf(address(sateth)) / 1e18);
        }

        // owner deposit to PSM
        IERC20(WETH).approve(address(psm), 10 ether);
        psm.mint(10 ether, owner);
        if (debug) {
            console2.log("[+] %d WETH deposited to PSM", IERC20(WETH).balanceOf(address(psm)) / 1e18);
        }
        // psm transfer to owner
        psm.withdrawStableCoins();
        ateth.ownerMint(address(owner), 10 ether);
        IERC20(ateth).approve(veloRouter, 10 ether);
        IERC20(WETH).approve(veloRouter, 10 ether);
        (,, uint256 lpAmount) = IVelodromeRouter(veloRouter).addLiquidity(
            WETH, address(ateth), true, 10 ether, 10 ether, 9.999 ether, 9.999 ether, owner, block.timestamp
        );
        if (debug) {
            console2.log("[+] %d WETH-ateth lp token added by owner", lpAmount);
        }
        // transfer lp to rebalance amo
        IERC20(pair).transfer(address(adapter), lpAmount);

        // add liquidity and deposit to gauge
        vm.startPrank(user);
        IERC20(WETH).approve(address(psm), 50 ether);
        psm.mint(50 ether, user);
        if (debug) {
            console2.log("[+] %d eth deposited to PSM", IERC20(WETH).balanceOf(address(psm)) / 1e18);
        }
        IERC20(WETH).approve(veloRouter, 50 ether);
        IERC20(ateth).approve(veloRouter, 50 ether);
        (,, lpAmount) = IVelodromeRouter(veloRouter).addLiquidity(
            WETH, address(ateth), true, 50 ether, 50 ether, 0, 0, user, block.timestamp
        );
        if (debug) {
            console2.log("[+] %d WETH-ateth lp token added by user", lpAmount);
        }
        assertEq(IERC20(pair).balanceOf(user), lpAmount);
        IERC20(pair).approve(gauge, lpAmount);
        IVelodromeGauge(gauge).deposit(lpAmount, user);
        if (debug) {
            console2.log(
                "[+] %d WETH-ateth lp token deposited to gauge, Owner now have %d staked lp",
                lpAmount,
                IERC20(gauge).balanceOf(user)
            );
        }
        assertEq(IVelodromeGauge(gauge).balanceOf(user), lpAmount);

        // transfer PSM's WETH to AMO
        vm.startPrank(manager);
        psm.sendToAMO(IERC20(WETH).balanceOf(address(psm)), 0);
        console2.log("manager", amo.manager());
        amo.addLiquidityAMO(50 ether, 50 ether, 0);
        if (debug) {
            logBalanceSheet();
        }

        // vote for usdc-rou pair
        vm.startPrank(veNFTHolder);
        address[] memory pools = new address[](1);
        pools[0] = pair;
        uint256[] memory weights = new uint256[](1);
        weights[0] = 100000000000000000000;
        IVeloGaugeFactory(veloGaugeFactory).vote(7, pools, weights);
        if (debug) {
            console2.log("[+] WETH-ateth pair voted");
        }

        // go to the future
        vm.warp(block.timestamp + 7 days);
        if (debug) {
            console2.log("[+] warp to %d", block.timestamp);
        }
        address[] memory gauges = new address[](1);
        gauges[0] = gauge;
        IVeloGaugeFactory(veloGaugeFactory).distribute(gauges);
        if (debug) {
            console2.log("[+] reward distributed: %d AERO", IERC20(AERO).balanceOf(gauge) / 1e18);
        }
        vm.warp(block.timestamp + 1 days);
        // claim reward
        vm.startPrank(manager);
        amo.collectRewards();
        if (debug) {
            logBalanceSheet();
        }
    }

    function _transfer_ownership(bool debug) public {
        if (debug) {
            console2.log(">>> 1. AMO transfer ownership");
            console2.log("[before transferOwnership]");
            console2.log("-> amo.owner()       : ", amo.owner());
            console2.log("-> amo.pendingOwner(): ", amo.pendingOwner());
        }
        vm.assertEq(amo.owner(), owner);
        vm.assertEq(amo.pendingOwner(), address(0));
        vm.startPrank(user);
        vm.expectRevert(hex"118cdaa700000000000000000000000090f79bf6eb2c4f870365e785982e1f101e93b906");
        amo.transferOwnership(deployer);
        vm.startPrank(owner);
        amo.transferOwnership(multiSig);
        if (debug) {
            console2.log("[after transferOwnership]");
            console2.log("-> amo.owner()       : ", amo.owner());
            console2.log("-> amo.pendingOwner(): ", amo.pendingOwner());
        }
        vm.assertEq(amo.owner(), owner);
        vm.assertEq(amo.pendingOwner(), multiSig);
        vm.startPrank(user);
        vm.expectRevert(hex"118cdaa700000000000000000000000090f79bf6eb2c4f870365e785982e1f101e93b906");
        amo.acceptOwnership();
        vm.startPrank(multiSig);
        amo.acceptOwnership();
        if (debug) {
            console2.log("[after acceptOwnership]");
            console2.log("-> amo.owner()       : ", amo.owner());
            console2.log("-> amo.pendingOwner(): ", amo.pendingOwner());
        }
        vm.assertEq(amo.owner(), multiSig);
        vm.assertEq(amo.pendingOwner(), address(0));

        // PSM
        if (debug) {
            console2.log(">>> 2. PSM transfer ownership");
            console2.log("[before transferOwnership]");
            console2.log("-> psm.owner()       : ", psm.owner());
            console2.log("-> psm.pendingOwner(): ", psm.pendingOwner());
        }
        vm.assertEq(psm.owner(), owner);
        vm.assertEq(psm.pendingOwner(), address(0));
        vm.startPrank(user);
        vm.expectRevert(hex"118cdaa700000000000000000000000090f79bf6eb2c4f870365e785982e1f101e93b906");
        psm.transferOwnership(deployer);
        vm.startPrank(owner);
        psm.transferOwnership(multiSig);
        if (debug) {
            console2.log("[after transferOwnership]");
            console2.log("-> psm.owner()       : ", psm.owner());
            console2.log("-> psm.pendingOwner(): ", psm.pendingOwner());
        }
        vm.assertEq(psm.owner(), owner);
        vm.assertEq(psm.pendingOwner(), multiSig);
        vm.startPrank(user);
        vm.expectRevert(hex"118cdaa700000000000000000000000090f79bf6eb2c4f870365e785982e1f101e93b906");
        psm.acceptOwnership();
        vm.startPrank(multiSig);
        psm.acceptOwnership();
        if (debug) {
            console2.log("[after acceptOwnership]");
            console2.log("-> psm.owner()       : ", psm.owner());
            console2.log("-> psm.pendingOwner(): ", psm.pendingOwner());
        }
        vm.assertEq(psm.owner(), multiSig);
        vm.assertEq(psm.pendingOwner(), address(0));

        // Staked atETH
        if (debug) {
            console2.log(">>> 3. stake transfer ownership");
            console2.log("[before transferOwnership]");
            console2.log("-> sateth.owner()       : ", sateth.owner());
            console2.log("-> sateth.pendingOwner(): ", sateth.pendingOwner());
        }
        vm.assertEq(sateth.owner(), owner);
        vm.assertEq(sateth.pendingOwner(), address(0));
        vm.startPrank(user);
        vm.expectRevert(hex"118cdaa700000000000000000000000090f79bf6eb2c4f870365e785982e1f101e93b906");
        sateth.transferOwnership(deployer);
        vm.startPrank(owner);
        sateth.transferOwnership(multiSig);
        if (debug) {
            console2.log("[after transferOwnership]");
            console2.log("-> sateth.owner()       : ", sateth.owner());
            console2.log("-> sateth.pendingOwner(): ", sateth.pendingOwner());
        }
        vm.assertEq(sateth.owner(), owner);
        vm.assertEq(sateth.pendingOwner(), multiSig);
        vm.startPrank(user);
        vm.expectRevert(hex"118cdaa700000000000000000000000090f79bf6eb2c4f870365e785982e1f101e93b906");
        sateth.acceptOwnership();
        vm.startPrank(multiSig);
        sateth.acceptOwnership();
        if (debug) {
            console2.log("[after acceptOwnership]");
            console2.log("-> sateth.owner()       : ", sateth.owner());
            console2.log("-> sateth.pendingOwner(): ", sateth.pendingOwner());
        }
        vm.assertEq(sateth.owner(), multiSig);
        vm.assertEq(sateth.pendingOwner(), address(0));

        // atETH
        if (debug) {
            console2.log(">>> 4. ateth transfer ownership");
            console2.log("[before transferOwnership]");
            console2.log("-> ateth.owner()       : ", ateth.owner());
            console2.log("-> ateth.pendingOwner(): ", ateth.pendingOwner());
        }
        vm.assertEq(ateth.owner(), owner);
        vm.assertEq(ateth.pendingOwner(), address(0));
        vm.startPrank(user);
        vm.expectRevert(hex"118cdaa700000000000000000000000090f79bf6eb2c4f870365e785982e1f101e93b906");
        ateth.transferOwnership(deployer);
        vm.startPrank(owner);
        ateth.transferOwnership(multiSig);
        if (debug) {
            console2.log("[after transferOwnership]");
            console2.log("-> ateth.owner()       : ", ateth.owner());
            console2.log("-> ateth.pendingOwner(): ", ateth.pendingOwner());
        }
        vm.assertEq(ateth.owner(), owner);
        vm.assertEq(ateth.pendingOwner(), multiSig);
        vm.startPrank(user);
        vm.expectRevert(hex"118cdaa700000000000000000000000090f79bf6eb2c4f870365e785982e1f101e93b906");
        ateth.acceptOwnership();
        vm.startPrank(multiSig);
        ateth.acceptOwnership();
        if (debug) {
            console2.log("[after acceptOwnership]");
            console2.log("-> ateth.owner()       : ", ateth.owner());
            console2.log("-> ateth.pendingOwner(): ", ateth.pendingOwner());
        }
        vm.assertEq(ateth.owner(), multiSig);
        vm.assertEq(ateth.pendingOwner(), address(0));

        // ATO
        if (debug) {
            console2.log(">>> 5. ATO transfer ownership");
            console2.log("[before transferOwnership]");
            console2.log("-> ato.owner()       : ", ato.owner());
            console2.log("-> ato.pendingOwner(): ", ato.pendingOwner());
        }
        vm.assertEq(ato.owner(), owner);
        vm.assertEq(ato.pendingOwner(), address(0));
        vm.startPrank(user);
        vm.expectRevert(hex"118cdaa700000000000000000000000090f79bf6eb2c4f870365e785982e1f101e93b906");
        ato.transferOwnership(deployer);
        vm.startPrank(owner);
        ato.transferOwnership(multiSig);
        if (debug) {
            console2.log("[after transferOwnership]");
            console2.log("-> ato.owner()       : ", ato.owner());
            console2.log("-> ato.pendingOwner(): ", ato.pendingOwner());
        }
        vm.assertEq(ato.owner(), owner);
        vm.assertEq(ato.pendingOwner(), multiSig);
        vm.startPrank(user);
        vm.expectRevert(hex"118cdaa700000000000000000000000090f79bf6eb2c4f870365e785982e1f101e93b906");
        ato.acceptOwnership();
        vm.startPrank(multiSig);
        ato.acceptOwnership();
        if (debug) {
            console2.log("[after acceptOwnership]");
            console2.log("-> ato.owner()       : ", ato.owner());
            console2.log("-> ato.pendingOwner(): ", ato.pendingOwner());
        }
        vm.assertEq(ato.owner(), multiSig);
        vm.assertEq(ato.pendingOwner(), address(0));
    }

    function logBalanceSheet() internal view {
        string[] memory names = new string[](8);
        names[0] = "owner";
        names[1] = "user";
        names[2] = "AMO";
        names[3] = "PSM";
        names[4] = "adapter";
        names[5] = "manager";
        names[6] = "profitManager";
        names[7] = "pool";
        address[] memory addrs = new address[](8);
        addrs[0] = owner;
        addrs[1] = user;
        addrs[2] = address(amo);
        addrs[3] = address(psm);
        addrs[4] = adapter;
        addrs[5] = manager;
        addrs[6] = profitManager;
        addrs[7] = pair;
        IERC20WithDecimals[] memory tokens = new IERC20WithDecimals[](6);
        string[] memory symbols = new string[](6);
        tokens[0] = IERC20WithDecimals(address(ateth));
        symbols[0] = "ateth";
        tokens[1] = IERC20WithDecimals(WETH);
        symbols[1] = "WETH";
        tokens[2] = IERC20WithDecimals(pair);
        symbols[2] = "lp";
        tokens[3] = IERC20WithDecimals(gauge);
        symbols[3] = "s-lp";
        tokens[4] = IERC20WithDecimals(AERO);
        symbols[4] = "AERO";
        tokens[5] = IERC20WithDecimals(address(sateth));
        symbols[5] = "s-ateth";
        logBalanceSheetInternal(names, addrs, tokens, symbols);
    }

    function logBalanceSheetInternal(
        string[] memory names,
        address[] memory addrs,
        IERC20WithDecimals[] memory tokens,
        string[] memory symbols
    ) internal view {
        // Log the header
        string memory header = repeat("-", 102);
        header = string(abi.encodePacked(header, "\n  |Name                  |"));
        for (uint256 i = 0; i < symbols.length; ++i) {
            header = string(abi.encodePacked(header, " ", formatSymbol(symbols[i]), " |"));
        }
        console2.log(header);

        // Log each row
        for (uint256 i = 0; i < addrs.length; ++i) {
            string memory row = string(abi.encodePacked("| ", formatName(names[i]), " |"));
            for (uint256 j = 0; j < tokens.length; ++j) {
                uint256 balance = tokens[j].balanceOf(addrs[i]);
                (bool success, bytes memory data) =
                    address(tokens[j]).staticcall(abi.encodeWithSelector(tokens[j].decimals.selector));
                uint8 decimals = 18;
                if (success) {
                    decimals = abi.decode(data, (uint8));
                }
                string memory formattedBalance = formatBalance(balance, decimals);
                row = string(abi.encodePacked(row, " ", formattedBalance, " |"));
            }
            console2.log(row);
        }
        console2.log(repeat("-", 102));
    }

    function formatSymbol(string memory symbol) internal pure returns (string memory) {
        // Adjust the symbol to fit a fixed width for alignment, assuming most symbols are <= 5 characters
        if (bytes(symbol).length < 10) {
            return string(abi.encodePacked(symbol, repeat(" ", (10 - bytes(symbol).length))));
        }
        return symbol;
    }

    function formatName(string memory name) internal pure returns (string memory) {
        // Truncate or pad the name to fit 20 characters for alignment
        bytes memory nameBytes = bytes(name);
        return string(abi.encodePacked(name, repeat(" ", (20 - nameBytes.length))));
    }

    function formatBalance(uint256 balance, uint8 decimals) internal pure returns (string memory) {
        if (decimals <= 2) {
            return uint2str(balance);
        }
        uint256 factor = 10 ** (decimals - 2);
        uint256 roundedBalance = balance / factor;
        string memory integerPart = uint2str(roundedBalance / 100);
        string memory decimalPart = uint2str(roundedBalance % 100);
        if (bytes(decimalPart).length < 2) {
            decimalPart = string(abi.encodePacked("0", decimalPart)); // Ensure two decimal places
        }
        string memory ret = string(abi.encodePacked(integerPart, ".", decimalPart));
        // pad with spaces to fit 10 characters
        if (bytes(ret).length >= 10) {
            return ret;
        } else {
            return string(abi.encodePacked(ret, repeat(" ", (10 - bytes(ret).length))));
        }
    }

    // Helper function to convert uint to string
    function uint2str(uint256 _i) internal pure returns (string memory _uintAsString) {
        if (_i == 0) {
            return "0";
        }
        uint256 j = _i;
        uint256 len;
        while (j != 0) {
            len++;
            j /= 10;
        }
        bytes memory bstr = new bytes(len);
        uint256 k = len;
        while (_i != 0) {
            k = k - 1;
            uint8 temp = (48 + uint8(_i - _i / 10 * 10));
            bytes1 b1 = bytes1(temp);
            bstr[k] = b1;
            _i /= 10;
        }
        return string(bstr);
    }

    function repeat(string memory character, uint256 times) internal pure returns (string memory) {
        bytes memory buffer = new bytes(times);
        for (uint256 i = 0; i < times; i++) {
            buffer[i] = bytes(character)[0];
        }
        return string(buffer);
    }
}

interface IVeloFactory {
    function createPool(address tokenA, address tokenB, bool stable) external returns (address pair);
}

interface IVeloGaugeFactory {
    function whitelistToken(address _token, bool _bool) external;

    function createGauge(address factory, address _token) external returns (address gauge);

    function vote(uint256 _tokenId, address[] memory _poolVote, uint256[] memory _weights) external;

    function length() external view returns (uint256);

    function distribute(address[] memory gauges) external;
}

interface IWETH {
    function deposit() external payable;

    function withdraw(uint256 wad) external;
}

interface IERC20WithDecimals {
    function balanceOf(address account) external view returns (uint256);
    function decimals() external view returns (uint8);
}