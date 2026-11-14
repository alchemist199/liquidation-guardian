// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Test } from "forge-std/Test.sol";
import { IPayable } from "@reactive/src/interfaces/IPayable.sol";
import { ISystemContract } from "@reactive/src/interfaces/ISystemContract.sol";
import { IReactive } from "@reactive/src/interfaces/IReactive.sol";
import { MockToken } from "../src/MockToken.sol";
import { MockPriceFeed } from "../src/MockPriceFeed.sol";
import { LendingVault } from "../src/LendingVault.sol";
import { Guardian } from "../src/Guardian.sol";
import { LiquidationReactive } from "../src/LiquidationReactive.sol";

address constant SYSTEM_ADDR = 0x8888888888888888888888888888888888888888;
uint256 constant BASE_SEPOLIA = 84532;

/// @notice Stand-in for the Reactive system contract (etched at 0x8888...).
/// Records every callback request so tests can assert on it.
contract MockSystem {
    struct CallbackReq {
        uint256 chainId;
        address recipient;
        uint64 gasLimit;
        bytes payload;
    }

    CallbackReq[] public callbacks;

    function subscribe(uint256, address, uint256, uint256, uint256, uint256) external {}

    function unsubscribe(uint256, address, uint256, uint256, uint256, uint256) external {}

    function requestCallbackV_1_0(ISystemContract.CallbackConfiguration_V_1_0 memory config) external {
        callbacks.push(CallbackReq(config.chainId, config.recipient, config.gasLimit, config.payload));
    }

    function debt(address) external pure returns (uint256) {
        return 0;
    }

    function callbackCount() external view returns (uint256) {
        return callbacks.length;
    }
}

/// @notice Stand-in for the Base Sepolia callback proxy.
contract MockProxy is IPayable {
    function debt(address) external pure returns (uint256) {
        return 0;
    }

    receive() external payable {}
}

