// Liquidation Guardian demo config.
// Deployed 15 Nov 2026 ~05:37 WIB, addresses verified on-chain via RPC.
const CONFIG = {
  baseSepoliaChainId: 84532,
  lasnaChainId: 5318007,
  // Base Sepolia (84532):
  mockWETH: "0xE07943b518Fa2534b27729aA7c74db7C8005e45C",
  mockUSDC: "0xcfd878e533505d7dc76C4916f651191364CF4725",
  priceFeed: "0xaE6253ED6050Cf93359C7780C2E0F434765b532b",
  vault: "0x509F6b0F15f4e2D065C9fCf542884599E505914d",
  guardian: "0x70789afFDEfc198765B0553EF48a9E9C43d97B74",
  // Lasna (5318007):
  reactive: "0x270F6C51D92B97254a5d9da7fE71342315E18993",
  // Explorers
  baseExplorer: "https://sepolia.basescan.org",
  lasnaExplorer: "https://lasna.reactscan.net",
};
