#!/bin/bash
# Rebuild the contracts from tag v1.0.0 and compare them byte for byte with what is deployed on Ethereum, BNB Chain,
# Base and Tron. Needs git, Foundry (forge) and python3; no API keys.
set -euo pipefail
cd "$(dirname "$0")/.."
git submodule update --init --quiet
if ! git diff --quiet v1.0.0 -- src foundry.toml lib/openzeppelin-contracts; then
  echo "Sources differ from tag v1.0.0. Run: git checkout v1.0.0 -- src foundry.toml && git submodule update"; exit 1
fi
forge build --quiet
python3 scripts/verify-deployment.py
