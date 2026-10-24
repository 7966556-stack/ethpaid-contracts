# Static analysis — 2026-10-24

Scope: `src/` on branch `stage-tron-spike` (commit 8240b0a): PaymentForwarder, ForwarderFactory (EVM, deployed on
testnets), TronPaymentForwarder, TronForwarderFactory (Nile). 274 nSLOC, solc 0.8.28.

Tools (release ≥ 2 weeks old, run locally, nothing installed into the project):

| Tool | Version | Command |
| --- | --- | --- |
| Slither | 0.11.6 (81 detectors) | `slither . --filter-paths "lib/\|test/\|script/" --exclude-informational` |
| Aderyn | 0.6.8 (88 detectors), sha256 of the release archive verified | `aderyn . --src src` |

Result: **no exploitable issue**. 17 Slither results and 9 Aderyn results, all triaged below as false positives or
intentional design. No code change.

The property every finding was checked against: funds can leave a forwarder only to the merchant or the fee recipient
baked into its immutable args; nobody (including us) can change them, and every function is permissionless.

## Slither

| Detector | Where | Verdict |
| --- | --- | --- |
| reentrancy-balance | TronPaymentForwarder._transfer | Intentional. `before` is read right before the call on purpose: the exact balance drop is how a transfer that silently did nothing (TRON USDT returns `false`) is detected. State (`accruedFee`) is written before the call (checks-effects-interactions). A re-entering token can only touch its own balance, and recipients are fixed, so re-entry cannot redirect funds. |
| incorrect-equality (×3) | `balance == 0` in flushToken/flushNative | Benign: early return on an empty balance. Forcing a non-zero balance only makes the flush do real work. |
| unused-return (×5) | factories: clone address, flushToken/flushNative results | Benign. The Tron factory compares the clone address with the prediction; the EVM factory gets it from OpenZeppelin Clones, which reverts on failure. Flush amounts are reported through events. |
| calls-loop (×8) | flushTokens, deployAndFlush, collectFees | By design: the caller chooses the list; a batch is all-or-nothing and can be retried per token. |

## Aderyn

| Finding | Where | Verdict |
| --- | --- | --- |
| H-1 encodePacked hash collision | TronForwarderFactory._predict | False positive: the only dynamic part (`args`) is last and its length is inside the hashed data (`uint16(args.length + 0x2d)`); `args` itself is fixed-width (address, address, uint16, uint64). Every deployment is also checked against the prediction (`PredictionMismatch`). |
| H-2 locks Ether | PaymentForwarder, TronPaymentForwarder | False positive: `flushNative()` sends the whole native balance to merchant + fee recipient. |
| H-3 state change after external call | TronPaymentForwarder.flushToken/collectFees | False positive: the "external call" is a `balanceOf` view call before the state write; the only transfer comes after it. |
| L-1 SSTORE in loop | flushTokens | Accepted: one write per token is the accounting itself. |
| L-2 large literal | `10_000`, `5_000_000` | Style only. |
| L-3 revert in loop | flushTokens | By design (all-or-nothing batch). |
| L-4 unchecked return | same as Slither unused-return | See above. |
| L-5 unsafe ERC20 | TronPaymentForwarder._transfer | Intentional: SafeERC20 reverts on TRON USDT; the balance check replaces it and is stricter. |
| L-6 public not used internally | config/feeFor/computeAddress/deploy… | Style only (`public` kept, some are called internally by the factory paths). |

## Limits

Static analysis finds known patterns; it does not replace the external audit planned before public launch. TVM
specifics (energy, TRC-20 quirks) are covered by the Nile tests, not by these tools.
