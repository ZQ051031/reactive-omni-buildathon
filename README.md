# Reactive Guard

Reactive Guard is a testnet prototype for unattended stop-loss and take-profit orders. A user escrows a base token in a vault, chooses a price threshold and amount, and receives quote tokens if the order settles. Otherwise, the owner can cancel and reclaim the escrow.

- **Every Second Counts:** A price event feeds a bounded Reactive decision and a single asynchronous callback per qualifying order. The event and settlement can be correlated on-chain.
- **Set It and Forget It:** After setup, the user doesn't have to watch prices, submit a settlement transaction, or run a keeper or bot. The mock price reporter supplies demo market data; it never decides or executes orders.

## Architecture

```text
Unichain Sepolia or Base Sepolia                       Reactive Lasna
┌──────────────────────────────────┐                  ┌─────────────────────────────┐
│ User → GuardVault                │ ── order logs ──► │ GuardReactive               │
│   create/cancel, escrow BASE    │                  │ System calls react(log)     │
│                                  │                  │ Track open orders/check     │
│ MockMarket                       │ ── PriceUpdated ► │ thresholds; request callback│
│   demo price feed and swap       │                  └─────────────────────────────┘
│                                  │                              │
│ GuardVault.executeOrder          │ ◄── destination proxy ◄─────┘
│   recheck price, sell escrow,   │
│   pay owner QUOTE, emit event   │ ── execution log back to Lasna
└──────────────────────────────────┘
```

- **`GuardVault`** serves one immutable base/quote pair. Anyone can create their own order using their own approved base tokens; only its owner can cancel it. A stop-loss matches at or below the threshold; a take-profit matches at or above it. The first qualifying update observed after order registration can trigger execution; there is no requirement for a previous tick on the opposite side. Creating an order itself does not trigger execution.
- **`GuardReactive`** subscribes to that vault's creation, cancellation and execution events and to the market's `PriceUpdated` event. It mirrors up to eight active order slots, bounds the work per update and ignores replayed price sequences and superseded lifecycle logs. It sends the order ID and the trigger's transaction hash, log index, timestamp and price in its callback.
- **`MockMarket`** is both the price feed and the settlement venue for two demo ERC-20s. The configured demo reporter publishes a price in quote units per base unit, scaled by `1e18`. The market pays `floor(baseAmount × livePrice / 1e18)` from pre-seeded reserves. Both demo tokens have 18 decimals.

The vault authenticates both the proxy caller and the network-injected Reactive contract address. It rechecks the live price before trading, and duplicate, cancelled or no-longer-qualifying callbacks do not move funds. A reverted sale (e.g. insufficient quote reserves) leaves the order open. A new qualifying price update can retry an open order; there is no separate timer-based retry. Multiple different ticks can request settlement before the execution log reaches Lasna; only the first successful callback can fill the order.

**Prototype limits:** The price feed is centrally controlled for a repeatable demo; this is not a production oracle, AMM, or audited vault. The stop is a trigger, not a guaranteed sale price. There is no minimum-output protection. Native callback funding and demo quote liquidity are separate; fee reserves must stay funded and even an unsuccessful delivery can cost testnet gas. Run a separate pair of vault/Reactive contracts for each market or destination chain.

### Current Reactive API vs. older examples

