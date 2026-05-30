#!/usr/bin/env bash
# replay_testnet.sh — M8 sim-vs-onchain end-to-end replay (WSL/bash port of
# replay_testnet.ps1, for Albary's Option-B WSL workflow).
#
# Runs the sim-mirrored R3 verification scenario against the live testnet
# package, captures the metrics REPLAY.md compares against the sim's expected
# magnitudes (sim/data/s1_results/s5_r3_verification.json), and writes the
# observation log to data/replay_log.json.
#
# Per docs/move_brief.md task M8 acceptance criteria:
#   - Deposit 100 dUSDC into the Strata vault.
#   - Open hedge ladder against a current BTC oracle.
#   - Trigger settlement at expiry.
#   - Compare post-state metrics against sim within +/-1% tolerance.
#
# Two-phase because the oracle must settle between open + redeem (~10 min on
# testnet). Like the .ps1 it is HALF-AUTOMATED: it picks the oracle, lists the
# dUSDC coin, reads on-chain state, and EMITS the exact `sui client ptb`
# template the operator signs manually (Option B). PTB construction is brittle
# to script; the 30s paste step buys an orders-of-magnitude clearer auditor
# trace.
#
#   bash scripts/replay_testnet.sh open       # pick oracle + emit open PTB
#   ... wait for oracle expiry + settlement (predict-server OracleSettled) ...
#   bash scripts/replay_testnet.sh finalise   # verify settled + read post-state
#
# Output schema of data/replay_log.json is kept BYTE-COMPATIBLE with
# scripts/fill_readme_after_deploy.sh (M9.5): final_state.dusdc_in_manager_post
# + final_state.total_max_payout_post are the two fields that script reads, plus
# the optional top-level *_tx_digest slots the operator fills from the PTB runs.
#
# Dependency: python3 + curl + sui CLI (same deps as the rest of scripts/).

set -euo pipefail

# --- arg parse ----------------------------------------------------------

PHASE="${1:-}"
case "$PHASE" in
    open|finalise) ;;
    -h|--help)
        grep -E '^# ' "$0" | sed 's/^# \{0,1\}//'
        exit 0
        ;;
    *)
        echo "[FAIL] usage: bash scripts/replay_testnet.sh {open|finalise}" >&2
        exit 1
        ;;
esac

# --- paths + constants --------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONTRACTS_ROOT="$(dirname "$SCRIPT_DIR")"
DATA_DIR="$CONTRACTS_ROOT/data"
RECEIPT_PATH="$DATA_DIR/deploy_receipt.json"
LOG_PATH="$DATA_DIR/replay_log.json"

# Canonical testnet protocol handles (verified in CLAUDE.md + appendix).
PREDICT_ID='0xc8736204d12f0a7277c86388a68bf8a194b0a14c5538ad13f22cbd8e2a38028a'
DUSDC_TYPE='0xe95040085976bfd54a1a07225cd46c8a2b4e8e2b6732f140a0fc49850ba73e1a::dusdc::DUSDC'
PREDICT_SERVER='https://predict-server.testnet.mystenlabs.com'

# --- 0. pre-flight ------------------------------------------------------

command -v python3 >/dev/null 2>&1 || { echo "[FAIL] python3 required (same dep as extract_publish_output.sh)." >&2; exit 1; }
command -v sui >/dev/null 2>&1     || { echo "[FAIL] sui CLI not on PATH." >&2; exit 1; }

if [[ ! -f "$RECEIPT_PATH" ]]; then
    echo "[FAIL] $RECEIPT_PATH missing — run the M7 publish + scripts/extract_publish_output.sh first." >&2
    exit 1
fi

# Read package_id + vault_object_id from the deploy receipt.
read -r PACKAGE_ID VAULT_ID < <(python3 - "$RECEIPT_PATH" <<'PY'
import sys, json
d = json.load(open(sys.argv[1]))
print(d.get("package_id") or "", d.get("vault_object_id") or "")
PY
)
if [[ -z "$PACKAGE_ID" || -z "$VAULT_ID" ]]; then
    echo "[FAIL] deploy_receipt.json missing package_id or vault_object_id." >&2
    exit 1
