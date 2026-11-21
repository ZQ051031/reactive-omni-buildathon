// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {AbstractReactive} from "@reactive/src/base/AbstractReactive.sol";
import {ISystemContract} from "@reactive/src/interfaces/ISystemContract.sol";
import {MAX_ACTIVE_ORDERS, PriceTrigger, thresholdMet} from "./GuardTypes.sol";
import {GuardVault} from "./GuardVault.sol";
import {MockMarket} from "./MockMarket.sol";

contract GuardReactive is AbstractReactive {
    struct WatchedOrder {
        uint256 orderId;
        uint128 threshold;
        bool takeProfit;
        bool active;
    }

    error NotConfigurator();
    error InvalidConfiguration();

    event SubscriptionsConfigured(uint256 indexed destinationChainId, address indexed vault, address indexed market);
    event OrderTrackingChanged(uint256 indexed orderId, uint8 indexed slot, bool active);
    event PriceObserved(uint256 indexed sequence, uint256 price);
    event SettlementRequested(uint256 indexed orderId, bytes32 indexed triggerTxHash, uint256 indexed triggerLogIndex);

    uint64 public constant CALLBACK_GAS_LIMIT = 300_000;
    address public immutable configurator;
    uint256 public immutable destinationChainId;
    address public vault;
    address public market;
    uint256 public lastPriceSequence;
    WatchedOrder[MAX_ACTIVE_ORDERS] public watchedOrders;

    constructor(uint256 destinationChainId_) payable {
        if (destinationChainId_ == 0) revert InvalidConfiguration();
        destinationChainId = destinationChainId_;
        configurator = msg.sender;
    }

    function configure(address vault_, address market_) external {
        if (msg.sender != configurator) revert NotConfigurator();
        if (vault != address(0) || vault_ == address(0) || market_ == address(0) || vault_ == market_) {
            revert InvalidConfiguration();
        }

        vault = vault_;
        market = market_;
        _subscribe(vault_, GuardVault.OrderCreated.selector);
        _subscribe(vault_, GuardVault.OrderCancelled.selector);
        _subscribe(vault_, GuardVault.OrderExecuted.selector);
        _subscribe(market_, MockMarket.PriceUpdated.selector);
        emit SubscriptionsConfigured(destinationChainId, vault_, market_);
    }

    function react(LogRecord calldata source) external override onlySystem {
        if (vault == address(0) || source.chainId != destinationChainId) return;
        bytes32 topic = bytes32(source.topic0);
        if (source.contractAddress == vault) {
            if (source.topic2 >= MAX_ACTIVE_ORDERS) return;
            uint8 slot = uint8(source.topic2);
            WatchedOrder storage watched = watchedOrders[slot];
            uint256 orderId = source.topic1;

            if (topic == GuardVault.OrderCreated.selector && orderId > watched.orderId) {
                (bool takeProfit, uint128 threshold,) = abi.decode(source.data, (bool, uint128, uint256));
                watchedOrders[slot] = WatchedOrder(orderId, threshold, takeProfit, true);
                emit OrderTrackingChanged(orderId, slot, true);
            } else if (
                (topic == GuardVault.OrderCancelled.selector || topic == GuardVault.OrderExecuted.selector)
                    && (orderId > watched.orderId || (orderId == watched.orderId && watched.active))
            ) {
                watchedOrders[slot] = WatchedOrder(orderId, 0, false, false);
                emit OrderTrackingChanged(orderId, slot, false);
            }
        } else if (
            source.contractAddress == market && topic == MockMarket.PriceUpdated.selector
                && source.topic1 > lastPriceSequence
        ) {
            (uint256 price, uint256 timestamp) = abi.decode(source.data, (uint256, uint256));
            lastPriceSequence = source.topic1;
            emit PriceObserved(source.topic1, price);
            PriceTrigger memory trigger = PriceTrigger(bytes32(source.txHash), source.logIndex, timestamp, price);
            for (uint8 slot; slot < MAX_ACTIVE_ORDERS; ++slot) {
                WatchedOrder memory watched = watchedOrders[slot];
                if (watched.active && thresholdMet(watched.takeProfit, price, watched.threshold)) {
                    _requestSettlement(watched.orderId, trigger);
                }
            }
        }
    }

    function _requestSettlement(uint256 orderId, PriceTrigger memory trigger) private {
        bytes memory payload = abi.encodeCall(GuardVault.executeOrder, (address(0), orderId, trigger));
        SYSTEM.requestCallbackV_1_0(
            ISystemContract.CallbackConfiguration_V_1_0(destinationChainId, vault, CALLBACK_GAS_LIMIT, payload)
        );
        emit SettlementRequested(orderId, trigger.txHash, trigger.logIndex);
    }

    function _subscribe(address emitter, bytes32 topic) private {
        SYSTEM.subscribe(destinationChainId, emitter, uint256(topic), REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
    }
}
