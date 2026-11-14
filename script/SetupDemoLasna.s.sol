// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Script, console } from "forge-std/Script.sol";
import { LiquidationReactive } from "../src/LiquidationReactive.sol";

/// @notice Step 4b (Lasna): point the reactive contract at the Guardian and
/// register the demo position for guarding (mirror: 1 mWETH / 1500 mUSDC).
/// Env: DEPLOYER_PRIVATE_KEY, REACTIVE, GUARDIAN, POSITION_ID
/// Usage: forge script script/SetupDemoLasna.s.sol --rpc-url https://lasna-rpc.rnk.dev/ --broadcast
contract SetupDemoLasna is Script {
    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        LiquidationReactive reactive = LiquidationReactive(payable(vm.envAddress("REACTIVE")));
        address guardian = vm.envAddress("GUARDIAN");
        uint256 pid = vm.envUint("POSITION_ID");

        vm.startBroadcast(pk);

        reactive.setRecipient(guardian);
        reactive.registerPosition(pid, 1 ether, 1500e6);

        vm.stopBroadcast();

        console.log("Recipient set to Guardian: ", guardian);
        console.log("Position registered: ", pid);
    }
}
