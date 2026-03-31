#Requires -Version 7.2
# =============================================================================
# update-drift-readme.ps1
# Stage 4b: Update or create CONFIGURATION-DRIFT.md in the repository.
# Idempotent: upserts the entry for the current PR run.
# =============================================================================
param(
  [Parameter(Mandatory)][string] $DriftReportPath,
  [Parameter(Mandatory)][string] $RepoRoot,
  [Parameter(Mandatory)][string] $RunId,
  [Parameter(Mandatory)][string] $PrId,
  [Parameter(Mandatory)][string] $SourceBranch
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$DriftFile   = Join-Path $RepoRoot "CONFIGURATION-DRIFT.md"
$Timestamp   = (Get-Date -Format "yyyy-MM-dd HH:mm") + " UTC"
$ReportDate  = Get-Date -Format "yyyy-MM-dd"

# ── Load drift report ─────────────────────────────────────────────────────────
if (-not (Test-Path $DriftReportPath)) {
  Write-Error "Drift report not found: $DriftReportPath"
  exit 1
}

$Report  = Get-Content $DriftReportPath -Raw | ConvertFrom-Json
$Summary = $Report.summary
$Items   = $Report.driftItems

$TotalDrift    = $Summary.totalDriftItems
$Critical      = $Summary.critical
$Warnings      = $Summary.warnings
$InCodeAzure   = $Summary.deployedAndInCode
$AzureNotCode  = $Summary.deployedNotInCode
$CodeNotAzure  = $Summary.inCodeNotDeployed

# ── Status badge ──────────────────────────────────────────────────────────────
$StatusBadge = if ($Critical -gt 0)       { "🔴 CRITICAL" }
               elseif ($Warnings -gt 0)   { "🟡 WARNING" }
               else                        { "🟢 CLEAN" }

# ── Build PR entry block ──────────────────────────────────────────────────────
$CriticalItems = $Items | Where-Object { $_.severity -eq "critical" }
$WarningItems  = $Items | Where-Object { $_.severity -eq "warning"  }

$CriticalRows = if ($CriticalItems) {
  $CriticalItems | ForEach-Object {
    $name = $_.resourceName ?? $_.file ?? "N/A"
    $type = $_.driftType
    $desc = $_.description
    "| ``$name`` | $type | $desc |"
  }
} else { @("| — | — | No critical drift found |") }

$WarningRows = if ($WarningItems) {
  $WarningItems | ForEach-Object {
    $name = $_.resourceName ?? $_.file ?? "N/A"
    $type = $_.driftType
    $desc = $_.description
    "| ``$name`` | $type | $desc |"
  }
} else { @("| — | — | No warnings |") }

$CriticalTable = @(
  "| Resource / File | Drift Type | Description |",
  "|---|---|---|"
) + $CriticalRows | Out-String

$WarningTable = @(
  "| Resource / File | Drift Type | Description |",
  "|---|---|---|"
) + $WarningRows | Out-String

$NewEntry = @"

---

## PR #$PrId · $SourceBranch · $ReportDate

> **Status:** $StatusBadge  
> **Pipeline Run:** ``$RunId``  
> **Analysed at:** $Timestamp

### Summary

| Metric | Count |
|---|---|
| 🔴 Critical Drift Items | $Critical |
| 🟡 Warnings | $Warnings |
| ✅ Resources in Code + Azure | $InCodeAzure |
| ⚠️ Deployed, Not in Code | $AzureNotCode |
| ❌ In Code, Not Deployed | $CodeNotAzure |
| **Total Drift Items** | **$TotalDrift** |

### Critical Items

$CriticalTable

### Warnings

$WarningTable

### Recommendations

$(if ($CodeNotAzure -gt 0) { "- 🚨 **$CodeNotAzure resource(s)** are defined in IaC but not found in Azure. Deploy them before merging." })
$(if ($AzureNotCode -gt 0) { "- ⚠️  **$AzureNotCode resource(s)** exist in Azure but have no IaC definition. Consider adding them to code." })
$(if ($TotalDrift -eq 0)   { "- ✅ No drift detected. All checked resources are consistent between code and Azure." })

"@

# ── Read existing file or create header ──────────────────────────────────────
if (Test-Path $DriftFile) {
  $Existing = Get-Content $DriftFile -Raw
} else {
  $Existing = @"
# Configuration Drift Report

> This file tracks infrastructure configuration drift detected during PR validation.
> It is automatically updated by the Azure Compliance Pipeline on every pull request to `main`.
> **Do not edit manually** — changes will be overwritten.

---

_No entries yet. Run the compliance pipeline to generate the first report._
"@
}

# ── Upsert: replace existing entry for this PR, or prepend ───────────────────
$PrAnchor   = "## PR #$PrId ·"
$HeaderLine = "# Configuration Drift Report"

if ($Existing -match [regex]::Escape($PrAnchor)) {
  # Replace existing block for this PR
  $Pattern  = "(?s)(---\s*\r?\n## PR #$([regex]::Escape($PrId)) ·.*?)(?=\r?\n---|\z)"
  $Existing = [regex]::Replace($Existing, $Pattern, $NewEntry.TrimStart())
  Write-Host "INFO: Updated existing PR #$PrId entry in CONFIGURATION-DRIFT.md"
} else {
  # Prepend after header block
  $SplitAt = $Existing.IndexOf("`n---")
  if ($SplitAt -ge 0) {
    $Existing = $Existing.Substring(0, $SplitAt) + $NewEntry + $Existing.Substring($SplitAt)
  } else {
    $Existing = $Existing + $NewEntry
  }
  Write-Host "INFO: Prepended new PR #$PrId entry to CONFIGURATION-DRIFT.md"
}

# ── Write file ────────────────────────────────────────────────────────────────
$Existing | Set-Content $DriftFile -Encoding UTF8 -NoNewline
Write-Host "SUCCESS: CONFIGURATION-DRIFT.md updated at $DriftFile"
Write-Host "  Status:   $StatusBadge"
Write-Host "  Critical: $Critical"
Write-Host "  Warnings: $Warnings"
