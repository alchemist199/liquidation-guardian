// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { IPayable } from "@reactive/src/interfaces/IPayable.sol";
import { AbstractCallback } from "@reactive/src/base/AbstractCallback.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { LendingVault } from "./LendingVault.sol";

/// @title Guardian — the callback contract (Base Sepolia).
/// @notice Holds a collateral reserve. When the reactive contract requests a
/// rescue, tops the position up from the reserve — but only while the on-chain
/// health factor is still below the trigger (defense in depth against stale
/// triggers). Never reverts on a bad rescue: it no-ops and emits RescueSkipped,
/// because a failed callback still bills the recipient.
/// Auth: only the callback proxy may call, and only for the authorized
/// reactive contract (both modifiers, always).
contract Guardian is AbstractCallback, Ownable {
    event Rescued(uint256 indexed positionId, uint256 topUpAmount, uint256 newHealthFactor);
    event RescueSkipped(uint256 indexed positionId, uint256 healthFactor);
    event ReserveDeposited(address indexed from, uint256 amount);
    event TriggerHFUpdated(uint256 triggerHF);

    LendingVault public immutable vault;
    IERC20 public immutable collateral;
    uint256 public triggerHF;

    constructor(IPayable callbackProxy_, address callbackSender_, address vault_, uint256 triggerHF_)
        payable
        AbstractCallback(callbackProxy_, callbackSender_)
        Ownable(msg.sender)
    {
        vault = LendingVault(vault_);
        collateral = IERC20(vault.collateral());
        triggerHF = triggerHF_;
    }

    /// @notice Top a position up from the reserve. Called by the callback proxy;
    /// `reactive_` is the address the proxy injected (the requesting contract).
    function rescue(address reactive_, uint256 positionId, uint256 amount)
        external
        onlyServiceProvider
        onlyCallbackSender(reactive_)
    {
        (,,, bool active) = vault.positions(positionId);
        if (!active) {
            emit RescueSkipped(positionId, 0);
            return;
        }
        uint256 hf = vault.healthFactor(positionId);
        if (hf >= triggerHF) {
            emit RescueSkipped(positionId, hf);
            return;
        }
        uint256 reserve = collateral.balanceOf(address(this));
        if (reserve == 0 || amount == 0) {
            emit RescueSkipped(positionId, hf);
            return;
        }
        uint256 topUpAmount = amount > reserve ? reserve : amount;
        collateral.approve(address(vault), topUpAmount);
        vault.topUp(positionId, topUpAmount);
        emit Rescued(positionId, topUpAmount, vault.healthFactor(positionId));
    }

    /// @notice Fund the rescue reserve (anyone may deposit collateral).
    function depositReserve(uint256 amount) external {
        collateral.transferFrom(msg.sender, address(this), amount);
        emit ReserveDeposited(msg.sender, amount);
    }

    function setTriggerHF(uint256 triggerHF_) external onlyOwner {
        triggerHF = triggerHF_;
        emit TriggerHFUpdated(triggerHF_);
    }

    function withdrawReserve(uint256 amount) external onlyOwner {
        collateral.transfer(msg.sender, amount);
    }

    /// @notice Settles outstanding callback debt from this contract's balance.
    function coverDebt() external {
        _coverDebt();
    }
}
