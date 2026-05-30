#!/usr/bin/env bash
# fill_readme_after_deploy.sh — M9.5 doc-filler (WSL/bash port of
# fill_readme_after_deploy.ps1, for Albary's Option-B WSL workflow).
#
# Fills the PENDING placeholders in README.md + REPLAY.md from the
# canonical deploy/replay receipts, then audits what still needs the
# operator's hand.
#
# Inputs (relative to contracts/ root):
#   data/deploy_receipt.json   (REQUIRED — written by
#                               scripts/extract_publish_output.sh after
#                               `sui client publish --json`)
#   data/replay_log.json       (OPTIONAL — written after M8 replay;
#                               REPLAY.md fill is skipped without it)
#
# Idempotent: on first run it caches README.md/REPLAY.md as
# *.template, then always re-renders from those originals, so re-running
# after an updated receipt/log is safe and deterministic.
#
# Dependency: python3 (same as scripts/extract_publish_output.sh — if
# that script ran for you, this one will too). No jq required.
#
# Usage:
#   bash scripts/fill_readme_after_deploy.sh            # write in place
#   bash scripts/fill_readme_after_deploy.sh --dry-run  # preview only
#
# NOTE on the bash port vs the .ps1: the PowerShell version's README
# package-address / tx-digest fills used a cross-row regex that does not
# match the actual two-line markdown table (the two `<PENDING M7
# publish>` cells sit on consecutive rows). This port fixes that by
# filling each cell on its own labelled row, so the README is correctly
# populated. REPLAY.md fills mirror the .ps1 one-to-one.

set -euo pipefail

# --- arg parse ----------------------------------------------------------

DRY_RUN=0
for arg in "$@"; do
    case "$arg" in
        --dry-run|-n) DRY_RUN=1 ;;
        -h|--help)
            grep -E '^# ' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            echo "[FAIL] unknown arg: $arg (use --dry-run or -h)" >&2
            exit 1
            ;;
    esac
done

# --- paths --------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONTRACTS_ROOT="$(dirname "$SCRIPT_DIR")"
DATA_DIR="$CONTRACTS_ROOT/data"

RECEIPT_PATH="$DATA_DIR/deploy_receipt.json"
REPLAY_PATH="$DATA_DIR/replay_log.json"

README_PATH="$CONTRACTS_ROOT/README.md"
REPLAY_DOC_PATH="$CONTRACTS_ROOT/REPLAY.md"
README_TEMPLATE_PATH="$CONTRACTS_ROOT/README.md.template"
REPLAY_TEMPLATE_PATH="$CONTRACTS_ROOT/REPLAY.md.template"

# --- 0. sanity ----------------------------------------------------------

if ! command -v python3 >/dev/null 2>&1; then
    echo "[FAIL] python3 not found — required for JSON parsing (same dep as extract_publish_output.sh)." >&2
    exit 1
fi

if [[ ! -f "$RECEIPT_PATH" ]]; then
    echo "[FAIL] $RECEIPT_PATH missing — run the publish + scripts/extract_publish_output.sh first (M7)." >&2
    exit 1
fi

# --- 1. template caching (cache originals before first overwrite) ------

ensure_template() {
    local source="$1" template="$2"
    if [[ ! -f "$template" ]]; then
        echo "[init] caching template: $template"
        cp "$source" "$template"
    fi
}
ensure_template "$README_PATH" "$README_TEMPLATE_PATH"
ensure_template "$REPLAY_DOC_PATH" "$REPLAY_TEMPLATE_PATH"

# --- 2+3. render via python3 (robust JSON + string handling) -----------

RECEIPT_PATH="$RECEIPT_PATH" \
REPLAY_PATH="$REPLAY_PATH" \
README_PATH="$README_PATH" \
REPLAY_DOC_PATH="$REPLAY_DOC_PATH" \
README_TEMPLATE_PATH="$README_TEMPLATE_PATH" \
REPLAY_TEMPLATE_PATH="$REPLAY_TEMPLATE_PATH" \
DRY_RUN="$DRY_RUN" \
python3 <<'PYEOF'
import os, json

dry_run = os.environ.get("DRY_RUN", "0") == "1"

receipt_path = os.environ["RECEIPT_PATH"]
replay_path = os.environ["REPLAY_PATH"]
readme_path = os.environ["README_PATH"]
replay_doc_path = os.environ["REPLAY_DOC_PATH"]
readme_tpl = os.environ["README_TEMPLATE_PATH"]
replay_tpl = os.environ["REPLAY_TEMPLATE_PATH"]

ADDRESS_X = "0x67606efb71792fdb505e123f020cfaaf19d9c54d3b07bf399b5fa08072f72eac"

with open(receipt_path, encoding="utf-8") as f:
    receipt = json.load(f)

replay = None
if os.path.isfile(replay_path):
    with open(replay_path, encoding="utf-8") as f:
        replay = json.load(f)

# --- README (from template + deploy receipt) ---------------------------

print("=== M9.5 - render README.md from template ===")
with open(readme_tpl, encoding="utf-8") as f:
    readme = f.read()

pkg = receipt.get("package_id") or "<PENDING M7 publish>"
tx = receipt.get("deploy_tx_digest") or "<PENDING M7 publish>"
deployer = receipt.get("deployer_address") or ADDRESS_X

