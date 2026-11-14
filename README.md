# Liquidation Guardian — Reactive Omni Buildathon

**Track:** Every Second Counts · **Prize:** $2,000 (1st) · **Deadline submit:** 6 Des 2026, 03:00 WIB

Ketika health factor posisi lending jatuh di bawah batas, reactive contract
otomatis **top-up collateral sebelum posisi ke-liquidasi**. Detik yang
menentukan — itulah alasan masuk track Every Second Counts.

> Duplicate check (15 Nov 2026, 23 entri): tidak ada entri lain yang
> membangun liquidation guard. Stop-loss/TP, Payday, dan dead-man's switch
> semuanya sudah ada — Liquidation Guardian tidak.

## Arsitektur

```
Base Sepolia (84532)                      Lasna (5318007)
┌──────────────────────┐                  ┌──────────────────────────┐
│ MockPriceFeed        │ PriceUpdated     │ LiquidationReactive    │
│  (ETH/USD, owner-set)│ ──event────────▶ │  (AbstractReactive)    │
├──────────────────────┤                  │  · mirror posisi       │
│ LendingVault         │                  │  · hitung HF dari harga│
│  · posisi + HF       │                  │  · HF < 1.2 → callback │
│  · LT 80%, min HF 1.1│                  └──────────┬───────────────┘
├──────────────────────┤                             │ SYSTEM.requestCallbackV_1_0
│ Guardian (callback)  │ ◀── rescue() ───────────────┘
│  · pegang reserve    │     (via callback proxy)
│  · hanya via proxy   │     topUp / coverDebt
│  · re-check HF on-chain sebelum belanja reserve
└──────────────────────┘
```

Kontrak (`src/`, Foundry, solc 0.8.29, `@reactive-network` via
`reactive-lib-omni`):

| Kontrak | Chain | Peran |
|---|---|---|
| `MockToken.sol` | Base Sepolia | mWETH (18 des) & mUSDC (6 des), mintable |
| `MockPriceFeed.sol` | Base Sepolia | Chainlink AggregatorV3-compatible, `PriceUpdated(int256,uint256)` |
| `LendingVault.sol` | Base Sepolia | Posisi, health factor (skala 1e18), LT 80%, liquidate +5% bonus |
| `Guardian.sol` | Base Sepolia | `AbstractCallback`, pegang reserve, `rescue()` / `coverDebt()` — hanya via callback proxy + hanya dari reactive contract |
| `LiquidationReactive.sol` | Lasna | `AbstractReactive`, subscribe `PriceUpdated`, mirror posisi, trigger HF 1.2, target HF 1.5, cooldown 60 dtk/posisi |

Safety di Guardian: `rescue()` re-check HF on-chain sebelum belanja
reserve, no-op (bukan revert) kalau posisi sudah sehat / reserve kosong,
top-up di-cap ke reserve yang ada, dan `coverDebt()` kalau collateral
tidak cukup untuk top-up.

## Demo loop (angka yang diverifikasi di test)

1. Buka posisi: **1 mWETH @ $3000, utang 1500 mUSDC → HF 1.6**
2. Harga jatuh ke **$2000 → HF ≈ 1.0667** (di bawah trigger 1.2)
3. Reactive contract Lasna request callback → Guardian top-up **0.40625 mWETH**
4. Posisi akhir: **1.40625 mWETH, HF 1.5** — selamat dari likuidasi

## Setup

```bash
forge install foundry-rs/forge-std
forge install OpenZeppelin/openzeppelin-contracts
forge install Reactive-Network/reactive-lib-omni
forge build
```

## Test

```
forge test
```

**13/13 lolos** (`test/LiquidationGuardian.t.sol`), termasuk:
- `testFullLoop` — harga jatuh → callback → top-up 0.40625 mWETH → HF 1.5
- `testCooldownPreventsSpam` — tidak ada callback ganda dalam 60 dtk
- `testRescueCapsAtReserve` — top-up di-cap ke reserve (0.1 mWETH)
- `testGuardianSkipsWhenHealthy` / `testNoRescueWhenHealthy` — no-op saat aman
- `testGuardianAuth` — `rescue()` ditolak dari non-proxy / non-reactive
- `testVaultHealthFactor` / `testVaultLiquidation` / `testVaultRepayAndWithdraw`

## Deploy (testnet only — TIDAK ADA mainnet, TIDAK ADA dana asli)

Deployer: wallet testnet baru khusus proyek ini,
`0x2B5C2f695046766a124AcB1544C56dC2bb6b139C`.
Private key HANYA di `.env` (mode 600) — jangan pernah print / commit.

Urutan deploy:

