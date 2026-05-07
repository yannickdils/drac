#Requires -Version 7.2
# =============================================================================
# write-job-summary.ps1
# Writes a rich markdown summary to $GITHUB_STEP_SUMMARY.
# This populates the "Summary" tab on the GitHub Actions run page.
# =============================================================================
param(
  [Parameter(Mandatory)][string] $ScanDir,
  [Parameter(Mandatory)][string] $ReviewDir,
  [Parameter(Mandatory)][string] $DriftDir,
  [Parameter(Mandatory)][string] $DrDir,
  [Parameter(Mandatory)][string] $SummaryFile,
  [string] $ExportDir = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

function Get-ReportJson($path) {
  if (Test-Path $path) { return Get-Content $path -Raw | ConvertFrom-Json }
  return $null
}

$ScanSummary  = Get-ReportJson (Join-Path $ScanDir   "scan-summary.json")
$MatchReport  = Get-ReportJson (Join-Path $ReviewDir "deployment-match-report.json")
$DriftReport  = Get-ReportJson (Join-Path $DriftDir  "drift-report.json")
$DrSummary    = Get-ReportJson (Join-Path $DrDir     "dr-summary.json")
$DrValidation = Get-ReportJson (Join-Path $DrDir     "dr-validation-report.json")
$DrHealthReport     = Get-ReportJson (Join-Path $DrDir "dr-health-report.json")
$UnsupportedSummary = if ($ExportDir) { Get-ReportJson (Join-Path $ExportDir "unsupported-summary.json") } else { $null }
# Round 5 §R5.6 / §R5.7 / §R5.8 — slow drift, SKU availability, API-version compat.
$SlowDriftReport     = Get-ReportJson (Join-Path $ScanDir "slow-drift.json")
$SkuAvailability     = Get-ReportJson (Join-Path $DrDir   "sku-availability.json")
$ApiVersionCompat    = Get-ReportJson (Join-Path $DrDir   "api-version-compat.json")

$DriftCritical          = if ($DriftReport)         { $DriftReport.summary.critical             } else { 0 }
$DriftWarnings          = if ($DriftReport)         { $DriftReport.summary.warnings             } else { 0 }
$Coverage               = if ($MatchReport)         { $MatchReport.summary.deploymentCoverage   } else { "N/A" }
$DrRegion               = if ($DrSummary)           { $DrSummary.drRegion                       } else { "N/A" }
$DrGenerated            = if ($DrSummary)           { $DrSummary.processed                      } else { 0 }
$DriftSeverity          = if ($DriftCritical -gt 0) { "critical" } elseif ($DriftWarnings -gt 0) { "warning" } else { "ok" }
$DrHealthStatus         = if ($DrHealthReport)      { $DrHealthReport.summary.status            } else { "N/A" }
$DrHealthChecks         = if ($DrHealthReport)      { $DrHealthReport.summary.totalChecks       } else { "N/A" }
$DrHealthPassed         = if ($DrHealthReport)      { $DrHealthReport.summary.passed            } else { "N/A" }
$RequiresHandAuthoredDR = if ($UnsupportedSummary)  { $UnsupportedSummary.requiresHandAuthoredDR } else { 0 }

# Slow drift (R5.6)
$SlowDriftAppeared    = if ($SlowDriftReport)  { $SlowDriftReport.summary.appeared    } else { 0 }
$SlowDriftDisappeared = if ($SlowDriftReport)  { $SlowDriftReport.summary.disappeared } else { 0 }
$SlowDriftChanged     = if ($SlowDriftReport)  { $SlowDriftReport.summary.changed     } else { 0 }
$SlowDriftTotal       = if ($SlowDriftReport)  { $SlowDriftReport.summary.total       } else { 0 }
# SKU availability (R5.7) — `checked` is the sum of the other three; not surfaced separately.
$SkuAvailable   = if ($SkuAvailability) { $SkuAvailability.summary.available   } else { 0 }
$SkuUnavailable = if ($SkuAvailability) { $SkuAvailability.summary.unavailable } else { 0 }
$SkuNotChecked  = if ($SkuAvailability) { $SkuAvailability.summary.notChecked  } else { 0 }
# API-version compatibility (R5.8) — `notChecked` is captured in the suggested-row table only.
$ApiCompatible   = if ($ApiVersionCompat) { $ApiVersionCompat.summary.compatible   } else { 0 }
$ApiIncompatible = if ($ApiVersionCompat) { $ApiVersionCompat.summary.incompatible } else { 0 }
$ApiNotAvailable = if ($ApiVersionCompat) { $ApiVersionCompat.summary.notAvailable } else { 0 }

$StatusEmoji = if ($DriftCritical -gt 0) { "🔴" } elseif ($DriftWarnings -gt 0) { "🟡" } else { "🟢" }

$Summary = @"
# $StatusEmoji DRaaC Pipeline Summary

## Scan
| Metric | Value |
|---|---|
| Subscriptions scanned | $(if ($ScanSummary) { $ScanSummary.subscriptionsScanned } else { 'N/A' }) |
| Total resources found | $(if ($ScanSummary) { $ScanSummary.totalResourcesFound  } else { 'N/A' }) |

## Deployment Coverage
| Metric | Value |
|---|---|
| Matched | $(if ($MatchReport) { $MatchReport.summary.matched   } else { 'N/A' }) |
| Unmatched | $(if ($MatchReport) { $MatchReport.summary.unmatched } else { 'N/A' }) |
| Coverage | $Coverage |

## Drift
| Severity | Count |
|---|---|
| 🔴 Critical | $DriftCritical |
| 🟡 Warning  | $DriftWarnings |
| Overall Severity | $DriftSeverity |

## DR Configuration → ``$DrRegion``
| Metric | Value |
|---|---|
| Templates generated | $DrGenerated |
| Validation passed   | $(if ($DrValidation) { $DrValidation.validationSummary.passed } else { 'N/A' }) |
| Validation failed   | $(if ($DrValidation) { $DrValidation.validationSummary.failed } else { 'N/A' }) |
| DR health status    | $DrHealthStatus |
| Health checks passed | $DrHealthPassed / $DrHealthChecks |
| Requires hand-authored DR | $RequiresHandAuthoredDR |
| SKU availability (avail/unavail/notChecked) | $SkuAvailable / $SkuUnavailable / $SkuNotChecked |
| API version compat (ok/bad/regionMissing) | $ApiCompatible / $ApiIncompatible / $ApiNotAvailable |

## Slow Drift (since baseline)
| Bucket | Count |
|---|---|
| 🟢 Appeared    | $SlowDriftAppeared |
| 🔴 Disappeared | $SlowDriftDisappeared |
| 🟡 Changed     | $SlowDriftChanged |
| Total          | $SlowDriftTotal |
"@

# Append per-row sections only when there are findings to surface.
if ($SkuAvailability -and $SkuUnavailable -gt 0) {
    $Summary += "`n## Unavailable SKUs (top 10)`n| Resource | Type | SKU | Reason | Suggested |`n|---|---|---|---|---|`n"
    $rows = @($SkuAvailability.results | Where-Object { $_.status -eq 'unavailable' } | Select-Object -First 10)
    foreach ($r in $rows) {
        $skuName = if ($r.sku.name) { $r.sku.name } else { $r.sku.tier }
        $sub = if ($r.suggestedSubstitute) { $r.suggestedSubstitute } else { '—' }
        $Summary += "| ``$($r.resource.name)`` | ``$($r.resource.type)`` | $skuName | $($r.reason) | $sub |`n"
    }
}

if ($ApiVersionCompat -and ($ApiIncompatible -gt 0 -or $ApiNotAvailable -gt 0)) {
    $Summary += "`n## Incompatible API versions / region gaps (top 10)`n| Resource Type | API Version | Status | Suggested |`n|---|---|---|---|`n"
    $rows = @($ApiVersionCompat.results | Where-Object { $_.status -in @('incompatible','notAvailable') } | Select-Object -First 10)
    foreach ($r in $rows) {
        $sug = if ($r.suggestedApiVersion) { $r.suggestedApiVersion } else { '—' }
        $Summary += "| ``$($r.resource.type)`` | $($r.apiVersion) | $($r.status) | $sug |`n"
    }
}

Add-Content -Path $SummaryFile -Value $Summary
Write-Host "INFO: Job summary written to $SummaryFile"
