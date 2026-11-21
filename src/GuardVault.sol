// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {AbstractCallback} from "@reactive/src/base/AbstractCallback.sol";
import {IPayable} from "@reactive/src/interfaces/IPayable.sol";
import {MAX_ACTIVE_ORDERS, PriceTrigger, thresholdMet} from "./GuardTypes.sol";
import {MockMarket} from "./MockMarket.sol";

contract GuardVault is AbstractCallback, ReentrancyGuard {
    using SafeERC20 for IERC20;

    enum Status {
        Unset,
        Open,
        Cancelled,
        Executed
    }

    struct Order {
        address owner;
        uint8 slot;
        bool takeProfit;
        Status status;
        uint128 threshold;
        uint256 amount;
    }

    error InvalidSetup();
    error InvalidOrder();
    error VaultFull();
    error NotOrderOwner();
    error NotOpen();

    event OrderCreated(
        uint256 indexed orderId,
        uint8 indexed slot,
        address indexed owner,
        bool takeProfit,
        uint128 threshold,
        uint256 amount
    );
    event OrderCancelled(uint256 indexed orderId, uint8 indexed slot, address indexed owner, uint256 amount);
    event OrderExecuted(
        uint256 indexed orderId,
        uint8 indexed slot,
        address indexed owner,
        bytes32 triggerTxHash,
        uint256 triggerLogIndex,
        uint256 triggerTimestamp,
        uint256 triggerPrice,
        uint256 settlementPrice,
        uint256 quoteOut
    );

    MockMarket public immutable market;
    IERC20 public immutable base;
    IERC20 public immutable quote;
    uint256 public lastOrderId;
    mapping(uint256 => Order) public orders;
    uint256[MAX_ACTIVE_ORDERS] public activeOrderIds;

    constructor(IPayable proxy, address reactive, MockMarket market_) payable AbstractCallback(proxy, reactive) {
        if (address(proxy) == address(0) || reactive == address(0) || address(market_).code.length == 0) {
            revert InvalidSetup();
        }
        market = market_;
        base = market_.base();
        quote = market_.quote();
    }

    function createOrder(bool takeProfit, uint128 threshold, uint256 amount)
        external
        nonReentrant
        returns (uint256 orderId)
    {
        if (threshold == 0 || amount == 0) revert InvalidOrder();
        uint8 slot;
        while (slot < MAX_ACTIVE_ORDERS && activeOrderIds[slot] != 0) ++slot;
        if (slot == MAX_ACTIVE_ORDERS) revert VaultFull();

        orderId = ++lastOrderId;
        activeOrderIds[slot] = orderId;
        orders[orderId] = Order(msg.sender, slot, takeProfit, Status.Open, threshold, amount);
        base.safeTransferFrom(msg.sender, address(this), amount);
        emit OrderCreated(orderId, slot, msg.sender, takeProfit, threshold, amount);
    }

    function cancelOrder(uint256 orderId) external nonReentrant {
        Order storage order = orders[orderId];
        if (order.owner != msg.sender) revert NotOrderOwner();
        if (order.status != Status.Open) revert NotOpen();

        _close(order, Status.Cancelled);
        base.safeTransfer(order.owner, order.amount);
        emit OrderCancelled(orderId, order.slot, order.owner, order.amount);
    }

    function executeOrder(address reactive, uint256 orderId, PriceTrigger calldata trigger)
        external
        onlyServiceProvider
        onlyCallbackSender(reactive)
        nonReentrant
    {
        Order storage order = orders[orderId];
        if (order.status != Status.Open) return;

        uint256 settlementPrice = market.price();
        if (
            !thresholdMet(order.takeProfit, trigger.price, order.threshold)
                || !thresholdMet(order.takeProfit, settlementPrice, order.threshold)
        ) return;

        _close(order, Status.Executed);
        base.forceApprove(address(market), order.amount);
        uint256 quoteOut = market.sell(order.amount, order.owner);
        emit OrderExecuted(
            orderId,
            order.slot,
            order.owner,
            trigger.txHash,
            trigger.logIndex,
            trigger.timestamp,
            trigger.price,
            settlementPrice,
            quoteOut
        );
    }

    function _close(Order storage order, Status status) private {
        order.status = status;
        delete activeOrderIds[order.slot];
    }
}
