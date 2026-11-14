// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Script, console } from "forge-std/Script.sol";
import { IPayable } from "@reactive/src/interfaces/IPayable.sol";
import { Guardian } from "../src/Guardian.sol";

/// @notice Step 3 (Base Sepolia): deploy the Guardian callback contract,
/// funded with SepETH so it can pay for callback execution.
/// Env: DEPLOYER_PRIVATE_KEY, REACTIVE (Lasna LiquidationReactive address),
///      VAULT (Base Sepolia LendingVault address)
/// Usage: forge script script/DeployGuardian.s.sol --rpc-url https://sepolia.base.org --broadcast
contract DeployGuardian is Script {
    // Base Sepolia callback proxy (from Reactive docs).
    address payable internal constant CALLBACK_PROXY = payable(0x476F44b11F5C942c58f4c8E3d0300E5710743585);

    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address reactive = vm.envAddress("REACTIVE");
        address vault = vm.envAddress("VAULT");
        vm.startBroadcast(pk);

        // Funding at deploy (payable constructor). Default 0.0005 SepETH:
        // a rescue() callback costs ~200k gas at ~0.01 gwei (~0.000002
        // SepETH), so 0.0005 funds ~250 callbacks. Override with
        // GUARDIAN_FUNDING_WEI if a bigger reserve is ever needed.
        uint256 funding = vm.envOr("GUARDIAN_FUNDING_WEI", uint256(0.0005 ether));
        Guardian guardian = new Guardian{ value: funding }(
            IPayable(CALLBACK_PROXY), reactive, vault, 1.2e18
        );

        vm.stopBroadcast();

        console.log("Guardian: ", address(guardian));
        console.log("Callback proxy: ", CALLBACK_PROXY);
        console.log("Authorized reactive: ", reactive);
    }
}
