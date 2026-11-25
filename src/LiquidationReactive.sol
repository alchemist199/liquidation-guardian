// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { ISystemContract } from "@reactive/src/interfaces/ISystemContract.sol";
import { IReactive } from "@reactive/src/interfaces/IReactive.sol";
import { AbstractReactive } from "@reactive/src/base/AbstractReactive.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

/// @title LiquidationReactive, the reactive contract (Lasna testnet).
/// @notice Subscribes to PriceUpdated events from the price feed on Base
/// Sepolia. On every price move it recomputes the health factor of each
/// guarded position from its mirrored state; when a position falls below the
/// trigger it requests a callback to the Guardian, which tops the position up
/// from its reserve before the position can be liquidated.
///
/// The mirror is updated optimistically when a rescue is requested (the
/// callback is expected to land); the Guardian re-checks the on-chain health
/// factor before spending reserve, so a stale trigger is harmless.
/// A per-position cooldown stops repeated callbacks while the price keeps
/// ticking below the trigger. `react()` never reverts as a filter: a revert
/// is still billed, so unhealthy logs just fall through.
contract LiquidationReactive is AbstractReactive, Ownable {
    uint256 public constant PRICE_UPDATED_TOPIC0 = uint256(keccak256("PriceUpdated(int256,uint256)"));
    uint256 public constant LIQUIDATION_THRESHOLD_BPS = 8000; // 80%, mirrors the vault
    uint64 private constant CALLBACK_GAS_LIMIT = 1_000_000;

    event PositionRegistered(uint256 indexed positionId, uint256 collateral, uint256 debt);
    event RescueRequested(uint256 indexed positionId, uint256 topUpAmount, uint256 healthFactor);
    event RecipientUpdated(address recipient);
    event ThresholdsUpdated(uint256 triggerHF, uint256 targetHF);

    struct GuardedPosition {
        uint256 collateral; // 18 decimals
        uint256 debt; // 6 decimals
        uint256 lastRescue;
        bool active;
    }

    uint256 public immutable originChainId;
    address public immutable priceFeed;
    address public recipient;
    uint256 public triggerHF = 1.2e18;
    uint256 public targetHF = 1.5e18;
    uint256 public cooldown = 60; // seconds between rescues of the same position

    mapping(uint256 => GuardedPosition) public guarded;
    uint256[] public positionIds;

    constructor(uint256 originChainId_, address priceFeed_) payable Ownable(msg.sender) {
        originChainId = originChainId_;
        priceFeed = priceFeed_;
        SYSTEM.subscribe(originChainId_, priceFeed_, PRICE_UPDATED_TOPIC0, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
    }

    function setRecipient(address recipient_) external onlyOwner {
        recipient = recipient_;
        emit RecipientUpdated(recipient_);
    }

    function setThresholds(uint256 triggerHF_, uint256 targetHF_) external onlyOwner {
        require(triggerHF_ < targetHF_, "trigger must be < target");
        triggerHF = triggerHF_;
        targetHF = targetHF_;
        emit ThresholdsUpdated(triggerHF_, targetHF_);
    }

    function setCooldown(uint256 cooldown_) external onlyOwner {
        cooldown = cooldown_;
    }

    function registerPosition(uint256 positionId, uint256 collateral, uint256 debt) external onlyOwner {
        if (!guarded[positionId].active) {
            positionIds.push(positionId);
        }
        guarded[positionId] = GuardedPosition({ collateral: collateral, debt: debt, lastRescue: 0, active: true });
        emit PositionRegistered(positionId, collateral, debt);
    }

    function updatePosition(uint256 positionId, uint256 collateral, uint256 debt) external onlyOwner {
        require(guarded[positionId].active, "not guarded");
        guarded[positionId].collateral = collateral;
        guarded[positionId].debt = debt;
    }

    function unregisterPosition(uint256 positionId) external onlyOwner {
        guarded[positionId].active = false;
    }

    /// @notice Settles outstanding debt to the system contract from this balance.
    function coverDebt() external {
        _coverDebt();
    }

    /// @inheritdoc IReactive
    function react(LogRecord calldata log_) external onlySystem {
        if (log_.topic0 != PRICE_UPDATED_TOPIC0 || log_.opCode != 1) return;
        if (recipient == address(0)) return;
        (int256 price,) = abi.decode(log_.data, (int256, uint256));
        if (price <= 0) return;
        uint256 priceU = uint256(price);
        uint256 len = positionIds.length;
        for (uint256 i = 0; i < len; i++) {
            uint256 pid = positionIds[i];
            GuardedPosition storage pos = guarded[pid];
            if (!pos.active) continue;
            if (pos.debt == 0) continue;
            if (pos.lastRescue != 0 && block.timestamp < pos.lastRescue + cooldown) continue;
            uint256 hf = _healthFactor(pos.collateral, pos.debt, priceU);
            if (hf >= triggerHF) continue;
            uint256 topUp = _topUpFor(pos.collateral, pos.debt, priceU);
            if (topUp == 0) continue;
            pos.collateral += topUp;
            pos.lastRescue = block.timestamp;
            bytes memory payload =
                abi.encodeWithSignature("rescue(address,uint256,uint256)", address(0), pid, topUp);
            SYSTEM.requestCallbackV_1_0(
                ISystemContract.CallbackConfiguration_V_1_0({
                    chainId: originChainId,
                    recipient: recipient,
                    gasLimit: CALLBACK_GAS_LIMIT,
                    payload: payload
                })
            );
            emit RescueRequested(pid, topUp, hf);
        }
    }

    /// @notice Health factor, 1e18 scale, at a given price (8 decimals).
    function _healthFactor(uint256 collateral_, uint256 debt_, uint256 price_) internal pure returns (uint256) {
        uint256 collateralValue = (collateral_ * price_) / 1e8; // 18-dec USD
        uint256 debtValue = debt_ * 1e12; // 6 -> 18 dec USD
        return (collateralValue * LIQUIDATION_THRESHOLD_BPS * 1e18) / (10000 * debtValue);
    }

    /// @notice Collateral (18 dec) needed to bring the position back to targetHF.
    function _topUpFor(uint256 collateral_, uint256 debt_, uint256 price_) internal view returns (uint256) {
        uint256 debtValue = debt_ * 1e12;
        uint256 neededValue = (targetHF * debtValue * 10000) / (1e18 * LIQUIDATION_THRESHOLD_BPS);
        uint256 currentValue = (collateral_ * price_) / 1e8;
        if (neededValue <= currentValue) return 0;
        return ((neededValue - currentValue) * 1e8) / price_;
    }
}
