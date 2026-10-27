#!/usr/bin/env python3
"""Check that the contracts deployed on mainnets are exactly this repository's v1.0.0 build.

Run from the repository root after `forge build` (scripts/verify-deployment.sh does both). No API keys: public RPC
nodes and TronGrid. Immutable values are not part of the compiled code; they are read from the chain, printed and
checked against the expected addresses, and every other byte must match.
"""

import json
import sys
import urllib.request

EVM_FACTORY = "0xFA109f39ff2300D2016c145E0519eCfe7e64BD60"
EVM_IMPL = "0x78d1Ed9b507F9912850644D0C3dD8d5Eb5Bdb26a"
EVM_RPC = {
    "Ethereum": "https://ethereum-rpc.publicnode.com",
    "BNB Chain": "https://bsc-rpc.publicnode.com",
    "Base": "https://base-rpc.publicnode.com",
}
TRON_API = "https://api.trongrid.io/wallet/"
TRON_FACTORY = "TNkKPtZs79Fz8qEckmjEvRyXVxhiUDKGzp"
TRON_IMPL = "TLbhrRk23QAL9VVZEquK4rtU4Snj82EY4v"
B58 = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"


def post(url: str, body: dict) -> dict:
    req = urllib.request.Request(url, data=json.dumps(body).encode(), headers={"Content-Type": "application/json", "User-Agent": "ethpaid-verify/1.0"})
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.load(r)


def artifact(path: str, name: str) -> dict:
    with open(f"out/{path}/{name}.json") as f:
        return json.load(f)


def tron_hex(addr: str) -> str:
    """Base58check TRON address -> 20-byte hex (without the 0x41 prefix)."""
    n = 0
    for ch in addr:
        n = n * 58 + B58.index(ch)
    raw = n.to_bytes(25, "big")
    assert raw[0] == 0x41, addr
    return raw[1:21].hex()


def match_runtime(onchain: str, art: dict) -> dict[str, str]:
    """Compare runtime code with the build, skipping immutable slots; return the immutable values found on chain."""
    built = art["deployedBytecode"]["object"].removeprefix("0x").lower()
    onchain = onchain.removeprefix("0x").lower()
    if len(onchain) != len(built):
        raise SystemExit(f"length differs: on chain {len(onchain) // 2} bytes, build {len(built) // 2}")
    found, masked = {}, list(built)
    for ref, slots in (art["deployedBytecode"].get("immutableReferences") or {}).items():
        for s in slots:
            a, b = 2 * s["start"], 2 * (s["start"] + s["length"])
            found.setdefault(ref, onchain[a:b])
            if onchain[a:b] != found[ref]:
                raise SystemExit("one immutable has different values in its slots")
            masked[a:b] = onchain[a:b]
    if "".join(masked) != onchain:
        raise SystemExit("runtime code differs from the build")
    return found


def ok(msg: str) -> None:
    print(f"  ✅ {msg}")


def main() -> None:
    fac = artifact("ForwarderFactory.sol", "ForwarderFactory")
    imp = artifact("PaymentForwarder.sol", "PaymentForwarder")
    for net, rpc in EVM_RPC.items():
        print(net)
        code = lambda a: post(rpc, {"jsonrpc": "2.0", "id": 1, "method": "eth_getCode", "params": [a, "latest"]})["result"]
        vals = match_runtime(code(EVM_FACTORY), fac)
        assert list(vals.values()) == ["0" * 24 + EVM_IMPL[2:].lower()], vals
        ok(f"factory {EVM_FACTORY} = build, implementation() = {EVM_IMPL}")
        vals = match_runtime(code(EVM_IMPL), imp)
        assert list(vals.values()) == ["0" * 24 + EVM_IMPL[2:].lower()], vals
        ok(f"implementation {EVM_IMPL} = build")

    print("Tron")
    tfac = artifact("TronForwarderFactory.sol", "TronForwarderFactory")
    timp = artifact("TronPaymentForwarder.sol", "TronPaymentForwarder")
    created = post(TRON_API + "getcontract", {"value": TRON_FACTORY, "visible": True})["bytecode"].lower()
    init = tfac["bytecode"]["object"].removeprefix("0x").lower()
    if created != init + "41" + "0" * 62:
        raise SystemExit("Tron factory creation code differs from build + constructor(0x41)")
    ok(f"factory {TRON_FACTORY}: creation code = build + constructor argument 0x41")
    info = lambda a: post(TRON_API + "getcontractinfo", {"value": a, "visible": True})["runtimecode"]
    vals = sorted(match_runtime(info(TRON_FACTORY), tfac).values())
    want = sorted(["41" + "0" * 62, "0" * 24 + tron_hex(TRON_IMPL)])
    assert vals == want, vals
    ok(f"factory runtime = build, implementation = {TRON_IMPL}, prefix = 0x41")
    vals = match_runtime(info(TRON_IMPL), timp)
    assert list(vals.values()) == ["0" * 24 + tron_hex(TRON_IMPL)], vals
    ok(f"implementation {TRON_IMPL} = build")
    print("\nAll deployed contracts are exactly the v1.0.0 build.")


if __name__ == "__main__":
    try:
        main()
    except (SystemExit, AssertionError) as e:
        print(f"  ❌ {e}")
        sys.exit(1)
