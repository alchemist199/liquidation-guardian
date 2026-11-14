// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Script, console } from "forge-std/Script.sol";
import { MockToken } from "../src/MockToken.sol";
import { MockPriceFeed } from "../src/MockPriceFeed.sol";
import { LendingVault } from "../src/LendingVault.sol";

/// @notice Step 1 (Base Sepolia): deploy mocks + vault.
/// Env: DEPLOYER_PRIVATE_KEY
/// Usage: forge script script/DeployBase.s.sol --rpc-url https://sepolia.base.org --broadcast
contract DeployBase is Script {
    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        vm.startBroadcast(pk);

        MockToken weth = new MockToken("Mock WETH", "mWETH", 18);
        MockToken usdc = new MockToken("Mock USDC", "mUSDC", 6);
        MockPriceFeed feed = new MockPriceFeed(3000e8); // ETH/USD = $3000
        LendingVault vault = new LendingVault(address(weth), address(usdc), address(feed));
        usdc.setMinter(address(vault));

        vm.stopBroadcast();

        console.log("MockWETH:      ", address(weth));
        console.log("MockUSDC:      ", address(usdc));
        console.log("MockPriceFeed: ", address(feed));
        console.log("LendingVault:  ", address(vault));
    }
}
