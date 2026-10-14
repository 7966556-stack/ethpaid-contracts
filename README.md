# ethpaid-contracts

Non-custodial payment addresses for **ETHPAID Pay** (EVM chains).

- `ForwarderFactory` — computes and deploys payment addresses (EIP-1167 clones via CREATE2).
- `PaymentForwarder` — the clone: forwards everything it receives to the merchant (minus an optional fee).

## Guarantees

| | |
|---|---|
| Recipient is fixed | merchant wallet, fee wallet and fee are immutable clone args — part of the CREATE2 address itself. Nothing can change them after the address is issued. |
| No admin | no owner, no pause, no upgrade, no rescue function. |
| Permissionless | anyone (including the merchant) can deploy and flush. If ETHPAID disappears, the merchant can still collect funds. |
| Fee cap | `MAX_FEE_BPS = 500` (5%) hard-coded; fee rounds down (merchant-favourable). |
| Safe params only | `computeAddress` reverts on parameters that could never be deployed, so no "dead" address can be handed out. |
| Same address on all EVM chains | factory is deployed with CREATE2 through `0x4e59b44847b379578588920ca78fbf26c0b4956c`; a payment sent on the wrong EVM network can still be forwarded once the factory exists there. |
| Tokens | `SafeERC20` — works with USDT (no return value); tokens returning `false` revert and stay in place. |

Two fee plans (chosen per merchant):
- **prepaid** — `feeBps = 0`, `feeRecipient = address(0)`; one transfer per flush, fee is charged from the merchant's prepaid balance off-chain.
- **on-chain fee** — `feeBps > 0`; the clone splits every flush between `feeRecipient` and the merchant.

## Gas (real Ethereum mainnet state, anvil fork of our node, 14.10.2026)

| Scenario | Gas |
|---|---|
| `deployAndFlush` USDT, prepaid plan | 111 259 |
| `deployAndFlush` USDT, on-chain fee plan | 121 477 (138 577 on the very first payment to a new fee wallet) |
| `flushToken` USDT, already deployed (static address) | 51 632 |
| Factory deployment (one-time per chain) | ~1.5 M |

At 0.25 gwei and ETH = $2 507 a flush costs ≈ $0.07–0.08; at 5 gwei ≈ $1.4–1.5. On BSC/Base/Polygon — fractions of a cent.

## Known properties / caveats (for the auditor)

- Native coin sent to an **already deployed** clone goes through the proxy's `delegatecall` (more than 2 300 gas). Some exchanges send native coins with a tight gas limit; use fresh (undeployed) addresses for native-coin invoices, static addresses for tokens.
- A merchant wallet that rejects the native coin makes `flushNative` revert; funds stay in the clone until the wallet can receive.
- Batch functions (`flushTokens`, `deployAndFlush`) are all-or-nothing; one failing token reverts the batch.
- Lint warnings left on purpose: `calls-loop`, `require-revert-in-loop` (transitive via batch flush).
- Compiled for `evm_version = paris` (no PUSH0/MCOPY) for maximum EVM compatibility.

## Develop

Foundry 1.8.5, solc 0.8.28, OpenZeppelin 5.7.0.

```bash
forge build
forge test                       # unit + fuzz
ETH_RPC_URL=<mainnet rpc> forge test --match-contract MainnetFork -vv   # real USDT/USDC
forge script script/Deploy.s.sol --rpc-url <rpc> --account <keystore> --broadcast
```

Expected addresses (same on every chain, valid until the bytecode changes):
- ForwarderFactory `0xFA109f39ff2300D2016c145E0519eCfe7e64BD60`
- PaymentForwarder implementation `0x78d1Ed9b507F9912850644D0C3dD8d5Eb5Bdb26a`

Status: **not audited. Testnets only.**
