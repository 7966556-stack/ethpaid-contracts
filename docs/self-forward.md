# Forwarding your payments yourself

Every ETHPAID payment address is a contract (an EIP-1167 clone created by a public factory). Three values are baked
into it when its address is computed: **your payout wallet**, **the fee recipient** and **the fee rate** (on Tron also
a fixed fee in token units). The contract has no owner, no admin and no upgrade path; its only functions send its
balance to those recipients. Calling them is **permissionless**: anyone may do it, including you.

ETHPAID's server normally does this for you right after confirmations and pays the network fee. You never need ETHPAID
for it: everything below works without our servers, and keeps working if ETHPAID is offline or gone.

## What you need: the parameters of the address

| Parameter | Where it comes from |
|---|---|
| `network`, `address` | the invoice |
| `factory` | `0xFA109f39ff2300D2016c145E0519eCfe7e64BD60` on Ethereum, BNB Chain, Base (and their testnets); `TNkKPtZs79Fz8qEckmjEvRyXVxhiUDKGzp` on Tron (Nile: `TGUD7c2jTpNEGBgi3f8tGBosVzX6jacvEH`) |
| `merchant` | your payout wallet at the time the invoice was created |
| `fee_recipient`, `fee_bps` | the fee written into the address (prepaid plan: `0x000…000` and `0`) |
| `fee_fixed` | Tron only: the fixed network fee in token units (`0` on EVM) |
| `salt` | 32 bytes, see below |

Get them all at once:

- **Telegram bot:** Settings → “Self-forward kit” → a JSON file with every address of your store;
- **API:** `GET /v1/forward-kit` (same JSON); every invoice in the API and in webhooks also carries
  `payment_options[].forwarder` with these values and a ready `self_forward_url`.

**Keep the file.** It contains no secrets — knowing the parameters only lets someone forward the funds *to you* — but
without the salt the address cannot be matched to the factory.

### How the salt is made

```
invoice address:  salt = keccak256( invoice_id_bytes(16) || network_key_utf8 || attempt_uint32_be )
```

`invoice_id` is the invoice UUID (`id` in the API) as 16 raw bytes, `network_key` is e.g. `bsc`, `base`, `ethereum`,
`tron`, `attempt` is almost always `0`. On Ethereum and Tron ETHPAID reuses an address for later invoices of the
**same** store; its salt is that of the invoice it was first made for — the export file lists it.

### Check that an address is really yours

Call the factory's view function `computeAddress(merchant, feeRecipient, feeBps, salt)` (Tron:
`computeAddress(merchant, feeRecipient, feeBps, feeFixed, salt)`). It must return the payment address. If it does not,
the parameters are wrong — do not use them.

## Three ways to forward

### 1. The web page (EVM and Tron)

`tools/forward/index.html` in this repository — one self-contained file, no external scripts or servers. Published at
https://ethpaid.com/forward/ and mirrored at https://7966556-stack.github.io/ethpaid-contracts/tools/forward/ (GitHub Pages,
independent of ETHPAID's servers); you can also save it and open it from your computer.

1. Load the export file (or open an invoice's `self_forward_url`).
2. Connect a wallet: MetaMask, Rabby, Trust… (EVM) or TronLink (Tron). Any account works: it only pays the network fee.
3. “Check” asks the factory to recompute the address and shows the balances. “Forward” sends one transaction:
   `factory.deployAndFlush(merchant, feeRecipient, feeBps, [feeFixed,] salt, tokens, includeNative)`.

### 2. Command line (EVM)

```bash
python3 scripts/self-forward.py --kit ethpaid-forward-kit.json
```

Checks every address against the factory on a public node, lists balances and prints `to`/`data` for a transaction you
send from your own wallet (or a `cast send … --interactive` command). It never asks for a key.

### 3. The block explorer, by hand

On Etherscan / BscScan / BaseScan open the factory → **Contract → Write Contract** → connect your wallet →
`deployAndFlush`:

| Field | Value |
|---|---|
| merchant | your payout wallet |
| feeRecipient | from the export (prepaid: `0x0000000000000000000000000000000000000000`) |
| feeBps | from the export (e.g. `100`) |
| salt | from the export (`0x…`, 64 hex digits) |
| tokens | e.g. `[0x55d398326f99059fF775485246999027B3197955]` (the tokens on the address) |
| includeNative | `true` if ETH/BNB is on the address, else `false` |

On Tron the factory source is published here, not on Tronscan (see README), so Tronscan's “Write Contract” form is not
offered; use the web page with TronLink.

`deployAndFlush` creates the contract if it does not exist yet and returns the existing one otherwise, so the same call
works in both cases.

## What cannot happen

- Funds cannot go anywhere except `merchant` and `fee_recipient` (by `fee_bps`, plus `fee_fixed` on Tron): the
  recipients are part of the contract's code and of its address.
- ETHPAID cannot change the recipients, pause the contract or take the funds; nor can anyone else.
- The fee cannot exceed 5 % (`MAX_FEE_BPS`): the factory refuses to create such an address.