The [current Reactive Contracts guide](https://dev.reactive.network/reactive-contracts) and [Callback Contracts guide](https://dev.reactive.network/callback-contracts) use the official [`reactive-lib-omni`](https://github.com/Reactive-Network/reactive-lib-omni/tree/v0.1.0). This entry follows those docs. The older [official smart-contract demos](https://github.com/Reactive-Network/reactive-smart-contract-demos) show the legacy `reactive-lib`, `vmOnly`, `emit Callback(...)` and an injected RVM ID. Here `AbstractReactive` uses `SYSTEM.subscribe` and `onlySystem`, and requests callbacks with `SYSTEM.requestCallbackV_1_0`. The reserved first `address` is replaced with the **requesting Reactive contract's address**, not the deployer or legacy RVM ID. The destination inherits `AbstractCallback` and checks `onlyServiceProvider` and `onlyCallbackSender`. See the [network table](https://dev.reactive.network/origins-and-destinations) and [fee/debt guide](https://dev.reactive.network/economy).

## Build and test locally

Use [Foundry](https://getfoundry.sh/) (tested with v1.10.0), Solidity 0.8.29, and the pinned Git submodules. No funded wallet, RPC, or environment file is needed for local tests.

```bash
git clone --recurse-submodules https://github.com/ZQ051031/reactive-omni-buildathon.git
cd reactive-omni-buildathon
# If cloned without --recurse-submodules:
git submodule update --init --recursive
forge build
forge test -vv
```

The suite captures the actual vault/market log topics and data, forwards them as Omni `LogRecord`s through a mock System Contract, captures the requested payload, and delivers it through a mock proxy that substitutes the first address. Tests cover escrow, owner cancellation, both threshold directions, non-qualifying updates, callback authentication, duplicates, price reversal, stale events on slot reuse, and the bounded active-order loop. This models protocol calls; it does not test real relay infrastructure or fees.

## Testnet deployment (not performed)

**NOT DEPLOYED — no deployer key available.** No existing funded testnet deployer was exposed through this environment's deployer/wallet variables. No wallet, key, or mnemonic was created or accessed. No application contract addresses, deployment transaction hashes, or public-network latency samples are available.

The addresses below are **Reactive infrastructure**, not Reactive Guard deployments:

| Network | Chain ID | System contract / callback proxy |
| --- | ---: | --- |
| Reactive Lasna | 5318007 | `0x8888888888888888888888888888888888888888` |
| Unichain Sepolia | 1301 | `0x775c9B990ADe401060B78D0e98684eEf8d2466C1` |
| Base Sepolia | 84532 | `0x476F44b11F5C942c58f4c8E3d0300E5710743585` |

The scripts refuse mainnet. Run these only with **already-funded testnet signers** and testnet funds. The commands assume existing Foundry account aliases; do not create or export keys for this project. Set funding amounts in wei based on available testnet funds (the demo script forwards these as native contract balances). To preview a script without submitting transactions, omit `--broadcast`.

```bash
export LASNA_RPC=https://lasna-rpc.rnk.dev/
export DESTINATION_RPC=https://sepolia.unichain.org
export DESTINATION_CHAIN_ID=1301
# For Base Sepolia, instead use https://sepolia.base.org and 84532.

export LASNA_ACCOUNT=your-existing-lasna-account
export DESTINATION_ACCOUNT=your-existing-destination-account
read -rp 'Existing Lasna signer address: ' LASNA_OPERATOR
read -rp 'Existing destination signer address: ' DESTINATION_OPERATOR
read -rp 'Reactive funding in testnet lREACT wei: ' REACTIVE_FUNDING_WEI
read -rp 'Callback funding in testnet ETH wei: ' CALLBACK_FUNDING_WEI
export LASNA_OPERATOR DESTINATION_OPERATOR REACTIVE_FUNDING_WEI CALLBACK_FUNDING_WEI

forge script script/Deploy.s.sol:DeployReactive \
  --rpc-url "$LASNA_RPC" --account "$LASNA_ACCOUNT" --broadcast
read -rp 'Deployed GuardReactive address: ' REACTIVE_ADDRESS
export REACTIVE_ADDRESS

forge script script/Deploy.s.sol:DeployDestination \
  --rpc-url "$DESTINATION_RPC" --account "$DESTINATION_ACCOUNT" --broadcast
read -rp 'Deployed GuardVault address: ' VAULT_ADDRESS
read -rp 'Deployed MockMarket address: ' MARKET_ADDRESS
read -rp 'Deployed base token address: ' BASE_ADDRESS
export VAULT_ADDRESS MARKET_ADDRESS BASE_ADDRESS

forge script script/Deploy.s.sol:ConfigureReactive \
  --rpc-url "$LASNA_RPC" --account "$LASNA_ACCOUNT" --broadcast
```

Save the addresses and transaction hashes from the output or `broadcast/Deploy.s.sol/<chain-id>/run-latest.json`. Wait for the [subscriptions](https://dev.reactive.network/rnk-rpc-methods) to become active on Lasna before creating orders; orders created before subscription are not backfilled by this app. The destination script mints demo tokens to the existing destination operator and seeds the market with quote liquidity. If either side runs out of fees, use the documented `depositTo(address)` method on its System Contract/proxy to top up with **testnet** funds only.

### Walk through a stop-loss on the selected testnet

Create a sell order for two GBASE with a stop at 90 GQUOTE per GBASE. Use the transaction logs or `lastOrderId()` in an uncontested demo deployment to find the order ID. Wait for its `OrderTrackingChanged` event on Lasna before publishing either price update.

```bash
cast send "$BASE_ADDRESS" 'approve(address,uint256)' "$VAULT_ADDRESS" 2000000000000000000 \
  --account "$DESTINATION_ACCOUNT" --rpc-url "$DESTINATION_RPC"
cast send "$VAULT_ADDRESS" 'createOrder(bool,uint128,uint256)' false 90000000000000000000 2000000000000000000 \
  --account "$DESTINATION_ACCOUNT" --rpc-url "$DESTINATION_RPC"
cast call "$VAULT_ADDRESS" 'lastOrderId()(uint256)' --rpc-url "$DESTINATION_RPC"

# 95: remains open. Wait for PriceObserved on Lasna.
cast send "$MARKET_ADDRESS" 'publishPrice(uint256)' 95000000000000000000 \
  --account "$DESTINATION_ACCOUNT" --rpc-url "$DESTINATION_RPC"
# 85: triggers; the vault pays 170 GQUOTE if the price remains 85.
cast send "$MARKET_ADDRESS" 'publishPrice(uint256)' 85000000000000000000 \
  --account "$DESTINATION_ACCOUNT" --rpc-url "$DESTINATION_RPC"
```

For a 120 take-profit, approve again and call `createOrder` with `true` and `120000000000000000000`, then publish `125000000000000000000` after registration. To cancel an open order, call `cancelOrder(uint256)` with its ID from the order's own account. Check the vault and Reactive logs before sending another tick so the demo clearly attributes each result.

## Measuring the full event → Reactive → callback loop

**Public testnet latency: not measured (no deployment).** The Foundry stop-loss test checks that the origin timestamp survives the full simulated event/callback path and yields a **4-second fixture** (clock advanced from 100 to 104); it is not a performance measurement.

On testnet, save the `PriceUpdated` transaction hash and that log's receipt `logIndex`. On Lasna, find the matching `SettlementRequested` event by order ID, trigger hash and log index. Inspect the same transaction for the System Contract's `CallbackRequest`. Use that Reactive transaction hash to find the destination callback transaction:

```bash
cast logs --address "$REACTIVE_ADDRESS" --rpc-url "$LASNA_RPC" \
  --from-block "$LASNA_START_BLOCK" --to-block latest \
  'SettlementRequested(uint256 indexed orderId,bytes32 indexed triggerTxHash,uint256 indexed triggerLogIndex)' \
  "$ORDER_ID" "$PRICE_TX" "$PRICE_LOG_INDEX"
cast call 0x8888888888888888888888888888888888888888 \
  'getCallbacks(uint256)((uint256,address,uint256,uint256,uint256,bytes)[])' \
  "$REACTIVE_TX" --rpc-url "$LASNA_RPC"
cast receipt "$EXECUTION_TX" --rpc-url "$DESTINATION_RPC"
```

Set `LASNA_START_BLOCK` to a bounded height before the trigger. The callback lookup returns records including the destination transaction hash, which may be displayed as a decimal `uint256`; use `cast to-hex` and left-pad to 32 bytes if needed. Only count a receipt with the vault's `OrderExecuted` log matching the original order and trigger (proxy delivery may succeed without a fill). Compare block inclusion timestamps:

```bash
block_timestamp() {
  local block time
  block=$(cast receipt "$1" blockHash --rpc-url "$2") || return
  time=$(cast block "$block" --field timestamp --rpc-url "$2") || return
  cast to-dec "$time"
}
t0=$(block_timestamp "$PRICE_TX" "$DESTINATION_RPC")
t1=$(block_timestamp "$REACTIVE_TX" "$LASNA_RPC")
t2=$(block_timestamp "$EXECUTION_TX" "$DESTINATION_RPC")
printf 'Origin → Reactive: %ss\nReactive → execution: %ss\nEnd-to-end: %ss\n' \
  "$((t1 - t0))" "$((t2 - t1))" "$((t2 - t0))"
```

The end-to-end metric uses two blocks on the **same** chain, from market event inclusion to execution inclusion; it excludes wallet submission time. Per-leg deltas use different chain clocks and can be skewed, especially at one-second resolution. Run at least ten fresh orders, log each of the three transaction hashes and deltas, and report sample count, median, p95 and failed/non-settling attempts separately. Receipt polling can establish a separate observer-based elapsed time, but its sampling interval must be reported.

## Submission

- [Reactive Omni Buildathon on DoraHacks](https://dorahacks.io/hackathon/reactive-omni-buildathon/detail): prize pool listed as **$5,500, payable in REACT tokens, not cash**.
- Deadline: **Dec 6, 2026, 04:00 CST (UTC+8)**.
- Submission requires the public GitHub repository link and a **demo video under 3 minutes**. See the [video outline](docs/VIDEO_SCRIPT.md). Recording and submitting are left to the entrant.
