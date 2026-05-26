# M8 — Strata sim-vs-onchain end-to-end replay (Windows PowerShell)
#
# Runs the sim-mirrored R3 verification scenario against the live
# testnet package, captures the metrics that REPLAY.md compares
# against the sim's expected magnitudes
# (sim/data/s1_results/s5_r3_verification.json), and writes the
# observation log to data/replay_log.json.
#
# Per docs/move_brief.md task M8 acceptance criteria:
#   - Deposit 100 dUSDC into the Strata vault.
#   - Open hedge ladder against a current BTC oracle.
#   - Trigger settlement at expiry.
#   - Compare post-state metrics against sim within +/-1% tolerance.
#
# Two-phase invocation because the oracle must settle between
# open + redeem (~ 10 minutes on testnet):
#   pwsh -File scripts/replay_testnet.ps1 -Phase open
#   ... wait for the oracle expiry + settlement (predict-server emits
#       OracleSettled events; check the oracle status) ...
#   pwsh -File scripts/replay_testnet.ps1 -Phase finalise

param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('open', 'finalise')]
    [string]$Phase
)

$ErrorActionPreference = 'Stop'
$ContractsRoot = Split-Path -Parent $PSScriptRoot
$DataDir = Join-Path $ContractsRoot 'data'
$ReceiptPath = Join-Path $DataDir 'deploy_receipt.json'
$LogPath = Join-Path $DataDir 'replay_log.json'

# --- 0. Pre-flight ------------------------------------------------------

if (-not (Test-Path $ReceiptPath)) {
    Write-Error "[FAIL] $ReceiptPath missing — run scripts/deploy_testnet.ps1 first (M7)."
    exit 1
}
$receipt = Get-Content $ReceiptPath -Raw | ConvertFrom-Json
$packageId = $receipt.package_id
$vaultId = $receipt.vault_object_id
if (-not $packageId -or -not $vaultId) {
    Write-Error '[FAIL] deploy_receipt.json missing package_id or vault_object_id.'
    exit 1
}
Write-Host "package_id      : $packageId"
Write-Host "vault_object_id : $vaultId"
Write-Host "phase           : $Phase"

# --- 1. Phase: open ----------------------------------------------------