fi
echo "package_id      : $PACKAGE_ID"
echo "vault_object_id : $VAULT_ID"
echo "phase           : $PHASE"

# --- 1. phase: open -----------------------------------------------------

if [[ "$PHASE" == "open" ]]; then
    echo "=== M8.open — supply / init manager / fund manager / open hedge ladder ==="
    mkdir -p "$DATA_DIR"

    # Pick the shortest-expiry ACTIVE BTC oracle so finalise can run promptly.
    ORACLES_JSON="$(curl -s --max-time 30 "$PREDICT_SERVER/predicts/$PREDICT_ID/oracles" || true)"
    if [[ -z "$ORACLES_JSON" ]]; then
        echo "[FAIL] predict-server returned no oracles (network? predict-server down?)." >&2
        exit 1
    fi

    read -r ORACLE_ID EXPIRY FORWARD < <(ORACLES_JSON="$ORACLES_JSON" python3 <<'PY'
import os, json
try:
    data = json.loads(os.environ["ORACLES_JSON"])
except Exception:
    print("", "", ""); raise SystemExit
# predict-server may return a bare list or a wrapper {oracles|data: [...]}.
oracles = data if isinstance(data, list) else (data.get("oracles") or data.get("data") or [])
active = [o for o in oracles if str(o.get("status", "")).lower() == "active"]
if not active:
    print("", "", ""); raise SystemExit
active.sort(key=lambda o: o.get("expiry", 1 << 62))
o = active[0]
print(o.get("id", ""), o.get("expiry", ""), o.get("forward", ""))
PY
)
    if [[ -z "$ORACLE_ID" ]]; then
        echo "[FAIL] no active oracle available on predict $PREDICT_ID right now — retry shortly." >&2
        exit 1
    fi
    echo "oracle_id       : $ORACLE_ID"
    echo "expiry          : $EXPIRY  (epoch ms)"
    echo "forward         : $FORWARD"

    # Best-effort dUSDC coin listing (convenience; the operator already holds
    # 0xb8438e9b...edb8 from the Tally airdrop). Never fail the run on this.
    echo "--- dUSDC coin objects owned by the active address ---"
    DUSDC_OBJS_JSON="$(sui client objects --json 2>/dev/null || true)"
    DUSDC_OBJS_JSON="$DUSDC_OBJS_JSON" python3 <<'PY' || true
import os, json
try:
    objs = json.loads(os.environ.get("DUSDC_OBJS_JSON") or "[]")
except Exception:
    objs = []
found = False
for o in (objs if isinstance(objs, list) else []):
    blob = json.dumps(o).lower()
    if "dusdc" in blob:
        data = o.get("data", o) if isinstance(o, dict) else {}
        oid = data.get("objectId", "")
        print(f"  id={oid}")
        found = True
if not found:
    print("  (none surfaced by `sui client objects` — use the known airdrop coin"
          " 0xb8438e9bafc5472196572a3435b160109e45bb33acda73ed40b8f1353ec7edb8)")
PY

    # Emit the exact PTB the operator pastes (dUSDC coin id + manager obj left as
    # <...> params). Strikes 9595/9811 = PLP loss-onset band from the S0 sim
    # diagnostic; 5 legs; 5000 = per-leg $5 notional. Matches the .ps1 template.
    PTB_PATH="$DATA_DIR/replay_open_ptb.txt"
    cat > "$PTB_PATH" <<EOF
