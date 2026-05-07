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
"@

Add-Content -Path $SummaryFile -Value $Summary
Write-Host "INFO: Job summary written to $SummaryFile"