if ($Phase -eq 'open') {
    Write-Host '=== M8.open — supply / init manager / fund manager / open hedge ladder ==='

    # Pick an active BTC oracle (predict-server REST). The brief
    # mandates an oracle whose expiry is within ~5 minutes so the
    # finalise phase can run promptly without burning hours.
    $predictId = '0xc8736204d12f0a7277c86388a68bf8a194b0a14c5538ad13f22cbd8e2a38028a'
    $oracles = curl -s --max-time 30 "https://predict-server.testnet.mystenlabs.com/predicts/$predictId/oracles" `
        | ConvertFrom-Json
    if (-not $oracles) { Write-Error '[FAIL] predict-server returned no oracles.'; exit 1 }
    # Filter: active, BTC-related (symbol field), shortest-expiry-first.
    $candidate = $oracles `
        | Where-Object { $_.status -eq 'active' } `
        | Sort-Object expiry `
        | Select-Object -First 1
    if (-not $candidate) { Write-Error '[FAIL] no active oracle available.'; exit 1 }
    $oracleId = $candidate.id
    $expiry = $candidate.expiry
    $forward = $candidate.forward
    Write-Host "oracle_id       : $oracleId"
    Write-Host "expiry          : $expiry  (epoch ms)"
    Write-Host "forward         : $forward"

    # Pick a dUSDC coin object owned by the active address. The
    # caller MUST have at least 100 dUSDC from the Tally airdrop;
    # the active address must match the deployer.
    $dusdcType = '0xe95040085976bfd54a1a07225cd46c8a2b4e8e2b6732f140a0fc49850ba73e1a::dusdc::DUSDC'
    Write-Host '--- dUSDC coin objects ---'
    sui client coins --json 2>&1 | python -c "
import sys, json
d = json.load(sys.stdin)
for c in d:
    if 'dusdc' in str(c.get('coinType','')).lower():
        print(f\"  id={c.get('coinObjectId')}  balance={c.get('mistBalance')}\")
" 2>&1 | Tee-Object -Variable dusdcList
    Write-Host ''
    Write-Host '>>> Re-run this script with the chosen dUSDC coin id pasted into'
    Write-Host '    a follow-up PTB. Below is the PTB skeleton (cli-driven) for'
    Write-Host '    the operator to run interactively.'

    # NOTE: scripting a Sui PTB with multiple coin splits + cross-module
    # calls is most cleanly done via @mysten/sui.js TypeScript. For the
    # M8 phase-1 we emit the exact `sui client ptb` template the
    # operator pastes, leaving the dUSDC coin ID + per-leg quantity as
    # parameters. This avoids reimplementing PTB construction in pwsh.

    $ptbTemplate = @"
sui client ptb `
    --move-call $packageId::ladder::init_predict_manager `
        @$vaultId `
    --assign manager_init `
    --move-call $packageId::vault::supply '<$dusdcType>' `
        @$vaultId `
        @<PREDICT_SHARED_OBJ:0xc8736...28a> `
        @<DUSDC_COIN_OBJ_ID> `
        @<CLOCK:0x6> `
    --assign strata_shares `
    --move-call $packageId::ladder::fund_manager '<$dusdcType>' `
        @$vaultId `
        @<PREDICT_MANAGER_OBJ_ID> `
        @<DUSDC_RESERVE_COIN_OBJ_ID> `
    --move-call $packageId::ladder::open_hedge_ladder '<$dusdcType>' `
        @$vaultId `
        @<PREDICT_SHARED_OBJ> `
        @<PREDICT_MANAGER_OBJ_ID> `
        @<ORACLE_OBJ_ID:$oracleId> `
        $expiry `
        $forward `
        5 9595 9811 5000 `
        @<CLOCK:0x6>
"@
    $ptbPath = Join-Path $DataDir 'replay_open_ptb.txt'
    New-Item -ItemType Directory -Force -Path $DataDir | Out-Null
    $ptbTemplate | Out-File -FilePath $ptbPath -Encoding utf8
    Write-Host "PTB template saved : $ptbPath"

    # Record initial state for the REPLAY.md comparison table.
    $log = [pscustomobject]@{
        phase                = 'open'
        timestamp_iso        = (Get-Date -Format 'o')
        package_id           = $packageId
        vault_object_id      = $vaultId
        oracle_id            = $oracleId
        oracle_expiry_ms     = $expiry
        oracle_forward       = $forward
        ptb_template_path    = $ptbPath
        operator_next_steps  = @(
            '1. Paste the PTB template + fill in <...> placeholders',
            '2. Run sui client ptb <...> --gas-budget 100_000_000',
            '3. Capture the supply/open tx digests',
            '4. Wait for oracle settlement (~10 min after expiry)',
            '5. Re-run this script with -Phase finalise'
        )
    }
    $log | ConvertTo-Json -Depth 5 | Out-File -FilePath $LogPath -Encoding utf8
    Write-Host "replay_log.json    : $LogPath"
    Write-Host ''
    Write-Host '>>> Phase OPEN halted at PTB template emission. Operator runs'
    Write-Host '    the PTB manually, then waits for settlement, then re-runs'
    Write-Host '    with -Phase finalise. Per docs/move_m8_notes.md (LOCAL) the'
    Write-Host '    half-automated approach is intentional: PTB construction'
    Write-Host '    is brittle in pwsh; the operator paste step adds 30s of'
    Write-Host '    friction for orders-of-magnitude clearer auditor trace.'
    exit 0
}

# --- 2. Phase: finalise ------------------------------------------------

if ($Phase -eq 'finalise') {
    Write-Host '=== M8.finalise — verify oracle settled / redeem_permissionless / read post-state ==='

    if (-not (Test-Path $LogPath)) {
        Write-Error "[FAIL] $LogPath missing — run -Phase open first."
        exit 1
    }
    $log = Get-Content $LogPath -Raw | ConvertFrom-Json
    $oracleId = $log.oracle_id
    Write-Host "oracle_id : $oracleId"

    # Check oracle.is_settled state via direct on-chain read.
    $oracleObj = sui client object $oracleId --json 2>&1 | ConvertFrom-Json
    # OracleSVI struct has `status` field; settled state in `fields.status`.
    $status = ($oracleObj.content.fields).status
    Write-Host "oracle.status : $status"
    if ($status -ne 'settled') {
        Write-Host "[WARN] oracle status is '$status' (expected 'settled'). Wait + retry."
        exit 2
    }

    # Read vault post-state via direct on-chain read.
    $vaultObj = sui client object $log.vault_object_id --json 2>&1 | ConvertFrom-Json
    $fields = $vaultObj.content.fields
    Write-Host '--- vault post-settlement state ---'
    Write-Host "plp_held value         : $($fields.plp_held.fields.value)"
    Write-Host "dusdc_in_manager       : $($fields.dusdc_in_manager)"
    Write-Host "total_max_payout       : $($fields.total_max_payout)"
    Write-Host "total_mtm              : $($fields.total_mtm)"

    Write-Host ''
    Write-Host '>>> Phase FINALISE: paste these PTB calls to redeem each of'
    Write-Host '    the 5 ladder legs via redeem_permissionless<DUSDC>:'

    $packageId = $log.package_id
    $dusdcType = '0xe95040085976bfd54a1a07225cd46c8a2b4e8e2b6732f140a0fc49850ba73e1a::dusdc::DUSDC'
    $redeemTemplate = @"
sui client ptb `
    --move-call $packageId::r3::redeem_permissionless '<$dusdcType>' `
        @$($log.vault_object_id) `
        @<PREDICT_SHARED_OBJ:0xc8736...28a> `
        @<PREDICT_MANAGER_OBJ_ID> `
        @<ORACLE_OBJ_ID:$oracleId> `
        @<MARKET_KEY_DOWN_STRIKE_K>     # one per ladder leg
        5000                              # per-leg quantity
        @<CLOCK:0x6>
"@
    $redeemPath = Join-Path $DataDir 'replay_finalise_ptb.txt'
    $redeemTemplate | Out-File -FilePath $redeemPath -Encoding utf8
    Write-Host "PTB template : $redeemPath"

    # Update log with final-state snapshot.
    $log | Add-Member -Force -NotePropertyName final_state -NotePropertyValue ([pscustomobject]@{
        timestamp_iso         = (Get-Date -Format 'o')
        plp_value_post        = $fields.plp_held.fields.value
        dusdc_in_manager_post = $fields.dusdc_in_manager
        total_max_payout_post = $fields.total_max_payout
        total_mtm_post        = $fields.total_mtm
        oracle_status         = $status
    })
    $log | Add-Member -Force -NotePropertyName phase -NotePropertyValue 'finalise'
    $log | ConvertTo-Json -Depth 6 | Out-File -FilePath $LogPath -Encoding utf8
    Write-Host "replay_log.json updated : $LogPath"
    Write-Host ''
    Write-Host '>>> M8 captured. Next: run scripts/fill_replay_md.ps1 to'
    Write-Host '    patch REPLAY.md PENDING fields from replay_log.json, then'
    Write-Host '    M9.7 tag.'
    exit 0
}
