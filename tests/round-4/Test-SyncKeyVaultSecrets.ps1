#Requires -Version 7.2
# =============================================================================
# tests/round-4/Test-SyncKeyVaultSecrets.ps1
# Round 4 §R4.4 acceptance test for scripts/secrets/Sync-KeyVaultSecrets.ps1
# and the bicep/modules/dr-keyvault-sync.bicep module.
#
# Strategy (no real Azure):
#   1. Synthesise an Event Grid event JSON for
#      Microsoft.KeyVault.SecretNewVersionCreated and write it under $env:TEMP.
#   2. Run the script with -DryRun and assert it logs "would write" + exits 0.
#   3. Synthesise a wrong-event-type payload and assert the script logs
#      "skipped" and exits 0 without raising.
#   4. With -DryRun + DRAAC_SECRETS_FORCE_INSYNC=1, assert the script logs
#      "would short-circuit as already-synced".
#   5. If a Bicep CLI is on PATH, compile the module and assert exit code 0.
#      Mirrors tests/round-2/Test-CheckDrCoverage.ps1's Test-BicepCliAvailable
#      pattern; skipped (PASS) when no CLI is available.
#
# Style: hand-rolled Assert helpers, no Pester. Exits 0/1.
# =============================================================================
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

$RepoRoot   = if ($env:DRAAC_REPO_ROOT) { $env:DRAAC_REPO_ROOT } else { (Resolve-Path (Join-Path $PSScriptRoot ".." "..")).Path }
$ScriptPath = Join-Path $RepoRoot 'scripts/secrets/Sync-KeyVaultSecrets.ps1'
$BicepPath  = Join-Path $RepoRoot 'bicep/modules/dr-keyvault-sync.bicep'

$Failures = [System.Collections.Generic.List[string]]::new()

function Assert-True {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { $Failures.Add("[FAIL] $Message") }
}

function Assert-Equal {
    param($Expected, $Actual, [string] $Message)
    if ($Expected -ne $Actual) {
        $Failures.Add("[FAIL] $Message`n         expected: $Expected`n         actual:   $Actual")
    }
}

function Assert-Match {
    param([string] $Pattern, [string] $Value, [string] $Message)
    if ($null -eq $Value) { $Value = '' }
    if ($Value -notmatch $Pattern) {
        $Failures.Add("[FAIL] $Message`n         pattern: $Pattern`n         value:   $Value")
    }
}

function Test-BicepCliAvailable {
    if (Get-Command bicep -ErrorAction SilentlyContinue) { return 'bicep' }
    if (Get-Command az    -ErrorAction SilentlyContinue) { return 'az' }
    return $null
}

function New-SecretEventJson {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Test helper writes a synthetic event payload to a per-test temp dir; outside the harness has no observable side effects.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Path,
        [string] $EventType  = 'Microsoft.KeyVault.SecretNewVersionCreated',
        [string] $VaultName  = 'kv-primary-test',
        [string] $ObjectName = 'my-secret',
        [string] $Version    = '0123456789abcdef0123456789abcdef',
        [string] $ObjectType = 'Secret'
    )
    $payload = [ordered]@{
        id          = [guid]::NewGuid().ToString()
        topic       = "/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/rg-primary/providers/Microsoft.KeyVault/vaults/$VaultName"
        subject     = $ObjectName
        eventType   = $EventType
        eventTime   = (Get-Date).ToUniversalTime().ToString('o')
        dataVersion = '1'
        data        = [ordered]@{
            Id         = "https://$VaultName.vault.azure.net/secrets/$ObjectName/$Version"
            VaultName  = $VaultName
            ObjectType = $ObjectType
            ObjectName = $ObjectName
            Version    = $Version
            NBF        = $null
            EXP        = $null
        }
    }
    ($payload | ConvertTo-Json -Depth 10) | Set-Content -Path $Path -Encoding UTF8
}

function Invoke-Script {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $EventFilePath,
        [Parameter(Mandatory)] [string] $LogDir,
        [string] $PrimaryVault = 'kv-primary-test',
        [string] $DrVault      = 'kv-dr-test',
        [switch] $DryRun
    )
    # Run the script under test in a child pwsh process and capture its
    # combined output stream to a log file so the test can assert on log lines.
    # This mirrors the run-in-subprocess style from Test-DRHealth.ps1.
    $null = New-Item -ItemType Directory -Force -Path $LogDir
    $logFile = Join-Path $LogDir ("run-" + [guid]::NewGuid().ToString('N') + '.log')

    $argList = @(
        '-NoProfile', '-File', $ScriptPath,
        '-EventFile',        $EventFilePath,
        '-PrimaryVaultName', $PrimaryVault,
        '-DrVaultName',      $DrVault
    )
    if ($DryRun) { $argList += '-DryRun' }

    & pwsh @argList *> $logFile
    $exit   = $LASTEXITCODE
    $output = if (Test-Path -LiteralPath $logFile) { Get-Content -Raw -LiteralPath $logFile } else { '' }
    if ($null -eq $output) { $output = '' }

    return [PSCustomObject]@{
        ExitCode = $exit
        Combined = $output
        LogFile  = $logFile
    }
}

# ── Setup ────────────────────────────────────────────────────────────────────

Assert-True (Test-Path $ScriptPath) "script under test exists at $ScriptPath"
Assert-True (Test-Path $BicepPath)  "bicep module exists at $BicepPath"

