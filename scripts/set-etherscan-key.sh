#!/bin/bash
# Saves the Etherscan API V2 key (one key for Ethereum, BNB Chain, Base) to ~/.config/ethpaid/etherscan.key (600).
# Typed hidden, checked against the API (key passed to curl via stdin, never on a command line), never printed.
set -euo pipefail
umask 077
D="$HOME/.config/ethpaid"; mkdir -p "$D"
read -r -s -p "Вставьте ключ Etherscan API (ввод скрыт) и нажмите Enter: " K; echo
K=$(printf %s "$K" | grep -oE '[A-Z0-9]{30,40}' | head -1 || true)
[ -n "$K" ] || { echo "Это не похоже на ключ Etherscan (34 заглавные буквы и цифры)."; exit 1; }
for c in 1 56 8453; do
  R=$(printf 'url = "https://api.etherscan.io/v2/api?chainid=%s&module=proxy&action=eth_blockNumber&apikey=%s"\n' "$c" "$K" \
      | curl -fsS -m 20 -K - | python3 -c 'import sys,json; d=json.load(sys.stdin); print("ok" if str(d.get("result","")).startswith("0x") else d.get("result") or d.get("message"))')
  [ "$R" = ok ] || { echo "Сеть $c: Etherscan не принял ключ ($R)."; exit 1; }
done
printf '%s' "$K" > "$D/etherscan.key"; chmod 600 "$D/etherscan.key"; unset K
echo "Готово: ключ проверен для Ethereum, BNB Chain и Base и сохранён (~/.config/ethpaid/etherscan.key)."
