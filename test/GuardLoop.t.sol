// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {AbstractCallback} from "@reactive/src/base/AbstractCallback.sol";
import {AbstractPayer} from "@reactive/src/base/AbstractPayer.sol";
import {IPayable} from "@reactive/src/interfaces/IPayable.sol";
import {IReactive} from "@reactive/src/interfaces/IReactive.sol";
import {ISystemContract} from "@reactive/src/interfaces/ISystemContract.sol";
import {MAX_ACTIVE_ORDERS, PriceTrigger} from "../src/GuardTypes.sol";
import {GuardReactive} from "../src/GuardReactive.sol";
import {GuardVault} from "../src/GuardVault.sol";
import {MockMarket, MockToken} from "../src/MockMarket.sol";

contract MockSystem {
    event CallbackRequest(
        uint256 indexed chainId,
        address indexed sender,
        address indexed recipient,
        ISystemContract.CallbackVersion version,
        bytes configuration
    );

    uint256 private constant IGNORE = 0xa65f96fc951c35ead38878e0f0b7a3c744a6f5ccc1476b313353ce31712313ad;
    mapping(bytes32 => bool) public subscribed;

    function subscribe(uint256 chainId, address emitter, uint256 topic0, uint256 topic1, uint256 topic2, uint256 topic3)
        external
    {
        require(topic1 == IGNORE && topic2 == IGNORE && topic3 == IGNORE);
        subscribed[keccak256(abi.encode(msg.sender, chainId, emitter, topic0))] = true;
    }

    function deliver(IReactive reactive, IReactive.LogRecord calldata source) external {
        require(subscribed[keccak256(abi.encode(reactive, source.chainId, source.contractAddress, source.topic0))]);
        reactive.react(source);
    }

    // forge-lint: disable-next-line(mixed-case-function)
    function requestCallbackV_1_0(ISystemContract.CallbackConfiguration_V_1_0 calldata config) external {
        emit CallbackRequest(
            config.chainId, msg.sender, config.recipient, ISystemContract.CallbackVersion.V_1_0, abi.encode(config)
        );
    }
}

contract MockCallbackProxy {
    function deliver(address reactive, address recipient, bytes memory payload) external {
        assembly ("memory-safe") {
            mstore(add(payload, 36), and(reactive, 0xffffffffffffffffffffffffffffffffffffffff))
        }
        (bool ok, bytes memory reason) = recipient.call(payload);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(reason, 32), mload(reason))
            }
        }
    }
}