$Workdir = Join-Path $env:TEMP ("draac-kvsync-" + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Force -Path $Workdir

try {
    # ── Test 1: happy-path DryRun ────────────────────────────────────────────
    Write-Host ""
    Write-Host "── Test 1: happy path (DryRun) ──"
    $eventPath = Join-Path $Workdir 'event-happy.json'
    New-SecretEventJson -Path $eventPath

    # Make sure the in-sync override is OFF for this test.
    $env:DRAAC_SECRETS_FORCE_INSYNC = $null
    $r1 = Invoke-Script -EventFilePath $eventPath -LogDir $Workdir -DryRun
    Assert-Equal 0 $r1.ExitCode 'happy: exit code 0'
    Assert-Match 'would write secret'                  $r1.Combined 'happy: logs "would write secret …"'
    Assert-Match "version '0123456789abcdef0123456789abcdef'" $r1.Combined 'happy: logs the secret version from the event'
    Assert-Match "vault 'kv-dr-test'"                  $r1.Combined 'happy: logs the DR vault name'

    # ── Test 2: wrong-event-type → graceful skip ─────────────────────────────
    Write-Host ""
    Write-Host "── Test 2: wrong event type ──"
    $wrongPath = Join-Path $Workdir 'event-wrong.json'
    New-SecretEventJson -Path $wrongPath `
        -EventType 'Microsoft.KeyVault.CertificateNewVersionCreated' `
        -ObjectType 'Certificate'
    $r2 = Invoke-Script -EventFilePath $wrongPath -LogDir $Workdir -DryRun
    Assert-Equal 0 $r2.ExitCode 'wrong-type: exit code 0'
    Assert-Match 'skipped: eventType' $r2.Combined 'wrong-type: logs the skip-reason for non-secret events'
    # Must NOT have logged the "would write" line for a skipped event.
    Assert-True ($r2.Combined -notmatch 'would write secret') 'wrong-type: does not log "would write secret"'

    # ── Test 3: idempotency forced-in-sync branch ────────────────────────────
    Write-Host ""
    Write-Host "── Test 3: forced-in-sync (DRAAC_SECRETS_FORCE_INSYNC=1) ──"
    $env:DRAAC_SECRETS_FORCE_INSYNC = '1'
    try {
        $r3 = Invoke-Script -EventFilePath $eventPath -LogDir $Workdir -DryRun
        Assert-Equal 0 $r3.ExitCode 'in-sync: exit code 0'
        Assert-Match 'would short-circuit as already-synced' $r3.Combined 'in-sync: logs the short-circuit branch under DryRun'
    }
    finally {
        $env:DRAAC_SECRETS_FORCE_INSYNC = $null
    }

    # ── Test 4: missing required event field → throws ────────────────────────
    Write-Host ""
    Write-Host "── Test 4: malformed payload (missing Version) ──"
    $badPath = Join-Path $Workdir 'event-bad.json'
    @{
        id          = [guid]::NewGuid().ToString()
        eventType   = 'Microsoft.KeyVault.SecretNewVersionCreated'
        subject     = 'my-secret'
        eventTime   = (Get-Date).ToUniversalTime().ToString('o')
        dataVersion = '1'
        data        = @{ VaultName = 'kv-primary-test'; ObjectName = 'my-secret'; ObjectType = 'Secret' }
    } | ConvertTo-Json -Depth 10 | Set-Content -Path $badPath -Encoding UTF8
    $r4 = Invoke-Script -EventFilePath $badPath -LogDir $Workdir -DryRun
    Assert-True ($r4.ExitCode -ne 0) 'malformed: non-zero exit code'
    Assert-Match 'missing required fields' $r4.Combined 'malformed: logs the missing-fields error'

    # ── Test 5: optional Bicep compile ───────────────────────────────────────
    Write-Host ""
    Write-Host "── Test 5: bicep build (skipped if no CLI) ──"
    $cli = Test-BicepCliAvailable
    if ($null -eq $cli) {
        Write-Host "  bicep CLI not found on PATH — skipping the compile assertion."
    } else {
        $compileOut = Join-Path $Workdir 'dr-keyvault-sync.json'
        $exit = 0
        if ($cli -eq 'bicep') {
            & bicep build $BicepPath --outfile $compileOut 2>&1 | Out-Null
            $exit = $LASTEXITCODE
        } else {
            & az bicep build --file $BicepPath --outfile $compileOut 2>&1 | Out-Null
            $exit = $LASTEXITCODE
        }
        Assert-Equal 0 $exit 'bicep build exits 0'
        Assert-True (Test-Path $compileOut) 'bicep build produced an ARM JSON output'
    }
}
finally {
    if (Test-Path $Workdir) {
        Remove-Item -Recurse -Force $Workdir -ErrorAction SilentlyContinue
    }
    $env:DRAAC_SECRETS_FORCE_INSYNC = $null
}

Write-Host ""
if ($Failures.Count -eq 0) {
    Write-Host "Test-SyncKeyVaultSecrets: all assertions passed."
    exit 0
} else {
    Write-Host "FAILED: $($Failures.Count) assertion(s)" -ForegroundColor Red
    foreach ($f in $Failures) { Write-Host $f -ForegroundColor Red }
    exit 1
}