```bash
# 0. Fund deployer dari faucet publik (lihat "Pendanaan" di bawah)
export $(grep -v '^#' .env | xargs)

# 1. Base Sepolia: mocks + vault
forge script script/DeployBase.s.sol --rpc-url https://sepolia.base.org --broadcast
#    → catat MockWETH, MockUSDC, MockPriceFeed, LendingVault

# 2. Lasna: reactive contract (butuh ~1 lREACT di deployer)
PRICE_FEED=<feed> forge script script/DeployLasna.s.sol \
  --rpc-url https://lasna-rpc.rnk.dev/ --broadcast
#    → catat LiquidationReactive

# 3. Base Sepolia: Guardian (butuh ~0.05 SepETH di deployer)
REACTIVE=<reactive> VAULT=<vault> forge script script/DeployGuardian.s.sol \
  --rpc-url https://sepolia.base.org --broadcast
#    → catat Guardian

# 4a. Base Sepolia: buka posisi demo + isi reserve Guardian
WETH=<weth> VAULT=<vault> GUARDIAN=<guardian> forge script script/SetupDemoBase.s.sol \
  --rpc-url https://sepolia.base.org --broadcast
#    → catat position id (0)

# 4b. Lasna: set recipient + register posisi
REACTIVE=<reactive> GUARDIAN=<guardian> POSITION_ID=0 forge script script/SetupDemoLasna.s.sol \
  --rpc-url https://lasna-rpc.rnk.dev/ --broadcast
```

Lalu isi alamat deploy di `frontend/config.js` dan buka `frontend/index.html`
(butuh wallet EVM di browser, chain Base Sepolia) — tombol "Set harga"
memicu loop demo penuh, dan panel riwayat mencatat event live.

### Pendanaan

- **SepETH (Base Sepolia):** faucet publik tanpa login —
  https://faucet.zalalena.com/base (captcha di browser). Alchemy/QuickNode
  menolak wallet baru (syarat saldo mainnet). Butuh total ~0.15–0.2 SepETH
  (deploy + fund Guardian 0.05 + faucet lREACT 0.1).
- **lREACT (Lasna):** kirim SepETH ke faucet Reactive di Base Sepolia,
  `0x2afaFD298b23b62760711756088F75B7409f5967`, panggil
  `request(address)` — 1 ETH → 100 lREACT, maks 5 ETH/tx:
  ```bash
  cast send 0x2afaFD298b23b62760711756088F75B7409f5967 \
    --rpc-url https://sepolia.base.org --private-key $DEPLOYER_PRIVATE_KEY \
    "request(address)" $DEPLOYER_ADDRESS --value 0.1ether
  # → 10 lREACT ke deployer di Lasna
  ```

## Alamat deploy

> **STATUS: TER-DEPLOY 15 Nov 2026 ~05:37 WIB (deployer 0x2B5C2f695046766a124AcB1544C56dC2bb6b139C).** Semua alamat diverifikasi on-chain via RPC.

| Kontrak | Chain | Alamat |
|---|---|---|
| MockWETH | Base Sepolia | 0xE07943b518Fa2534b27729aA7c74db7C8005e45C |
| MockUSDC | Base Sepolia | 0xcfd878e533505d7dc76C4916f651191364CF4725 |
| MockPriceFeed | Base Sepolia | 0xaE6253ED6050Cf93359C7780C2E0F434765b532b |
| LendingVault | Base Sepolia | 0x509F6b0F15f4e2D065C9fCf542884599E505914d |
| Guardian | Base Sepolia | 0x70789afFDEfc198765B0553EF48a9E9C43d97B74 |
| LiquidationReactive | Lasna | 0x270F6C51D92B97254a5d9da7fE71342315E18993 |

Tx hash deploy (semua status sukses, diverifikasi via receipt):
- MockWETH: `0xba82af4989fded288a4149bfc0155ee55697f69d3268b9d3e6eea0f8e8eba532`
- MockUSDC: `0x093be97e00e964bb9ec01004351ce4834117e6838710d63e2c87ca0e1b90a088`
- MockPriceFeed: `0x512bfb93e2f00494e311922822732511f1b2ada62c034694df017621b5a170cd`
- LendingVault: `0x12f1c31ac6d8d23f060cfdc5dd664b5e05327908a1ca3b15627197e77387b0d7`
- setMinter (vault jadi minter mUSDC): `0x65e173442af9d6b33c5a822fb66b06e17f626a187ca96771089aa40b1d2087c3`
- LiquidationReactive (Lasna, gas 1.063.955, blok 8360618): `0x079b1c53689aaf4f9132ce740c987040c741e844abe5197eb070435c2d00a9b0`
- Guardian (funding 0.0005 SepETH): `0x178a752068b034173b1f98e0af0d7b7dc2254ebdbe5892e20bc3221032821da3`
- Setup demo Base (posisi 0: 1 mWETH / 1500 mUSDC, HF 1.6; reserve Guardian 1 mWETH): mint `0x87dcc46306b02e861f2fe4d48c49798b573035d30bcd1465892f3cb790ae484e`, approve `0x5fd8fdf40bd5a957740481f4fb157c992d3edf785358993ddf33b70e81f7e100`, openPosition `0xb33ff1eac845bdb1618ff67825de077fa6fbcac7ca20d66e8ee67de09d2147f5`, approve `0x3537668c0056eb8ecaa88c953428255b110649cf5fc737f3d09577c55adeb6f0`, depositReserve `0xdc0bed583782f3c00d58296653623bb43d89f8d4e93945093990ee52b8c50985`
- Setup demo Lasna (setRecipient + registerPosition 0): `0xa8d3f5a3de9650bcecb5c09037b4b07ca763eab9e8a9cf51acbc7ef9f88a4234`, `0x63aac717d11663cc151754607b7250fe7f867baf3afc5642b4924a9d1fb5f1bc`
- Faucet lREACT #1 (0.0025 SepETH → 0.25 lREACT): `0xeedd50cddc546b1dc3f44120555651218e7fa15cec98116a5fef1437b7357735` (blok 58866209, status sukses)
- Faucet lREACT #2 (0.001 SepETH → 0.1 lREACT): `0xf1962d192e4084c78b2b599758a8040f7084bef431f86bb9b84dc247dca55fae` (status sukses)

