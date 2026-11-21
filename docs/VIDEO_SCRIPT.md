# Reactive Guard — demo outline (2:45)

| Time | Show | Say |
| --- | --- | --- |
| 0:00–0:20 | Project name, tracks, one diagram | “Reactive Guard escrows a token and sells it for the quote token when a stop-loss or take-profit price is reached. No keeper or bot submits the sale.” |
| 0:20–0:50 | Create a two-GBASE stop-loss at 90; show the escrow and Lasna registration | “The order event registers the threshold on Lasna. The vault still holds both base tokens.” |
| 0:50–1:10 | Publish 95; show the order stays open | “The market event arrives and is observed, but it doesn't qualify. No callback is requested.” |
| 1:10–1:55 | Publish 85, then show the three correlated receipts and wallet balance | “The trigger becomes a Reactive callback request. The authenticated proxy calls the vault, which rechecks the live price and pays 170 GQUOTE at 85.” |
| 1:55–2:20 | Show same-origin trigger hash/log index and the latency table; briefly show the take-profit or cancellation test | “We measure from the price event's block to the execution block. Here's the sample count and the measured median and p95. A replay cannot settle a second time.” |
| 2:20–2:45 | Repo URL, model limits, closing | “The demo uses a mock market on a Sepolia chain and tests the full callback payload locally. The source, tests and testnet deployment steps are public.” |

If still undeployed, substitute `forge test -vvvv --match-test testStopLossExecutesAtThresholdAndCorrelatesOrigin` for the explorer footage. Label the traces **local simulation** and explain that no public latency was measured; do not present the four-second fixture as a benchmark.
