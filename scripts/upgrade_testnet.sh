#!/usr/bin/env bash
# upgrade_testnet.sh - #41 package upgrade (Albary signs).
#
# Ships the grid-snap fix as a Move package UPGRADE (NOT a republish), preserving
# the canonical package/vault objects + the dUSDC airdrop. Run by Albary from the
# canonical deployer address.
#
#   bash scripts/upgrade_testnet.sh
#
# Guards (refuses to proceed unless all hold):
#   1. sui CLI on PATH.
#   2. active address == canonical deployer 0xe7b27055...96add.
#   3. SUI gas balance >= 2.
#
# It NEVER passes --with-unpublished-dependencies (FORBIDDEN: would fork the deps).
# After a successful upgrade, follow the printed post-steps (bump Published.toml,
# record upgraded_package_id, re-run replay, patch REPLAY.md).

set -euo pipefail

UPGRADE_CAP='0xbff356585e35890fba6c09733463158a96530c0a9b0c2bca2ab042f41e95012a'
CANONICAL_DEPLOYER='0xe7b270554f5e3cb61f178f0411a71601b9d4c5a3114f26fa40104d4b22696add'
GAS_BUDGET='200000000'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONTRACTS_ROOT="$(dirname "$SCRIPT_DIR")"

command -v sui >/dev/null 2>&1 || { echo "[FAIL] sui CLI not on PATH." >&2; exit 1; }

ACTIVE="$(sui client active-address 2>/dev/null || true)"
echo "active address  : $ACTIVE"
echo "canonical       : $CANONICAL_DEPLOYER"
if [[ "$ACTIVE" != "$CANONICAL_DEPLOYER" ]]; then
    echo "[FAIL] active address is not the canonical deployer. Switch with:" >&2
    echo "       sui client switch --address $CANONICAL_DEPLOYER" >&2
    exit 1
fi

# SUI gas balance >= 2 (mist; 1 SUI = 1e9 mist).
BAL_MIST="$(sui client gas --json 2>/dev/null | python -c '
import sys, json
try:
    g = json.load(sys.stdin)
except Exception:
    print(0); raise SystemExit
tot = 0
for c in (g if isinstance(g, list) else []):
    for k in ("mistBalance", "gasBalance", "balance"):
        if k in c:
            tot += int(c[k]); break
print(tot)
' || echo 0)"
echo "gas balance     : ${BAL_MIST} mist"
if [[ "${BAL_MIST:-0}" -lt 2000000000 ]]; then
    echo "[FAIL] need >= 2 SUI for the upgrade. Top up via faucet." >&2
    exit 1
fi

echo "=== sui client upgrade (canonical deployer signs) ==="
echo "    upgrade-capability: $UPGRADE_CAP"
echo "    gas-budget        : $GAS_BUDGET"
echo ""

cd "$CONTRACTS_ROOT"
sui client upgrade --upgrade-capability "$UPGRADE_CAP" --gas-budget "$GAS_BUDGET"

echo ""
echo ">>> Upgrade submitted. POST-STEPS (do in order):"
echo "  1. Record the NEW upgraded package id into data/deploy_receipt.json"
echo "     as \"upgraded_package_id\" (the on-chain objType=package from the tx)."
echo "  2. Confirm Move.lock / Published.toml advanced to version 2; commit"
echo "     Move.lock + Published.toml + sources + scripts in ONE atomic commit."
echo "  3. sui client verify-source"
echo "  4. Re-run M8 steps 4-5 with PACKAGE_ID = upgraded id:"
echo "       bash scripts/replay_testnet.sh open    # ladder now uses snapped strikes"
echo "       (wait for settlement) bash scripts/replay_testnet.sh finalise"
echo "  5. Verify within_max_exposure post-ladder + redeem; band vs sim +/-1%."
echo "  6. Patch REPLAY.md ladder rows BLOCKED -> live digests; re-point the tag."
echo "  NEVER pass --with-unpublished-dependencies."
