# Liquidation Guardian

A Reactive Network contract that tops up lending collateral before a position gets liquidated. Built for the Reactive Omni Buildathon, track **Every Second Counts**.

When a position's health factor drops below 1.2, the reactive contract fires a callback that adds collateral until the health factor is back to 1.5. End-to-end latency on testnet: ~2 seconds.

## How it works

```
Base Sepolia (84532)                      Lasna (5318007)
┌──────────────────────┐                  ┌──────────────────────────┐
│ MockPriceFeed        │ PriceUpdated     │ LiquidationReactive    │
│  (ETH/USD, owner-set)│ ──event────────▶ │  (AbstractReactive)    │
├──────────────────────┤                  │  · mirrors positions   │
│ LendingVault         │                  │  · computes HF         │
│  · positions + HF    │                  │  · HF < 1.2 → callback │
│  · LT 80%, min HF 1.1│                  └──────────┬───────────────┘
├──────────────────────┤                             │ SYSTEM.requestCallbackV_1_0
│ Guardian (callback)  │ ◀── rescue() ───────────────┘
│  · holds reserve     │     (via callback proxy)
│  · proxy only        │     topUp / coverDebt
│  · re-checks HF on-chain before spending reserve
└──────────────────────┘
```

Contracts (`src/`, Foundry, solc 0.8.29, `@reactive-network` via `reactive-lib-omni`):

| Contract | Chain | Role |
|---|---|---|
| `MockToken.sol` | Base Sepolia | mWETH (18 dec) & mUSDC (6 dec), mintable |
| `MockPriceFeed.sol` | Base Sepolia | Chainlink AggregatorV3-compatible, emits `PriceUpdated(int256,uint256)` |
| `LendingVault.sol` | Base Sepolia | Positions, health factor (1e18 scale), LT 80%, liquidation +5% bonus |
| `Guardian.sol` | Base Sepolia | `AbstractCallback`, holds the reserve, `rescue()` / `coverDebt()`, callback proxy only, reactive contract only |
| `LiquidationReactive.sol` | Lasna | `AbstractReactive`, subscribes to `PriceUpdated`, mirrors positions, triggers at HF 1.2, targets HF 1.5, 60 s cooldown per position |

Safety: `rescue()` re-checks the health factor on-chain before spending any reserve, no-ops (no revert) when the position is already healthy or the reserve is empty, caps the top-up at the available reserve, and falls back to `coverDebt()` when collateral is too low to top up.

## Demo

Verified on testnet, 15 Nov 2026:

1. Open a position: **1 mWETH @ $3000, 1500 mUSDC debt → HF 1.6**
2. Price drops to **$2000 → HF 1.0667** (below the 1.2 trigger)
3. The Lasna reactive contract requests a callback → Guardian tops up **0.40625 mWETH**
4. Final position: **1.40625 mWETH, HF 1.5**, saved from liquidation

Proof:

- Price drop: `setPrice` tx `0xf0ec289961f062e92760c6a0202676c342a2e5129b092cb1414cdfaeaaf169d6` (Base Sepolia block 58867240)
- Callback: tx `0x3a3878e38dd5aa2cbd61208135ed1f025ae065f922078c3fa7887ffa0c917dc0` (block 58867249), `Rescued` event: +0.40625 mWETH, HF 1.5
- Latency: block timestamps 1794695316 → 1794695318, **~2 s** end-to-end

Note: `react()` runs at the system level on Lasna, so there is no regular transaction hash for it. The proof is the `setPrice` tx, the changed on-chain state (`guarded(0)` collateral 1.0 → 1.40625 mWETH), and the callback tx. Lasna's `eth_getLogs` is broken, verify via `cast call`, not logs.

Video demo (92 s): [video-demo.mp4](video-demo.mp4)

## Setup

```bash
forge install foundry-rs/forge-std
forge install OpenZeppelin/openzeppelin-contracts
forge install Reactive-Network/reactive-lib-omni
forge build
forge test   # 13/13 pass (test/LiquidationGuardian.t.sol)
```

Key tests: `testFullLoop` (price drop → callback → top-up → HF 1.5), `testCooldownPreventsSpam`, `testRescueCapsAtReserve`, `testGuardianSkipsWhenHealthy`, `testGuardianAuth`.

## Deploy (testnet only, no mainnet, no real funds)

```bash
export $(grep -v '^#' .env | xargs)

# 1. Base Sepolia: mocks + vault
forge script script/DeployBase.s.sol --rpc-url https://sepolia.base.org --broadcast

# 2. Lasna: reactive contract (needs ~1 lREACT on the deployer)
PRICE_FEED=<feed> forge script script/DeployLasna.s.sol \
  --rpc-url https://lasna-rpc.rnk.dev/ --broadcast

# 3. Base Sepolia: Guardian (needs ~0.05 SepETH)
REACTIVE=<reactive> VAULT=<vault> forge script script/DeployGuardian.s.sol \
  --rpc-url https://sepolia.base.org --broadcast

# 4a. Base Sepolia: open demo position + fund Guardian reserve
WETH=<weth> VAULT=<vault> GUARDIAN=<guardian> forge script script/SetupDemoBase.s.sol \
  --rpc-url https://sepolia.base.org --broadcast

# 4b. Lasna: set recipient + register position
REACTIVE=<reactive> GUARDIAN=<guardian> POSITION_ID=0 forge script script/SetupDemoLasna.s.sol \
  --rpc-url https://lasna-rpc.rnk.dev/ --broadcast
```

Then set the deployed addresses in `frontend/config.js` and open `frontend/index.html` (needs an EVM wallet in the browser, Base Sepolia chain). The "Set price" button runs the full demo loop.

Funding: SepETH from a public faucet; lREACT by sending SepETH to the Reactive faucet `0x2afaFD298b23b62760711756088F75B7409f5967` on Base Sepolia and calling `request(address)` (1 ETH → 100 lREACT).

## Deployed addresses

| Contract | Chain | Address |
|---|---|---|
| MockWETH | Base Sepolia | 0xE07943b518Fa2534b27729aA7c74db7C8005e45C |
| MockUSDC | Base Sepolia | 0xcfd878e533505d7dc76C4916f651191364CF4725 |
| MockPriceFeed | Base Sepolia | 0xaE6253ED6050Cf93359C7780C2E0F434765b532b |
| LendingVault | Base Sepolia | 0x509F6b0F15f4e2D065C9fCf542884599E505914d |
| Guardian | Base Sepolia | 0x70789afFDEfc198765B0553EF48a9E9C43d97B74 |
| LiquidationReactive | Lasna | 0x270F6C51D92B97254a5d9da7fE71342315E18993 |

Deployed 15 Nov 2026. DoraHacks build: https://dorahacks.io/build/51164

License: MIT