# M8.open PTB — fill the <...> placeholders, then run with --gas-budget 100000000
sui client ptb \\
    --move-call ${PACKAGE_ID}::ladder::init_predict_manager \\
        @${VAULT_ID} \\
    --assign manager_init \\
    --move-call ${PACKAGE_ID}::vault::supply '<${DUSDC_TYPE}>' \\
        @${VAULT_ID} \\
        @${PREDICT_ID} \\
        @<DUSDC_COIN_OBJ_ID> \\
        @0x6 \\
    --assign strata_shares \\
    --move-call ${PACKAGE_ID}::ladder::fund_manager '<${DUSDC_TYPE}>' \\
        @${VAULT_ID} \\
        @<PREDICT_MANAGER_OBJ_ID> \\
        @<DUSDC_RESERVE_COIN_OBJ_ID> \\
    --move-call ${PACKAGE_ID}::ladder::open_hedge_ladder '<${DUSDC_TYPE}>' \\
        @${VAULT_ID} \\
        @${PREDICT_ID} \\
        @<PREDICT_MANAGER_OBJ_ID> \\
        @${ORACLE_ID} \\
        ${EXPIRY} \\
        ${FORWARD} \\
        5 9595 9811 5000 \\
        @0x6
EOF
    echo "PTB template saved : $PTB_PATH"

    # Record open-phase state for the REPLAY.md comparison table.
    PACKAGE_ID="$PACKAGE_ID" VAULT_ID="$VAULT_ID" ORACLE_ID="$ORACLE_ID" \
    EXPIRY="$EXPIRY" FORWARD="$FORWARD" PTB_PATH="$PTB_PATH" LOG_PATH="$LOG_PATH" \
    python3 <<'PY'
import os, json, datetime
log = {
    "phase": "open",
    "timestamp_iso": datetime.datetime.utcnow().isoformat() + "Z",
    "package_id": os.environ["PACKAGE_ID"],
    "vault_object_id": os.environ["VAULT_ID"],
    "oracle_id": os.environ["ORACLE_ID"],
    "oracle_expiry_ms": os.environ["EXPIRY"],
    "oracle_forward": os.environ["FORWARD"],
    "ptb_template_path": os.environ["PTB_PATH"],
    # Operator fills these from the signed PTB digests (M9.5 reads them):
    "supply_tx_digest": "<PENDING-operator>",
    "init_manager_tx_digest": "<PENDING-operator>",
    "fund_manager_tx_digest": "<PENDING-operator>",
    "open_ladder_tx_digest": "<PENDING-operator>",
    "operator_next_steps": [
        "1. Fill <...> in replay_open_ptb.txt (dUSDC coin id + manager obj id)",
        "2. Run the PTB --gas-budget 100000000; capture the tx digests",
        "3. Paste digests into the *_tx_digest fields of replay_log.json",
        "4. Wait ~10 min for oracle settlement after expiry",
        "5. bash scripts/replay_testnet.sh finalise",
    ],
}
with open(os.environ["LOG_PATH"], "w", encoding="utf-8") as f:
    json.dump(log, f, indent=2)
print("replay_log.json    :", os.environ["LOG_PATH"])
PY

    echo ""
    echo ">>> Phase OPEN halted at PTB emission. Sign the PTB, wait for"
    echo "    settlement, then: bash scripts/replay_testnet.sh finalise"
    exit 0
fi

# --- 2. phase: finalise -------------------------------------------------

if [[ "$PHASE" == "finalise" ]]; then
    echo "=== M8.finalise — verify oracle settled / redeem_permissionless / read post-state ==="

    if [[ ! -f "$LOG_PATH" ]]; then
        echo "[FAIL] $LOG_PATH missing — run 'bash scripts/replay_testnet.sh open' first." >&2
        exit 1
    fi
    ORACLE_ID="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("oracle_id",""))' "$LOG_PATH")"
    echo "oracle_id : $ORACLE_ID"
    [[ -n "$ORACLE_ID" ]] || { echo "[FAIL] replay_log.json has no oracle_id." >&2; exit 1; }

    # Check oracle settlement via direct on-chain read.
    ORACLE_STATUS="$(sui client object "$ORACLE_ID" --json 2>/dev/null | python3 -c '
import sys, json
try:
    o = json.load(sys.stdin)
except Exception:
    print(""); raise SystemExit