contract LiquidationGuardianTest is Test {
    MockToken internal weth;
    MockToken internal usdc;
    MockPriceFeed internal feed;
    LendingVault internal vault;
    Guardian internal guardian;
    LiquidationReactive internal reactive;
    MockSystem internal system;
    MockProxy internal proxy;

    address internal user = address(0xBEEF);
    address internal liquidator = address(0xCAFE);

    uint256 internal constant PRICE_3000 = 3000e8;
    uint256 internal constant PRICE_2000 = 2000e8;

    function setUp() public {
        vm.warp(1_000_000);
        system = new MockSystem();
        vm.etch(SYSTEM_ADDR, address(system).code);
        proxy = new MockProxy();

        weth = new MockToken("Mock WETH", "mWETH", 18);
        usdc = new MockToken("Mock USDC", "mUSDC", 6);
        feed = new MockPriceFeed(int256(PRICE_3000));
        vault = new LendingVault(address(weth), address(usdc), address(feed));
        usdc.setMinter(address(vault));

        reactive = new LiquidationReactive{ value: 1 ether }(BASE_SEPOLIA, address(feed));
        guardian = new Guardian{ value: 0.1 ether }(proxy, address(reactive), address(vault), 1.2e18);
        reactive.setRecipient(address(guardian));

        weth.mint(user, 10 ether);
        weth.mint(address(this), 10 ether);
        vm.startPrank(user);
        weth.approve(address(vault), type(uint256).max);
        weth.approve(address(guardian), type(uint256).max);
        vm.stopPrank();
    }

    function _openPosition() internal returns (uint256 pid) {
        vm.prank(user);
        pid = vault.openPosition(1 ether, 1500e6);
    }

    function _guardPosition(uint256 pid) internal {
        reactive.registerPosition(pid, 1 ether, 1500e6);
    }

    function _fundReserve(uint256 amount) internal {
        weth.approve(address(guardian), amount);
        guardian.depositReserve(amount);
    }

    /// @notice The callback payload starts with the 4-byte selector; strip it before decoding the args.
    function _stripSelector(bytes memory payload) internal pure returns (bytes memory args) {
        args = new bytes(payload.length - 4);
        for (uint256 i = 0; i < args.length; i++) {
            args[i] = payload[i + 4];
        }
    }

    function _priceLog(int256 price) internal view returns (IReactive.LogRecord memory) {
        return IReactive.LogRecord({
            chainId: BASE_SEPOLIA,
            contractAddress: address(feed),
            topic0: uint256(keccak256("PriceUpdated(int256,uint256)")),
            topic1: 0,
            topic2: 0,
            topic3: 0,
            data: abi.encode(price, block.timestamp),
            blockNumber: block.number,
            opCode: 1,
            blockHash: 0,
            txHash: 0,
            logIndex: 0
        });
    }

    function _reactAsSystem(int256 price) internal {
        vm.prank(SYSTEM_ADDR);
        reactive.react(_priceLog(price));
    }

    function testVaultHealthFactor() public {
        uint256 pid = _openPosition();
        // 1 mWETH @ $3000, 1500 mUSDC -> HF = 3000*0.8/1500 = 1.6
        assertEq(vault.healthFactor(pid), 1.6e18);
        feed.setPrice(int256(PRICE_2000));
        // @ $2000 -> HF = 2000*0.8/1500 = 1.0666...
        assertApproxEqAbs(vault.healthFactor(pid), 1.066666666666666666e18, 1e9);
    }

    function testFullLoop() public {
        uint256 pid = _openPosition();
        _guardPosition(pid);
        _fundReserve(1 ether);

        feed.setPrice(int256(PRICE_2000));
        _reactAsSystem(int256(PRICE_2000));

        // One callback requested, to the Guardian on Base Sepolia.
        assertEq(MockSystem(SYSTEM_ADDR).callbackCount(), 1);
        (uint256 chainId, address recipient, uint64 gasLimit, bytes memory payload) = MockSystem(SYSTEM_ADDR).callbacks(0);
        assertEq(chainId, BASE_SEPOLIA);
        assertEq(recipient, address(guardian));
        assertGt(gasLimit, 0);
        (address injected, uint256 cbPid, uint256 topUp) =
            abi.decode(_stripSelector(payload), (address, uint256, uint256));
        assertEq(injected, address(0)); // placeholder the proxy overwrites
        assertEq(cbPid, pid);
        // Needed for HF 1.5 @ $2000: (2812.5-2000)/2000 = 0.40625 mWETH
        assertEq(topUp, 0.40625 ether);

        // The proxy delivers the callback (injecting the reactive address).
        vm.prank(address(proxy));
        guardian.rescue(address(reactive), pid, topUp);

        // Position saved: collateral topped up, HF back to 1.5, reserve spent.
        LendingVault.Position memory pos = vault.getPosition(pid);
        assertEq(pos.collateral, 1.40625 ether);
        assertEq(vault.healthFactor(pid), 1.5e18);
        assertEq(weth.balanceOf(address(guardian)), 1 ether - 0.40625 ether);
    }

    function testNoRescueWhenHealthy() public {
        uint256 pid = _openPosition();
        _guardPosition(pid);
        _fundReserve(1 ether);
        feed.setPrice(2900e8);
        _reactAsSystem(2900e8); // HF = 2900*0.8/1500 = 1.5466... >= 1.2
        assertEq(MockSystem(SYSTEM_ADDR).callbackCount(), 0);
    }

    function testCooldownPreventsSpam() public {
        uint256 pid = _openPosition();
        _guardPosition(pid);
        _fundReserve(5 ether);
        feed.setPrice(int256(PRICE_2000));
        _reactAsSystem(int256(PRICE_2000));
        assertEq(MockSystem(SYSTEM_ADDR).callbackCount(), 1);
        // Price falls further while the first rescue is still in cooldown:
        // HF would be 1.125 < 1.2, but the cooldown blocks a second callback.
        feed.setPrice(1500e8);
        _reactAsSystem(1500e8);
        assertEq(MockSystem(SYSTEM_ADDR).callbackCount(), 1);
        // After the cooldown passes, the still-low price triggers again.
        vm.warp(block.timestamp + 61);
        _reactAsSystem(1500e8);
        assertEq(MockSystem(SYSTEM_ADDR).callbackCount(), 2);
    }

    function testGuardianAuth() public {
        uint256 pid = _openPosition();
        _guardPosition(pid);
        _fundReserve(1 ether);
        // Not from the proxy: reverts.
        vm.expectRevert();
        guardian.rescue(address(reactive), pid, 0.1 ether);
        // From the proxy but with the wrong reactive address: reverts.
        vm.prank(address(proxy));
        vm.expectRevert();
        guardian.rescue(address(0xDEAD), pid, 0.1 ether);
    }

    function testGuardianSkipsWhenHealthy() public {
        uint256 pid = _openPosition();
        _guardPosition(pid);
        _fundReserve(1 ether);
        vm.prank(address(proxy));
        guardian.rescue(address(reactive), pid, 0.1 ether); // HF 1.6 >= 1.2
        assertEq(weth.balanceOf(address(guardian)), 1 ether); // nothing spent
        assertEq(vault.getPosition(pid).collateral, 1 ether);
    }

    function testRescueCapsAtReserve() public {
        uint256 pid = _openPosition();
        _guardPosition(pid);
        _fundReserve(0.1 ether); // less than the 0.40625 needed
        feed.setPrice(int256(PRICE_2000));
        _reactAsSystem(int256(PRICE_2000));
        (,,, bytes memory payload) = MockSystem(SYSTEM_ADDR).callbacks(0);
        (,, uint256 topUp) = abi.decode(_stripSelector(payload), (address, uint256, uint256));
        vm.prank(address(proxy));
        guardian.rescue(address(reactive), pid, topUp);
        // Only the 0.1 reserve was spent; position improved but not to 1.5.
        assertEq(vault.getPosition(pid).collateral, 1.1 ether);
        assertEq(weth.balanceOf(address(guardian)), 0);
        assertGt(vault.healthFactor(pid), 1.066666666666666666e18);
    }

    function testWrongTopicIgnored() public {
        uint256 pid = _openPosition();
        _guardPosition(pid);
        IReactive.LogRecord memory log = _priceLog(int256(PRICE_2000));
        log.topic0 = uint256(keccak256("SomethingElse(uint256)"));
        vm.prank(SYSTEM_ADDR);
        reactive.react(log);
        assertEq(MockSystem(SYSTEM_ADDR).callbackCount(), 0);
    }

    function testReactRevertsForNonSystem() public {
        vm.expectRevert();
        reactive.react(_priceLog(int256(PRICE_2000)));
    }

    function testVaultLiquidation() public {
        uint256 pid = _openPosition();
        feed.setPrice(1000e8); // HF = 1000*0.8/1500 = 0.533 < 1.0
        assertLt(vault.healthFactor(pid), 1e18);
        usdc.mint(liquidator, 1500e6);
        vm.startPrank(liquidator);
        usdc.approve(address(vault), 1500e6);
        vault.liquidate(pid);
        vm.stopPrank();
        assertFalse(vault.getPosition(pid).active);
        // Liquidator seized debt*1.05 worth of collateral: 1575/1000 = 1.575 -> capped at 1.0
        assertEq(weth.balanceOf(liquidator), 1 ether);
    }

    function testVaultRepayAndWithdraw() public {
        uint256 pid = _openPosition();
        vm.startPrank(user);
        usdc.approve(address(vault), 500e6);
        vault.repay(pid, 500e6);
        assertEq(vault.getPosition(pid).debt, 1000e6);
        // HF now 3000*0.8/1000 = 2.4, withdraw 0.2 collateral keeps HF >= 1.1
        vault.withdrawCollateral(pid, 0.2 ether);
        assertEq(vault.getPosition(pid).collateral, 0.8 ether);
        vm.stopPrank();
    }

    function testCoverDebt() public {
        reactive.coverDebt();
        guardian.coverDebt();
    }

    function testRegisterPositionOnlyOwner() public {
        vm.prank(user);
        vm.expectRevert();
        reactive.registerPosition(0, 1 ether, 1500e6);
    }
}
