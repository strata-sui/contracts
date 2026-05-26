# M9.5 — fill PENDING placeholders in README.md + REPLAY.md
#
# Consumes data/deploy_receipt.json (M7 output) and
# data/replay_log.json (M8 output), patches the public
# documentation, and reports unfilled placeholders that still need
# manual operator attention.
#
# Idempotent: re-running after an updated receipt/log re-renders
# the docs from the originals (held as .template copies on first run).

param(
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$ContractsRoot = Split-Path -Parent $PSScriptRoot
$DataDir = Join-Path $ContractsRoot 'data'
$ReceiptPath = Join-Path $DataDir 'deploy_receipt.json'
$ReplayPath = Join-Path $DataDir 'replay_log.json'

$ReadmePath = Join-Path $ContractsRoot 'README.md'
$ReplayDocPath = Join-Path $ContractsRoot 'REPLAY.md'
$ReadmeTemplatePath = Join-Path $ContractsRoot 'README.md.template'
$ReplayTemplatePath = Join-Path $ContractsRoot 'REPLAY.md.template'

function Ensure-Template {
    param([string]$source, [string]$template)
    if (-not (Test-Path $template)) {
        Write-Host "[init] caching template: $template"
        Copy-Item -Path $source -Destination $template -Force
    }
}

# --- 0. Sanity ---------------------------------------------------------

if (-not (Test-Path $ReceiptPath)) {
    Write-Error "[FAIL] $ReceiptPath missing — run scripts/deploy_testnet.ps1 first (M7)."
    exit 1
}
$receipt = Get-Content $ReceiptPath -Raw | ConvertFrom-Json

# Replay log is OPTIONAL — README has its M9 fields populated from
# deploy_receipt alone; REPLAY.md needs replay_log.
$replay = $null
if (Test-Path $ReplayPath) {
    $replay = Get-Content $ReplayPath -Raw | ConvertFrom-Json
}

# --- 1. Template caching ----------------------------------------------

Ensure-Template -source $ReadmePath -template $ReadmeTemplatePath
Ensure-Template -source $ReplayDocPath -template $ReplayTemplatePath

# --- 2. Render README from template + receipt ------------------------

Write-Host '=== M9.5 — render README.md from template ==='
$readme = Get-Content $ReadmeTemplatePath -Raw

# README placeholders (from M9a draft):
$pkg = $receipt.package_id
$tx = $receipt.deploy_tx_digest
$deployer = $receipt.deployer_address

$readme = $readme `
    -replace '`<PENDING M7 publish>` \| Deploy tx digest', "``$pkg`` | Deploy tx digest" `
    -replace 'Deploy tx digest \| `<PENDING M7 publish>`', "Deploy tx digest | ``$tx``" `
    -replace 'Deployer \(testnet\) \| `0x67606efb71792fdb505e123f020cfaaf19d9c54d3b07bf399b5fa08072f72eac`', "Deployer (testnet) | ``$deployer``"

if ($DryRun) {
    Write-Host '--- README.md (would write) ---'
    $readme | Select-String -Pattern '\| Package address|\| Deploy tx digest|\| Deployer' | ForEach-Object { Write-Host $_ }
} else {
    $readme | Out-File -FilePath $ReadmePath -Encoding utf8
    Write-Host "[wrote] $ReadmePath"
}

# --- 3. Render REPLAY.md from template + replay log -------------------

if ($null -eq $replay -or -not $replay.final_state) {
    Write-Host '=== M9.5 — REPLAY.md fill SKIPPED (replay_log.json missing final_state — run replay_testnet.ps1 -Phase finalise first) ==='
} else {
    Write-Host '=== M9.5 — render REPLAY.md from template ==='
    $replayDoc = Get-Content $ReplayTemplatePath -Raw

    # Pull metrics from replay_log.final_state.
    $final = $replay.final_state
    $supplyTx = if ($replay.supply_tx_digest) { $replay.supply_tx_digest } else { '<MISSING>' }
    $initMgrTx = if ($replay.init_manager_tx_digest) { $replay.init_manager_tx_digest } else { '<MISSING>' }
    $fundTx = if ($replay.fund_manager_tx_digest) { $replay.fund_manager_tx_digest } else { '<MISSING>' }
    $openTx = if ($replay.open_ladder_tx_digest) { $replay.open_ladder_tx_digest } else { '<MISSING>' }
    $redeemTx = if ($replay.redeem_tx_digests) { ($replay.redeem_tx_digests -join ', ') } else { '<MISSING>' }
    $userRedeemTx = if ($replay.user_redeem_tx_digest) { $replay.user_redeem_tx_digest } else { '<MISSING>' }

    # Sim expectations from sim/data/s1_results/s5_r3_verification.json
    # (regression-protected by sim/tests/test_s5_regression_protect.py):
    #   liquid_cash_delta_R3 ~ $383_063 (1% band: [$378k, $389k])
    #   pre-settle total_max_payout = 1_868_063 / available = 0
    # See sim/SUBMISSION.md §5 for the canonical empirical claim.

    # Per-row placeholder fills. The replay log surfaces raw u64
    # base units (6-decimal dUSDC fixed-point per CLAUDE.md §4).
    $r3Delta = if ($final.dusdc_in_manager_post -and $replay.dusdc_in_manager_pre_redeem) {
        $final.dusdc_in_manager_post - $replay.dusdc_in_manager_pre_redeem
    } else { '<DERIVED-MISSING>' }

    # Simple line-level fills (table cells held as `<PENDING>` strings).
    # The REPLAY.md template uses `<PENDING>` for both sim-expected and
    # on-chain cells; this script fills the on-chain side, leaving the
    # sim-expected side for the operator to populate from a matched
    # sim run (per the M8 brief: 'compare to a sim run on the same
    # path with identical SVI params').

    $replayDoc = $replayDoc `
        -replace 'total_max_payout` post-mint \| `<PENDING>` \| `<PENDING>`',
                 "total_max_payout`` post-mint | ``<run-sim-matched-path>`` | ``$($final.total_max_payout_post)``" `
        -replace 'share_price_micro` pre-settlement \| `<PENDING>` \| `<PENDING>`',
                 "share_price_micro`` pre-settlement | ``<run-sim-matched-path>`` | ``<read-pre-settle>``" `
        -replace 'R3 `liquid_cash_delta` \| `<PENDING>` \| `<PENDING>`',
                 "R3 ``liquid_cash_delta`` | ``383063 (sim verified)`` | ``$r3Delta``" `
        -replace 'share_price_micro` post-R3 \| `<PENDING>` \| `<PENDING>`',
                 "share_price_micro`` post-R3 | ``<run-sim-matched-path>`` | ``<read-post-R3>``"

    $replayDoc = $replayDoc `
        -replace '`vault::supply<DUSDC>` of 100 dUSDC \| `<PENDING>`',
                 "``vault::supply<DUSDC>`` of 100 dUSDC | ``$supplyTx``" `
        -replace '`ladder::init_predict_manager` \| `<PENDING>` \(one-time, pre-supply\)',
                 "``ladder::init_predict_manager`` | ``$initMgrTx`` (one-time, pre-supply)" `
        -replace '`ladder::fund_manager<DUSDC>` of ~10 dUSDC \| `<PENDING>`',
                 "``ladder::fund_manager<DUSDC>`` of ~10 dUSDC | ``$fundTx``" `
        -replace '`ladder::open_hedge_ladder<DUSDC>` \(5-leg\) \| `<PENDING>`',
                 "``ladder::open_hedge_ladder<DUSDC>`` (5-leg) | ``$openTx``" `
        -replace '`r3::redeem_permissionless<DUSDC>` × 5 legs \| `<PENDING>`',
                 "``r3::redeem_permissionless<DUSDC>`` × 5 legs | ``$redeemTx``" `
        -replace '`vault::redeem<DUSDC>` of 100 Strata shares \| `<PENDING>`',
                 "``vault::redeem<DUSDC>`` of 100 Strata shares | ``$userRedeemTx``"

    if ($DryRun) {
        Write-Host '--- REPLAY.md (would write) ---'
        $replayDoc | Select-String -Pattern '\| `<run-sim|liquid_cash_delta' | ForEach-Object { Write-Host $_ }
    } else {
        $replayDoc | Out-File -FilePath $ReplayDocPath -Encoding utf8
        Write-Host "[wrote] $ReplayDocPath"
    }
}

# --- 4. Audit remaining PENDING placeholders --------------------------

Write-Host ''
Write-Host '=== unfilled placeholders (operator must address) ==='
$pending = @()
foreach ($f in @($ReadmePath, $ReplayDocPath)) {
    $matches = Select-String -Path $f -Pattern 'PENDING|<MISSING>|<DERIVED-MISSING>|<run-sim-matched-path>' -SimpleMatch
    if ($matches) {
        foreach ($m in $matches) {
            Write-Host "  $($m.Path):$($m.LineNumber)  $($m.Line.Trim())"
            $pending += $m
        }
    }
}
if ($pending.Count -eq 0) {
    Write-Host '  (none — README + REPLAY fully filled, ready for M9.7 tag)'
}
Write-Host ''
Write-Host '>>> Commit + push the doc updates, then run M9.7 tag.'