f = (o.get("content") or {}).get("fields") or {}
print(f.get("status", ""))
')"
    echo "oracle.status : ${ORACLE_STATUS:-<unreadable>}"
    if [[ "$ORACLE_STATUS" != "settled" ]]; then
        echo "[WARN] oracle status is '${ORACLE_STATUS:-<unreadable>}' (expected 'settled'). Wait + retry." >&2
        exit 2
    fi

    # Read vault post-settlement state + update replay_log.json final_state.
    # final_state.dusdc_in_manager_post + total_max_payout_post are the exact
    # keys scripts/fill_readme_after_deploy.sh (M9.5) consumes.
    VAULT_ID="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("vault_object_id",""))' "$LOG_PATH")"
    VAULT_JSON="$(sui client object "$VAULT_ID" --json 2>/dev/null || true)"
    if [[ -z "$VAULT_JSON" ]]; then
        echo "[FAIL] could not read vault object $VAULT_ID on-chain." >&2
        exit 1
    fi

    VAULT_JSON="$VAULT_JSON" LOG_PATH="$LOG_PATH" ORACLE_STATUS="$ORACLE_STATUS" python3 <<'PY'
import os, json, datetime

vault = json.loads(os.environ["VAULT_JSON"])
fields = (vault.get("content") or {}).get("fields") or {}

def num(key):
    v = fields.get(key)
    if isinstance(v, dict):                 # nested {fields:{value:...}} wrappers
        v = (v.get("fields") or {}).get("value", v.get("value"))
    return v

plp_value = num("plp_held")
dusdc_in_manager = fields.get("dusdc_in_manager")
total_max_payout = fields.get("total_max_payout")
total_mtm = fields.get("total_mtm")

print("--- vault post-settlement state ---")
print("plp_held value   :", plp_value)
print("dusdc_in_manager :", dusdc_in_manager)
print("total_max_payout :", total_max_payout)
print("total_mtm        :", total_mtm)

log_path = os.environ["LOG_PATH"]
with open(log_path, encoding="utf-8") as f:
    log = json.load(f)
log["phase"] = "finalise"
log["final_state"] = {
    "timestamp_iso": datetime.datetime.utcnow().isoformat() + "Z",
    "plp_value_post": plp_value,
    "dusdc_in_manager_post": dusdc_in_manager,
    "total_max_payout_post": total_max_payout,
    "total_mtm_post": total_mtm,
    "oracle_status": os.environ["ORACLE_STATUS"],
}
# Operator fills these from the signed redeem PTBs (M9.5 reads them):
log.setdefault("dusdc_in_manager_pre_redeem", "<PENDING-operator>")
log.setdefault("redeem_tx_digests", ["<PENDING-operator>"])
log.setdefault("user_redeem_tx_digest", "<PENDING-operator>")
with open(log_path, "w", encoding="utf-8") as f:
    json.dump(log, f, indent=2)
print("replay_log.json updated :", log_path)
PY

    # Emit the redeem PTB template (one redeem_permissionless per ladder leg).
    PACKAGE_ID="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("package_id",""))' "$LOG_PATH")"
    REDEEM_PATH="$DATA_DIR/replay_finalise_ptb.txt"
    cat > "$REDEEM_PATH" <<EOF
# M8.finalise PTB — redeem each of the 5 ladder legs. Repeat the --move-call
# block per leg with that leg's MarketKey down-strike. --gas-budget 100000000.
sui client ptb \\
    --move-call ${PACKAGE_ID}::r3::redeem_permissionless '<${DUSDC_TYPE}>' \\
        @${VAULT_ID} \\
        @${PREDICT_ID} \\
        @<PREDICT_MANAGER_OBJ_ID> \\
        @${ORACLE_ID} \\
        @<MARKET_KEY_DOWN_STRIKE_K> \\
        5000 \\
        @0x6
EOF
    echo "PTB template : $REDEEM_PATH"

    echo ""
    echo ">>> M8 captured. Sign the redeem PTBs, fill the *_tx_digest +"
    echo "    dusdc_in_manager_pre_redeem fields in replay_log.json, then run"
    echo "    bash scripts/fill_readme_after_deploy.sh to patch REPLAY.md, then"
    echo "    cut the M9.7 tag."
    exit 0
fi