contract GuardLoopTest is Test {
    address private constant SYSTEM = 0x8888888888888888888888888888888888888888;
    uint256 private constant DESTINATION = 1301;
    address private constant ALICE = address(0xA11CE);
    address private constant BOB = address(0xB0B);
    bytes32 private constant PRICE_TX = keccak256("simulated origin transaction");

    MockToken private base;
    MockToken private quote;
    MockMarket private market;
    MockCallbackProxy private proxy;
    GuardVault private vault;
    GuardReactive private reactive;

    function setUp() public {
        vm.etch(SYSTEM, address(new MockSystem()).code);
        base = new MockToken("Guard Base", "GBASE", ALICE, 100 ether);
        quote = new MockToken("Guard Quote", "GQUOTE", address(this), 100_000 ether);
        market = new MockMarket(base, quote, address(this), 100 ether);
        quote.transfer(address(market), 100_000 ether);
        proxy = new MockCallbackProxy();
        reactive = new GuardReactive(DESTINATION);
        vault = new GuardVault(IPayable(payable(address(proxy))), address(reactive), market);
        reactive.configure(address(vault), address(market));
        vm.prank(ALICE);
        base.approve(address(vault), type(uint256).max);
    }

    function testCreateEscrowsBaseAndTracksTheOrder() public {
        (uint256 id,) = _create(false, 90 ether, 2 ether);
        (address owner, uint8 slot, bool takeProfit, GuardVault.Status status, uint128 threshold, uint256 amount) =
            vault.orders(id);
        assertEq(owner, ALICE);
        assertEq(slot, 0);
        assertFalse(takeProfit);
        assertEq(uint256(status), uint256(GuardVault.Status.Open));
        assertEq(threshold, 90 ether);
        assertEq(amount, 2 ether);
        assertEq(address(vault.base()), address(base));
        assertEq(address(vault.quote()), address(quote));
        assertEq(base.balanceOf(ALICE), 98 ether);
        assertEq(base.balanceOf(address(vault)), 2 ether);
        (uint256 trackedId, uint128 trackedThreshold,, bool tracked) = reactive.watchedOrders(slot);
        assertEq(trackedId, id);
        assertEq(trackedThreshold, threshold);
        assertTrue(tracked);
    }

    function testOwnerCancelsAndGetsEscrowBack() public {
        (uint256 id,) = _create(false, 90 ether, 2 ether);
        vm.prank(BOB);
        vm.expectRevert(GuardVault.NotOrderOwner.selector);
        vault.cancelOrder(id);

        _cancel(id);
        assertEq(uint256(_status(id)), uint256(GuardVault.Status.Cancelled));
        assertEq(base.balanceOf(ALICE), 100 ether);
        assertEq(base.balanceOf(address(vault)), 0);
        assertEq(vault.activeOrderIds(0), 0);
        (,,, bool tracked) = reactive.watchedOrders(0);
        assertFalse(tracked);
        (, Vm.Log[] memory reaction) = _publish(80 ether);
        assertEq(_callbackCount(reaction), 0);
    }

    function testUncrossedThresholdsDoNotRequestOrExecute() public {
        (uint256 stop,) = _create(false, 90 ether, 1 ether);
        (uint256 profit,) = _create(true, 120 ether, 1 ether);
        (, Vm.Log[] memory reaction) = _publish(100 ether);
        assertEq(_callbackCount(reaction), 0);
        assertEq(uint256(_status(stop)), uint256(GuardVault.Status.Open));
        assertEq(uint256(_status(profit)), uint256(GuardVault.Status.Open));
        assertEq(quote.balanceOf(ALICE), 0);
    }

    function testStopLossExecutesAtThresholdAndCorrelatesOrigin() public {
        (uint256 id,) = _create(false, 90 ether, 2 ether);
        vm.warp(100);
        (, Vm.Log[] memory reaction) = _publish(90 ether);
        assertEq(_callbackCount(reaction), 1);
        vm.warp(104);
        IReactive.LogRecord memory execution = _settle(_request(reaction));
        (
            bytes32 txHash,
            uint256 logIndex,
            uint256 triggerTimestamp,
            uint256 triggerPrice,
            uint256 settlementPrice,
            uint256 quoteOut
        ) = abi.decode(execution.data, (bytes32, uint256, uint256, uint256, uint256, uint256));
        assertEq(execution.topic1, id);
        assertEq(txHash, PRICE_TX);
        assertEq(logIndex, 3);
        assertEq(triggerTimestamp, 100);
        assertEq(vm.getBlockTimestamp() - triggerTimestamp, 4);
        assertEq(triggerPrice, 90 ether);
        assertEq(settlementPrice, 90 ether);
        assertEq(quoteOut, 180 ether);
        assertEq(uint256(_status(id)), uint256(GuardVault.Status.Executed));
        assertEq(quote.balanceOf(ALICE), 180 ether);
        assertEq(base.balanceOf(address(vault)), 0);
        assertEq(base.balanceOf(address(market)), 2 ether);
    }

    function testTakeProfitExecutesAboveThreshold() public {
        (uint256 id,) = _create(true, 120 ether, 2 ether);
        (, Vm.Log[] memory reaction) = _publish(125 ether);
        assertEq(_callbackCount(reaction), 1);
        _settle(_request(reaction));
        assertEq(uint256(_status(id)), uint256(GuardVault.Status.Executed));
        assertEq(quote.balanceOf(ALICE), 250 ether);
    }

    function testWrongCallbackCallerCannotExecute() public {
        (uint256 id,) = _create(false, 110 ether, 1 ether);
        vm.expectRevert(abi.encodeWithSelector(AbstractPayer.NotAuthorized.selector, BOB, address(proxy)));
        vm.prank(BOB);
        vault.executeOrder(address(reactive), id, PriceTrigger(PRICE_TX, 0, 1, 100 ether));
    }

    function testProxyRejectsWrongReactiveIdentity() public {
        (uint256 id,) = _create(false, 110 ether, 1 ether);
        vm.expectRevert(abi.encodeWithSelector(AbstractCallback.CallbackNotAuthorized.selector, BOB, address(reactive)));
        vm.prank(address(proxy));
        vault.executeOrder(BOB, id, PriceTrigger(PRICE_TX, 0, 1, 100 ether));
    }

    function testDuplicatePriceAndCallbackCannotExecuteTwice() public {
        (uint256 id,) = _create(false, 90 ether, 1 ether);
        (IReactive.LogRecord memory priceLog, Vm.Log[] memory reaction) = _publish(85 ether);
        ISystemContract.CallbackConfiguration_V_1_0 memory request = _request(reaction);
        assertEq(_callbackCount(_deliver(priceLog)), 0);
        _settle(request);

        vm.recordLogs();
        proxy.deliver(address(reactive), request.recipient, request.payload);
        assertEq(vm.getRecordedLogs().length, 0);
        assertEq(uint256(_status(id)), uint256(GuardVault.Status.Executed));
        assertEq(quote.balanceOf(ALICE), 85 ether);

        (, reaction) = _publish(80 ether);
        assertEq(_callbackCount(reaction), 0);
    }

    function testPriceReversalBeforeDeliveryLeavesOrderOpen() public {
        (uint256 id,) = _create(false, 90 ether, 1 ether);
        (, Vm.Log[] memory reaction) = _publish(85 ether);
        ISystemContract.CallbackConfiguration_V_1_0 memory stale = _request(reaction);
        _publish(95 ether);
        proxy.deliver(address(reactive), stale.recipient, stale.payload);
        assertEq(uint256(_status(id)), uint256(GuardVault.Status.Open));
        assertEq(quote.balanceOf(ALICE), 0);

        (, reaction) = _publish(88 ether);
        _settle(_request(reaction));
        assertEq(quote.balanceOf(ALICE), 88 ether);
    }

    function testStaleCallbackAndLifecycleLogsCannotAffectReusedSlot() public {
        (uint256 oldId, IReactive.LogRecord memory oldCreate) = _create(false, 90 ether, 1 ether);
        (, Vm.Log[] memory reaction) = _publish(85 ether);
        ISystemContract.CallbackConfiguration_V_1_0 memory stale = _request(reaction);

        IReactive.LogRecord memory oldCancel = _cancel(oldId);
        (uint256 newId,) = _create(true, 120 ether, 1 ether);
        _deliver(oldCreate);
        _deliver(oldCancel);
        proxy.deliver(address(reactive), stale.recipient, stale.payload);
        assertEq(uint256(_status(oldId)), uint256(GuardVault.Status.Cancelled));
        assertEq(uint256(_status(newId)), uint256(GuardVault.Status.Open));
        assertEq(vault.activeOrderIds(0), newId);
        assertEq(quote.balanceOf(ALICE), 0);

        (, reaction) = _publish(130 ether);
        _settle(_request(reaction));
        assertEq(uint256(_status(newId)), uint256(GuardVault.Status.Executed));
        assertEq(quote.balanceOf(ALICE), 130 ether);
    }

    function testOnlySystemCanReactAndOnlyConfiguratorCanConfigure() public {
        IReactive.LogRecord memory source;
        vm.expectRevert(abi.encodeWithSelector(AbstractPayer.NotAuthorized.selector, BOB, SYSTEM));
        vm.prank(BOB);
        reactive.react(source);
        vm.expectRevert(GuardReactive.NotConfigurator.selector);
        vm.prank(BOB);
        reactive.configure(BOB, BOB);
        vm.expectRevert(GuardReactive.InvalidConfiguration.selector);
        reactive.configure(address(vault), address(market));
    }

    function testAllActiveOrdersCanRequestInOneCappedReaction() public {
        for (uint8 slot; slot < MAX_ACTIVE_ORDERS; ++slot) {
            _create(false, 90 ether, 1 ether);
        }
        vm.expectRevert(GuardVault.VaultFull.selector);
        vm.prank(ALICE);
        vault.createOrder(false, 90 ether, 1 ether);

        vm.recordLogs();
        market.publishPrice(85 ether);
        IReactive.LogRecord memory source = _origin(address(market), MockMarket.PriceUpdated.selector);
        vm.recordLogs();
        vm.prank(SYSTEM);
        reactive.react{gas: 900_000}(source);
        assertEq(_callbackCount(vm.getRecordedLogs()), MAX_ACTIVE_ORDERS);
    }

    function _create(bool takeProfit, uint128 threshold, uint256 amount)
        private
        returns (uint256 id, IReactive.LogRecord memory eventLog)
    {
        vm.recordLogs();
        vm.prank(ALICE);
        id = vault.createOrder(takeProfit, threshold, amount);
        eventLog = _origin(address(vault), GuardVault.OrderCreated.selector);
        _deliver(eventLog);
    }

    function _cancel(uint256 id) private returns (IReactive.LogRecord memory eventLog) {
        vm.recordLogs();
        vm.prank(ALICE);
        vault.cancelOrder(id);
        eventLog = _origin(address(vault), GuardVault.OrderCancelled.selector);
        _deliver(eventLog);
    }

    function _publish(uint256 newPrice)
        private
        returns (IReactive.LogRecord memory eventLog, Vm.Log[] memory reaction)
    {
        vm.recordLogs();
        market.publishPrice(newPrice);
        eventLog = _origin(address(market), MockMarket.PriceUpdated.selector);
        reaction = _deliver(eventLog);
    }

    function _origin(address emitter, bytes32 signature) private returns (IReactive.LogRecord memory eventLog) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            Vm.Log memory entry = logs[i];
            if (entry.emitter != emitter || entry.topics[0] != signature) continue;
            eventLog.chainId = DESTINATION;
            eventLog.contractAddress = emitter;
            eventLog.topic0 = uint256(signature);
            eventLog.topic1 = uint256(entry.topics[1]);
            if (entry.topics.length > 2) eventLog.topic2 = uint256(entry.topics[2]);
            if (entry.topics.length > 3) eventLog.topic3 = uint256(entry.topics[3]);
            eventLog.data = entry.data;
            eventLog.txHash = uint256(PRICE_TX);
            eventLog.logIndex = 3;
            return eventLog;
        }
        revert("origin log not found");
    }

    function _deliver(IReactive.LogRecord memory source) private returns (Vm.Log[] memory) {
        vm.recordLogs();
        MockSystem(SYSTEM).deliver(reactive, source);
        return vm.getRecordedLogs();
    }

    function _callbackCount(Vm.Log[] memory logs) private pure returns (uint256 count) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == SYSTEM && logs[i].topics[0] == MockSystem.CallbackRequest.selector) ++count;
        }
    }

    function _request(Vm.Log[] memory logs)
        private
        view
        returns (ISystemContract.CallbackConfiguration_V_1_0 memory request)
    {
        for (uint256 i; i < logs.length; ++i) {
            Vm.Log memory entry = logs[i];
            if (entry.emitter != SYSTEM || entry.topics[0] != MockSystem.CallbackRequest.selector) continue;
            assertEq(uint256(entry.topics[2]), uint256(uint160(address(reactive))));
            (ISystemContract.CallbackVersion version, bytes memory config) =
                abi.decode(entry.data, (ISystemContract.CallbackVersion, bytes));
            assertEq(uint256(version), uint256(ISystemContract.CallbackVersion.V_1_0));
            request = abi.decode(config, (ISystemContract.CallbackConfiguration_V_1_0));
            assertEq(request.chainId, DESTINATION);
            assertEq(request.recipient, address(vault));
            assertEq(request.gasLimit, reactive.CALLBACK_GAS_LIMIT());
            assertEq(bytes4(request.payload), GuardVault.executeOrder.selector);
            return request;
        }
        revert("callback request not found");
    }

    function _settle(ISystemContract.CallbackConfiguration_V_1_0 memory request)
        private
        returns (IReactive.LogRecord memory execution)
    {
        vm.recordLogs();
        proxy.deliver(address(reactive), request.recipient, request.payload);
        execution = _origin(address(vault), GuardVault.OrderExecuted.selector);
        _deliver(execution);
    }

    function _status(uint256 id) private view returns (GuardVault.Status status) {
        (,,, status,,) = vault.orders(id);
    }
}
