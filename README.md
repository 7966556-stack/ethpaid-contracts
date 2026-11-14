# ethpaid-contracts

Non-custodial payment addresses for **ETHPAID Pay** (EVM chains and Tron). Developed by SIA ETHPAID (Latvia).

- `ForwarderFactory` — computes and deploys payment addresses (EIP-1167 clones via CREATE2).
- `PaymentForwarder` — the clone: forwards everything it receives to the merchant (minus an optional fee).
- `tron/TronForwarderFactory`, `tron/TronPaymentForwarder` — the same design for TRON (fee accrues in the clone and
  can only be collected to the fixed fee wallet).

## Mainnet deployments (tag `v1.0.0`)

| Network | Factory | Implementation | Source |
|---|---|---|---|
| Ethereum | [0xFA109f39ff2300D2016c145E0519eCfe7e64BD60](https://etherscan.io/address/0xFA109f39ff2300D2016c145E0519eCfe7e64BD60#code) | [0x78d1Ed9b507F9912850644D0C3dD8d5Eb5Bdb26a](https://etherscan.io/address/0x78d1Ed9b507F9912850644D0C3dD8d5Eb5Bdb26a#code) | verified on Etherscan and Sourcify |
| BNB Chain | [0xFA109f…BD60](https://bscscan.com/address/0xFA109f39ff2300D2016c145E0519eCfe7e64BD60#code) | [0x78d1Ed…b26a](https://bscscan.com/address/0x78d1Ed9b507F9912850644D0C3dD8d5Eb5Bdb26a#code) | verified on BscScan and Sourcify |
| Base | [0xFA109f…BD60](https://basescan.org/address/0xFA109f39ff2300D2016c145E0519eCfe7e64BD60#code) | [0x78d1Ed…b26a](https://basescan.org/address/0x78d1Ed9b507F9912850644D0C3dD8d5Eb5Bdb26a#code) | verified on BaseScan and Sourcify |
| Tron | [TNkKPtZs79Fz8qEckmjEvRyXVxhiUDKGzp](https://tronscan.org/#/contract/TNkKPtZs79Fz8qEckmjEvRyXVxhiUDKGzp) | [TLbhrRk23QAL9VVZEquK4rtU4Snj82EY4v](https://tronscan.org/#/contract/TLbhrRk23QAL9VVZEquK4rtU4Snj82EY4v) | this repository (see below) |

The EVM factory is deployed with CREATE2 through `0x4e59b44847b379578588920ca78fbf26c0b4956c` (salt
`keccak256("ETHPAID ForwarderFactory v1")`), so it has the same address on every EVM chain. The Tron factory takes one
constructor argument, the CREATE2 address prefix `0x41`.

### Verify it yourself

All contracts are compiled with standard solc 0.8.28 (`evm_version = "paris"`, optimizer 10 000 runs, no metadata hash;
see `foundry.toml`). Tronscan's verifier did not match this metadata-free build (27.10.2026), so for Tron — and for any
network — anyone can rebuild and compare byte for byte:

```bash
git clone --recurse-submodules https://github.com/7966556-stack/ethpaid-contracts && cd ethpaid-contracts
git checkout v1.0.0 -- src foundry.toml && ./scripts/verify-deployment.sh
```

The script needs Foundry and python3, no API keys (public RPC nodes and TronGrid). It checks the creation code (Tron)
and the runtime code of every factory and implementation; immutable values (implementation address, Tron prefix) are
read from the chain and checked against the expected addresses.

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

Fee: with `feeBps > 0` the clone splits every flush between `feeRecipient` and the merchant (ETHPAID Pay uses
100 bps = 1 %; on Tron also a fixed `feeFixed`). With `feeBps = 0` and `feeRecipient = address(0)` the whole amount
goes to the merchant.

## Forward your payments yourself

Forwarding is permissionless: a merchant never needs ETHPAID to receive its funds. With the parameters of an address
(the bot's “Self-forward kit” or `GET /v1/forward-kit`):

- **web page** — [`tools/forward/index.html`](tools/forward/index.html): one self-contained file, no servers;
  checks the address against the factory and forwards with your own wallet (MetaMask etc., TronLink);
  published at https://ethpaid.com/forward/;
- **command line** — `python3 scripts/self-forward.py --kit ethpaid-forward-kit.json` (EVM; prints the transaction,
  never asks for a key);
- **block explorer** — the factory's “Write Contract” → `deployAndFlush`.

Details, the salt formula and the explorer fields: [docs/self-forward.md](docs/self-forward.md).

## Gas (real Ethereum mainnet state, anvil fork of our node, 14.10.2026)

| Scenario | Gas |
|---|---|
| `deployAndFlush` USDT, no fee | 111 259 |
| `deployAndFlush` USDT, with fee | 121 477 (138 577 on the very first payment to a new fee wallet) |
| `flushToken` USDT, already deployed (static address) | 51 632 |
| Factory deployment (one-time per chain) | ~1.5 M |

At 0.25 gwei and ETH = $2 507 a flush costs ≈ $0.07–0.08; at 5 gwei ≈ $1.4–1.5. On BSC/Base/Polygon — fractions of a cent.

## Known properties / caveats

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

## Testnet deployments (14.10.2026)

| Network | ForwarderFactory | Notes |
|---|---|---|
| Ethereum Sepolia (11155111) | `0xFA109f39ff2300D2016c145E0519eCfe7e64BD60` | deploy tx `0x1989157997f1a3254869bdb763238c6179189085d191529c777780b9a6406f15`, 7.77 M gas (Glamsterdam/EIP-8037 state gas) |
| Base Sepolia (84532) | `0xFA109f39ff2300D2016c145E0519eCfe7e64BD60` | |
| BSC Testnet (97) | `0xFA109f39ff2300D2016c145E0519eCfe7e64BD60` | requires priority fee ≥ 0.1 gwei (`--priority-gas-price 100000000`), otherwise txs hang in public mempools |

## Status

v1.0.0 is deployed on Ethereum, BNB Chain, Base and Tron mainnets (26.10.2026). No external audit yet;
internal static analysis: [docs/static-analysis-2026-10-24.md](docs/static-analysis-2026-10-24.md).
