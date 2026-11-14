// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Script, console } from "forge-std/Script.sol";
import { MockToken } from "../src/MockToken.sol";
import { LendingVault } from "../src/LendingVault.sol";
import { Guardian } from "../src/Guardian.sol";

/// @notice Step 4a (Base Sepolia): mint demo collateral, open the demo
/// position (1 mWETH / 1500 mUSDC, HF 1.6 at $3000) and fund the Guardian
/// reserve with 1 mWETH.
/// Env: DEPLOYER_PRIVATE_KEY, WETH, VAULT, GUARDIAN
/// Usage: forge script script/SetupDemoBase.s.sol --rpc-url https://sepolia.base.org --broadcast
contract SetupDemoBase is Script {
    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(pk);
        MockToken weth = MockToken(vm.envAddress("WETH"));
        LendingVault vault = LendingVault(vm.envAddress("VAULT"));
        Guardian guardian = Guardian(payable(vm.envAddress("GUARDIAN")));

        vm.startBroadcast(pk);

        weth.mint(deployer, 2 ether);
        weth.approve(address(vault), 1 ether);
        uint256 pid = vault.openPosition(1 ether, 1500e6);
        weth.approve(address(guardian), 1 ether);
        guardian.depositReserve(1 ether);

        vm.stopBroadcast();

        console.log("Demo position id: ", pid);
        console.log("Health factor:    ", vault.healthFactor(pid));
        console.log("Guardian reserve: ", weth.balanceOf(address(guardian)));
    }
}
