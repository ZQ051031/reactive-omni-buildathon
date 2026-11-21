// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

uint8 constant MAX_ACTIVE_ORDERS = 8;

struct PriceTrigger {
    bytes32 txHash;
    uint256 logIndex;
    uint256 timestamp;
    uint256 price;
}

function thresholdMet(bool takeProfit, uint256 price, uint256 threshold) pure returns (bool) {
    return takeProfit ? price >= threshold : price <= threshold;
}