# The two `<PENDING M7 publish>` cells are identical and sit on
# consecutive rows, so fill each on its own labelled row (this is the
# correctness fix over the .ps1 cross-row regex).
out_lines = []
for ln in readme.splitlines(keepends=True):
    if "| Package address |" in ln and "<PENDING M7 publish>" in ln:
        ln = ln.replace("<PENDING M7 publish>", pkg)
    elif "| Deploy tx digest |" in ln and "<PENDING M7 publish>" in ln:
        ln = ln.replace("<PENDING M7 publish>", tx)
    elif "Deployer (testnet)" in ln:
        ln = ln.replace(ADDRESS_X, deployer)
    out_lines.append(ln)
readme = "".join(out_lines)

if dry_run:
    print("--- README.md (would write) ---")
    for ln in readme.splitlines():
        if ("| Package address" in ln) or ("| Deploy tx digest |" in ln) or ("| Deployer" in ln):
            print("  " + ln)
else:
    with open(readme_path, "w", encoding="utf-8") as f:
        f.write(readme)
    print("[wrote] " + readme_path)

# --- REPLAY (from template + replay log; optional) ---------------------

if replay is None or not replay.get("final_state"):
    print("=== M9.5 - REPLAY.md fill SKIPPED (data/replay_log.json missing "
          "final_state - run the M8 replay finalise phase first) ===")
else:
    print("=== M9.5 - render REPLAY.md from template ===")
    with open(replay_tpl, encoding="utf-8") as f:
        replay_doc = f.read()

    final = replay["final_state"]
    supply_tx = replay.get("supply_tx_digest", "<MISSING>")
    init_mgr_tx = replay.get("init_manager_tx_digest", "<MISSING>")
    fund_tx = replay.get("fund_manager_tx_digest", "<MISSING>")
    open_tx = replay.get("open_ladder_tx_digest", "<MISSING>")
    redeem_list = replay.get("redeem_tx_digests")
    redeem_tx = ", ".join(redeem_list) if redeem_list else "<MISSING>"
    user_redeem_tx = replay.get("user_redeem_tx_digest", "<MISSING>")

    post = final.get("dusdc_in_manager_post")
    pre = replay.get("dusdc_in_manager_pre_redeem")
    r3_delta = str(post - pre) if (post is not None and pre is not None) else "<DERIVED-MISSING>"

    total_max_payout_post = final.get("total_max_payout_post", "<MISSING>")

    # Sim-expected cells flagged `<run-sim-matched-path>` are left for
    # the operator to populate from a matched s5_main.py run on the same
    # SVI path (per the M8 brief). This script fills only the on-chain
    # side + the regression-protected R3 sim expectation ($383,063).
    repls = [
        ("`total_max_payout` post-mint | `<PENDING>` | `<PENDING>`",
         "`total_max_payout` post-mint | `<run-sim-matched-path>` | `%s`" % total_max_payout_post),
        ("`share_price_micro` pre-settlement | `<PENDING>` | `<PENDING>`",
         "`share_price_micro` pre-settlement | `<run-sim-matched-path>` | `<read-pre-settle>`"),
        ("R3 `liquid_cash_delta` | `<PENDING>` | `<PENDING>`",
         "R3 `liquid_cash_delta` | `383063 (sim verified)` | `%s`" % r3_delta),
        ("`share_price_micro` post-R3 | `<PENDING>` | `<PENDING>`",
         "`share_price_micro` post-R3 | `<run-sim-matched-path>` | `<read-post-R3>`"),
        ("`vault::supply<DUSDC>` of 100 dUSDC | `<PENDING>`",
         "`vault::supply<DUSDC>` of 100 dUSDC | `%s`" % supply_tx),
        ("`ladder::init_predict_manager` | `<PENDING>` (one-time, pre-supply)",
         "`ladder::init_predict_manager` | `%s` (one-time, pre-supply)" % init_mgr_tx),
        ("`ladder::fund_manager<DUSDC>` of ~10 dUSDC | `<PENDING>`",
         "`ladder::fund_manager<DUSDC>` of ~10 dUSDC | `%s`" % fund_tx),
        ("`ladder::open_hedge_ladder<DUSDC>` (5-leg) | `<PENDING>`",
         "`ladder::open_hedge_ladder<DUSDC>` (5-leg) | `%s`" % open_tx),
        ("`r3::redeem_permissionless<DUSDC>` × 5 legs | `<PENDING>`",
         "`r3::redeem_permissionless<DUSDC>` × 5 legs | `%s`" % redeem_tx),
        ("`vault::redeem<DUSDC>` of 100 Strata shares | `<PENDING>`",
         "`vault::redeem<DUSDC>` of 100 Strata shares | `%s`" % user_redeem_tx),
    ]
    for old, new in repls:
        replay_doc = replay_doc.replace(old, new)

    if dry_run:
        print("--- REPLAY.md (would write) ---")
        for ln in replay_doc.splitlines():
            if ("| `<run-sim" in ln) or ("liquid_cash_delta" in ln):
                print("  " + ln)
    else:
        with open(replay_doc_path, "w", encoding="utf-8") as f:
            f.write(replay_doc)
        print("[wrote] " + replay_doc_path)
PYEOF

# --- 4. audit remaining placeholders -----------------------------------

echo ""
echo "=== unfilled placeholders (operator must address) ==="
PENDING_FOUND=0
for f in "$README_PATH" "$REPLAY_DOC_PATH"; do
    [[ -f "$f" ]] || continue
    while IFS= read -r line; do
        echo "  $line"
        PENDING_FOUND=1
    done < <(grep -nHE 'PENDING|<MISSING>|<DERIVED-MISSING>|<run-sim-matched-path>' "$f" || true)
done
if [[ "$PENDING_FOUND" -eq 0 ]]; then
    echo "  (none — README + REPLAY fully filled, ready for M9.7 tag)"
fi
echo ""
echo ">>> Commit + push the doc updates, then cut the M9.7 tag."
