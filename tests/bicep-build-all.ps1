#Requires -Version 7.2
# =============================================================================
# tests/bicep-build-all.ps1
# Builds every *.bicep under bicep/modules/ and bicep/regions/ to validate
# that they compile cleanly. Non-zero exit on any compilation failure.
# Idempotent: builds are deterministic; re-runs produce same artefacts/output.
# Fault-tolerant: continues on per-file failures, reports them at the end.
# =============================================================================
[CmdletBinding()]
param(
    [string[]] $Path = @("bicep/modules", "bicep/regions")
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$Failed   = [System.Collections.Generic.List[object]]::new()
$Built    = 0

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    Write-Warning "Azure CLI not found — skipping bicep build (treated as PASS for now)."
    exit 0
}

foreach ($rel in $Path) {
    $abs = Join-Path $RepoRoot $rel
    if (-not (Test-Path $abs)) {
        Write-Host "  Skipping $rel — does not exist yet (Round 4 introduces these dirs)."
        continue
    }

    $files = Get-ChildItem -Path $abs -Filter "*.bicep" -Recurse -File
    foreach ($f in $files) {
        Write-Host "  Building: $($f.FullName.Substring($RepoRoot.Length + 1))"
        $output = az bicep build --file $f.FullName --stdout 2>&1
        if ($LASTEXITCODE -ne 0) {
            $Failed.Add([PSCustomObject]@{ File = $f.FullName; Error = ($output | Out-String) })
        } else {
            $Built++
        }
    }
}

Write-Host ""
Write-Host "Bicep build: $Built succeeded, $($Failed.Count) failed."
if ($Failed.Count -gt 0) {
    foreach ($f in $Failed) {
        Write-Warning "  $($f.File)"
        Write-Warning "    $($f.Error.Trim())"
    }
    exit 1
}
exit 0