Pendanaan akhir deployer (setelah semua deploy + setup): ~0.000977 SepETH, ~0.177 lREACT. Guardian pegang 0.0005 SepETH, Reactive pegang 0.05 lREACT.

## Demo loop LIVE (15 Nov 2026 ~05:40 WIB) — BERHASIL ✅

Loop penuh berjalan live di testnet, angka sama persis dengan test lokal:

| Tahap | Bukti |
|---|---|
| 1. Harga jatuh $3000 → $2000 | `setPrice` tx `0xf0ec289961f062e92760c6a0202676c342a2e5129b092cb1414cdfaeaaf169d6`, blok Base Sepolia 58867240, status sukses. HF posisi 0 langsung jatuh 1.6 → **1.0667** (di bawah trigger 1.2) |
| 2. Reactive contract Lasna bereaksi | **Tidak ada tx biasa** — `react()` dieksekusi di level sistem Lasna (scan 74 blok tidak menemukan tx ke reactive contract). Bukti on-chain: mirror `guarded(0)` berubah collateral 1.0 → **1.40625 mWETH**, `lastRescue` = 1794695316 (timestamp blok setPrice); saldo Reactive 0.05 → **0.0330966 lREACT** (terpakai ~0.0169: gas react ~0.0094 + fee sistem/callback) |
| 3. Callback ke Guardian | Tx `0x3a3878e38dd5aa2cbd61208135ed1f025ae065f922078c3fa7887ffa0c917dc0`, dari relayer `0xf7e866d726658f6c3f14b8ee537fe268a4d91ddb` ke callback proxy `0x476F44b11F5C942c58f4c8E3d0300E5710743585`, blok 58867249, gas 135.636, status sukses. Event `Rescued`: topUp **0.40625 mWETH**, HF baru **1.5** |
| 4. Posisi selamat | HF akhir **1.5**, collateral 1.40625 mWETH, reserve Guardian tersisa 0.59375 mWETH |

**Latensi terukur (timestamp blok on-chain):** setPrice mined (ts 1794695316) → callback mined (ts 1794695318) = **~2 detik** end-to-end (wall-clock dari kirim setPrice sampai callback terkonfirmasi ≈ 3,6 detik). Angka ini yang jadi headline demo: detik yang menentukan.

Catatan: RPC Lasna `eth_getLogs` tidak mengembalikan log (diverifikasi: blok setRecipient yang pasti punya log pun mengembalikan 0) — jangan pakai getLogs untuk verifikasi Lasna; pakai `cast call` state + receipt.

## Yang masih kurang

- [x] Pendanaan faucet deployer (SepETH + lREACT) — 0.005 SepETH dari Zalalena + konversi 0.0035 SepETH → 0.35 lREACT
- [x] Deploy ke Lasna + Base Sepolia + alamat/tx hash diisi di tabel atas
- [x] Demo loop live end-to-end (harga jatuh → reactive tx → callback tx → top-up) + ukur latensi loop — **BERHASIL, latensi ~2 detik**
- [x] Frontend config diisi alamat deploy (uji di browser: parent — butuh wallet EVM di browser)
- [x] Video demo < 3 menit (dibuat parent) — `video/liquidation-guardian-demo.mp4`, 92,21 detik, 1920×1080, narasi Inggris (Helio), 1 klip AI untuk scene judul + slide PIL; tx hash + alamat kontrak diverifikasi dari frame
- [ ] Repo GitHub publik (dibuat parent via browser) + submit di DoraHacks sebelum 6 Des 2026 03:00 WIB
- [ ] Duplicate re-check entri baru sebelum submit
