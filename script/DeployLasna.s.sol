// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Script, console } from "forge-std/Script.sol";
import { LiquidationReactive } from "../src/LiquidationReactive.sol";

/// @notice Step 2 (Lasna testnet): deploy the reactive contract, funded with
/// lREACT so it can pay for reactive transactions.
/// Env: DEPLOYER_PRIVATE_KEY, PRICE_FEED (Base Sepolia MockPriceFeed address)
/// Usage: forge script script/DeployLasna.s.sol --rpc-url https://lasna-rpc.rnk.dev/ --broadcast
contract DeployLasna is Script {
    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address priceFeed = vm.envAddress("PRICE_FEED");
        vm.startBroadcast(pk);

        // Funding at deploy (payable constructor). Default 0.05 lREACT: a
        // triggering react() costs ~94k gas at 100 gwei (~0.0094 lREACT), so
        // 0.05 covers ~5 reactions. Override with REACTIVE_FUNDING_WEI.
        uint256 funding = vm.envOr("REACTIVE_FUNDING_WEI", uint256(0.05 ether));
        LiquidationReactive reactive = new LiquidationReactive{ value: funding }(84532, priceFeed);

        vm.stopBroadcast();

        console.log("LiquidationReactive: ", address(reactive));
        console.log("Subscribed to PriceUpdated on Base Sepolia feed:", priceFeed);
    }
}
