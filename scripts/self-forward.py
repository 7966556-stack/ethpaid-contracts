#!/usr/bin/env python3
"""Forward an ETHPAID payment address yourself, without ETHPAID (EVM networks).

Checks the address against the public factory (computeAddress), shows its balances, and prints the transaction to
send from your own wallet: `to` = the factory, `data` = deployAndFlush(...). Nothing is signed here and no key is
asked for: paste `to`/`data` into any wallet that supports custom data, or run the printed `cast send` command.

  python3 scripts/self-forward.py --kit ethpaid-forward-kit.json            # every address in an export file
  python3 scripts/self-forward.py --network bsc --address 0x… --merchant 0x… \\
      --fee-recipient 0x… --fee-bps 100 --salt 0x…

Python 3.9+, standard library only. Tron: use tools/forward (TronLink) or Tronscan's "Write Contract" (docs/self-forward.md).
"""

from __future__ import annotations

import argparse
import json
import sys
import urllib.request

FACTORY = "0xFA109f39ff2300D2016c145E0519eCfe7e64BD60"  # the same address on every EVM network
NETS = {
    "ethereum": (1, "https://ethereum-rpc.publicnode.com",
                 [("USDT", "0xdAC17F958D2ee523a2206206994597C13D831ec7", 6), ("USDC", "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48", 6)]),
    "bsc": (56, "https://bsc-rpc.publicnode.com",
            [("USDT", "0x55d398326f99059fF775485246999027B3197955", 18), ("USDC", "0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d", 18)]),
    "base": (8453, "https://base-rpc.publicnode.com", [("USDC", "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913", 6)]),
    "sepolia": (11155111, "https://ethereum-sepolia-rpc.publicnode.com", [("USDT", "0x5DEC28792fbF05C4272252a5008A86b9ED46aBf7", 6)]),
    "bsc-testnet": (97, "https://bsc-testnet-rpc.publicnode.com", [("USDT", "0x7f16a363339614A1479b529f65fA56Ca793a68F0", 6)]),
    "base-sepolia": (84532, "https://base-sepolia-rpc.publicnode.com", [("USDT", "0x7f16a363339614A1479b529f65fA56Ca793a68F0", 6)]),
    "localhost": (31337, "http://127.0.0.1:8545", []),
}
SEL_COMPUTE, SEL_FLUSH, SEL_BALANCE = "7db7e86c", "a20a1944", "70a08231"  # keccak256(signature)[:4]


def rpc(url: str, method: str, params: list):
    req = urllib.request.Request(url, json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode(),
                                 {"Content-Type": "application/json", "User-Agent": "ethpaid-self-forward/1.0"})
    with urllib.request.urlopen(req, timeout=30) as r:
        out = json.load(r)
    if "error" in out:
        raise SystemExit(f"RPC error: {out['error']}")
    return out["result"]


def word(hex_or_int) -> str:
    if isinstance(hex_or_int, int):
        return f"{hex_or_int:064x}"
    return hex_or_int.lower().removeprefix("0x").rjust(64, "0")


def units(v: int, dec: int) -> str:
    s = str(v).rjust(dec + 1, "0")
    i, f = s[:-dec] if dec else s, (s[-dec:] if dec else "").rstrip("0")
    return f"{i}.{f}" if f else i


def one(e: dict, rpc_url: str | None) -> None:
    net = e["network"]
    if net not in NETS:
        print(f"- {e.get('address')}: network {net!r} is not EVM or unknown (Tron: see docs/self-forward.md)")
        return
    chain_id, default_rpc, tokens = NETS[net]
    url = rpc_url or default_rpc
    if e.get("factory") and e["factory"].lower() != FACTORY.lower():
        print(f"- {e['address']}: factory {e['factory']} is not the official one — skipped")
        return
    merchant, fee_r, bps, salt = e["merchant"], e["fee_recipient"], int(e.get("fee_bps", 0)), e["salt"]
    tokens = tokens + [(t["symbol"], t["address"], int(t.get("decimals", 18))) for t in e.get("tokens", [])
                       if t["address"].lower() not in {x[1].lower() for x in tokens}]
    out = rpc(url, "eth_call", [{"to": FACTORY, "data": "0x" + SEL_COMPUTE + word(merchant) + word(fee_r) + word(bps) + word(salt)}, "latest"])
    computed = "0x" + out[-40:]
    print(f"\n{net} {e['address']}")
    if computed.lower() != e["address"].lower():
        print(f"  ✗ does NOT match these parameters (factory computes {computed}) — do not use")
        return
    print(f"  ✓ matches the factory; funds can go only to {merchant}" + (f" and {bps / 100:.2f}% to {fee_r}" if bps else " (no fee)"))
    have, native = [], int(rpc(url, "eth_getBalance", [e["address"], "latest"]), 16)
    for sym, tok, dec in tokens:
        b = int(rpc(url, "eth_call", [{"to": tok, "data": "0x" + SEL_BALANCE + word(e["address"])}, "latest"]) or "0x0", 16)
        if b:
            have.append(tok)
            print(f"  {units(b, dec)} {sym}")
    if native:
        print(f"  {units(native, 18)} (native coin)")
    if not have and not native:
        print("  nothing to forward")
        return
    data = ("0x" + SEL_FLUSH + word(merchant) + word(fee_r) + word(bps) + word(salt) + word(0xC0) + word(1 if native else 0)
            + word(len(have)) + "".join(word(t) for t in have))
    print(f"  send from any wallet on chain {chain_id}:\n    to:    {FACTORY}\n    value: 0\n    data:  {data}")
    print(f"  or: cast send {FACTORY} {data} --rpc-url {url} --interactive")


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--kit", help="export file from the ETHPAID bot or GET /v1/forward-kit")
    ap.add_argument("--network")
    ap.add_argument("--address")
    ap.add_argument("--merchant")
    ap.add_argument("--fee-recipient")
    ap.add_argument("--fee-bps", type=int, default=0)
    ap.add_argument("--salt")
    ap.add_argument("--rpc", help="RPC URL (default: a public node of the network)")
    a = ap.parse_args()
    if a.kit:
        with open(a.kit, encoding="utf-8") as f:
            data = json.load(f)
        entries = data if isinstance(data, list) else data.get("addresses", [])
    elif a.network and a.address and a.merchant and a.fee_recipient and a.salt:
        entries = [{"network": a.network, "address": a.address, "merchant": a.merchant, "fee_recipient": a.fee_recipient,
                    "fee_bps": a.fee_bps, "salt": a.salt}]
    else:
        ap.print_help()
        sys.exit(2)
    for e in entries:
        one(e, a.rpc)


if __name__ == "__main__":
    main()
