// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { AggregatorV3Interface } from "./MockPriceFeed.sol";
import { MockToken } from "./MockToken.sol";

/// @title Minimal lending vault with health-factor accounting (testnet demo).
/// @notice A position = collateral (mWETH, 18 dec) + debt (mUSDC, 6 dec).
/// Health factor (1e18 scale) = collateralValue * liquidationThreshold / debtValue.
/// The Guardian tops a position up through `topUp()`; anyone may liquidate a
/// position whose health factor fell below 1.0.
contract LendingVault is Ownable {
    uint256 public constant LIQUIDATION_THRESHOLD_BPS = 8000; // 80%
    uint256 public constant MIN_OPEN_HF = 1.1e18; // positions must open at HF >= 1.1
    uint256 public constant LIQUIDATION_BONUS_BPS = 500; // 5% bonus for the liquidator

    IERC20 public immutable collateral;
    MockToken public immutable debt;
    AggregatorV3Interface public immutable priceFeed;

    struct Position {
        address owner;
        uint256 collateral;
        uint256 debt;
        bool active;
    }

    mapping(uint256 => Position) public positions;
    uint256 public nextPositionId;

    event PositionOpened(uint256 indexed positionId, address indexed owner, uint256 collateral, uint256 debt);
    event TopUp(uint256 indexed positionId, address indexed from, uint256 amount);
    event Repaid(uint256 indexed positionId, uint256 amount);
    event CollateralWithdrawn(uint256 indexed positionId, address indexed owner, uint256 amount);
    event Liquidated(uint256 indexed positionId, address indexed liquidator, uint256 debtRepaid, uint256 seized);

    constructor(address collateral_, address debt_, address priceFeed_) Ownable(msg.sender) {
        collateral = IERC20(collateral_);
        debt = MockToken(debt_);
        priceFeed = AggregatorV3Interface(priceFeed_);
    }

    /// @notice Current collateral price (8 decimals, must be > 0).
    function price() public view returns (uint256) {
        (, int256 answer,,,) = priceFeed.latestRoundData();
        require(answer > 0, "bad price");
        return uint256(answer);
    }

    /// @notice Collateral value in USD, 18 decimals.
    function collateralValueUsd(uint256 collateralAmount) public view returns (uint256) {
        return (collateralAmount * price()) / 1e8;
    }

    /// @notice Debt value in USD, 18 decimals (debt token has 6 decimals).
    function debtValueUsd(uint256 debtAmount) public pure returns (uint256) {
        return debtAmount * 1e12;
    }

    /// @notice Health factor, 1e18 scale. type(uint256).max when there is no debt.
    function healthFactor(uint256 positionId) public view returns (uint256) {
        Position storage pos = positions[positionId];
        require(pos.active, "no such position");
        if (pos.debt == 0) return type(uint256).max;
        uint256 value = collateralValueUsd(pos.collateral);
        return (value * LIQUIDATION_THRESHOLD_BPS * 1e18) / (10000 * debtValueUsd(pos.debt));
    }

    function getPosition(uint256 positionId) external view returns (Position memory) {
        return positions[positionId];
    }

    /// @notice Deposit collateral and borrow debt tokens (minted to the caller).
    function openPosition(uint256 collateralAmount, uint256 borrowAmount) external returns (uint256 positionId) {
        require(collateralAmount > 0 && borrowAmount > 0, "amounts must be > 0");
        positionId = nextPositionId++;
        collateral.transferFrom(msg.sender, address(this), collateralAmount);
        positions[positionId] =
            Position({ owner: msg.sender, collateral: collateralAmount, debt: borrowAmount, active: true });
        debt.mint(msg.sender, borrowAmount);
        require(healthFactor(positionId) >= MIN_OPEN_HF, "HF too low to open");
        emit PositionOpened(positionId, msg.sender, collateralAmount, borrowAmount);
    }

    /// @notice Add collateral to a position. Anyone may call (the Guardian does).
    function topUp(uint256 positionId, uint256 amount) external {
        Position storage pos = positions[positionId];
        require(pos.active, "no such position");
        require(amount > 0, "amount must be > 0");
        collateral.transferFrom(msg.sender, address(this), amount);
        pos.collateral += amount;
        emit TopUp(positionId, msg.sender, amount);
    }

    /// @notice Repay (part of) the debt. Debt tokens are burned from the caller.
    function repay(uint256 positionId, uint256 amount) external {
        Position storage pos = positions[positionId];
        require(pos.active, "no such position");
        uint256 toRepay = amount > pos.debt ? pos.debt : amount;
        require(toRepay > 0, "nothing to repay");
        debt.burnFrom(msg.sender, toRepay);
        pos.debt -= toRepay;
        emit Repaid(positionId, toRepay);
    }

    /// @notice Withdraw collateral (position owner only, HF must stay >= 1.1).
    function withdrawCollateral(uint256 positionId, uint256 amount) external {
        Position storage pos = positions[positionId];
        require(pos.active, "no such position");
        require(msg.sender == pos.owner, "not owner");
        require(amount <= pos.collateral, "insufficient collateral");
        pos.collateral -= amount;
        require(healthFactor(positionId) >= MIN_OPEN_HF, "HF too low");
        collateral.transfer(msg.sender, amount);
        emit CollateralWithdrawn(positionId, msg.sender, amount);
    }

    /// @notice Liquidate a position with HF < 1.0: repay the full debt, seize
    /// collateral worth debt + 5% bonus, return the remainder to the owner.
    function liquidate(uint256 positionId) external {
        Position storage pos = positions[positionId];
        require(pos.active, "no such position");
        require(healthFactor(positionId) < 1e18, "position is healthy");
        uint256 debtAmount = pos.debt;
        debt.burnFrom(msg.sender, debtAmount);
        uint256 seizeValue = (debtValueUsd(debtAmount) * (10000 + LIQUIDATION_BONUS_BPS)) / 10000;
        uint256 seize = (seizeValue * 1e8) / price();
        if (seize > pos.collateral) seize = pos.collateral;
        uint256 remainder = pos.collateral - seize;
        pos.collateral = 0;
        pos.debt = 0;
        pos.active = false;
        if (seize > 0) collateral.transfer(msg.sender, seize);
        if (remainder > 0) collateral.transfer(pos.owner, remainder);
        emit Liquidated(positionId, msg.sender, debtAmount, seize);
    }
}
