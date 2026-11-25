// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

/// @notice Minimal Chainlink AggregatorV3 interface (subset actually used).
interface AggregatorV3Interface {
    function decimals() external view returns (uint8);
    function description() external view returns (string memory);
    function version() external view returns (uint256);
    function getRoundData(uint80 _roundId)
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

/// @notice Chainlink-compatible mock price feed (8 decimals, like ETH/USD).
/// The owner moves the price; every move emits PriceUpdated, the event the
/// reactive contract subscribes to. In production this would be the real
/// Chainlink feed (same interface, no code change in the vault).
contract MockPriceFeed is AggregatorV3Interface, Ownable {
    event PriceUpdated(int256 price, uint256 timestamp);

    uint8 public constant override decimals = 8;
    int256 private _price;
    uint80 private _roundId;
    uint256 private _updatedAt;

    constructor(int256 initialPrice) Ownable(msg.sender) {
        _setPrice(initialPrice);
    }

    function description() external pure override returns (string memory) {
        return "Mock ETH/USD";
    }

    function version() external pure override returns (uint256) {
        return 1;
    }

    function latestRoundData() external view override returns (uint80, int256, uint256, uint256, uint80) {
        return (_roundId, _price, _updatedAt, _updatedAt, _roundId);
    }

    function getRoundData(uint80 roundId_)
        external
        view
        override
        returns (uint80, int256, uint256, uint256, uint80)
    {
        require(roundId_ == _roundId, "no such round");
        return (_roundId, _price, _updatedAt, _updatedAt, _roundId);
    }

    function setPrice(int256 newPrice) external onlyOwner {
        _setPrice(newPrice);
    }

    function _setPrice(int256 newPrice) internal {
        require(newPrice > 0, "price must be > 0");
        _price = newPrice;
        _roundId += 1;
        _updatedAt = block.timestamp;
        emit PriceUpdated(newPrice, block.timestamp);
    }
}
