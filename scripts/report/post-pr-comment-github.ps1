#Requires -Version 7.2
# =============================================================================
# post-pr-comment-github.ps1
# Stage 6 (GitHub): Post/update the DRaaC compliance report as a PR comment.
# Uses the GitHub REST API via the gh CLI — no ADO dependency.
# Idempotent: finds existing bot comment by anchor tag and updates it.
# =============================================================================
param(
  [Parameter(Mandatory)][string] $ScanDir,
  [Parameter(Mandatory)][string] $ReviewDir,
  [Parameter(Mandatory)][string] $DriftDir,
  [Parameter(Mandatory)][string] $DrDir,
  [Parameter(Mandatory)][string] $RunId,
  [Parameter(Mandatory)][string] $PrId,
  [Parameter(Mandatory)][string] $RepoOwner,
  [Parameter(Mandatory)][string] $RepoName,
  [Parameter(Mandatory)][string] $RunUrl
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$BOT_TAG   = "<!-- draac-pipeline-bot -->"
$Timestamp = (Get-Date -Format "yyyy-MM-dd HH:mm") + " UTC"
$Repo      = "$RepoOwner/$RepoName"

# ── Load reports ──────────────────────────────────────────────────────────────
function Load-Json($path) {
  if (Test-Path $path) { return Get-Content $path -Raw | ConvertFrom-Json }
  return $null
}

$ScanSummary  = Load-Json (Join-Path $ScanDir   "scan-summary.json")
$MatchReport  = Load-Json (Join-Path $ReviewDir "deployment-match-report.json")
$DriftReport  = Load-Json (Join-Path $DriftDir  "drift-report.json")
$DrSummary    = Load-Json (Join-Path $DrDir     "dr-summary.json")
$DrValidation = Load-Json (Join-Path $DrDir     "dr-validation-report.json")

# ── Derive status indicators ──────────────────────────────────────────────────
$DriftCritical = if ($DriftReport) { $DriftReport.summary.critical  } else { 0 }
$DriftWarnings = if ($DriftReport) { $DriftReport.summary.warnings  } else { 0 }
$TotalDrift    = if ($DriftReport) { $DriftReport.summary.totalDriftItems } else { 0 }
$Matched       = if ($MatchReport) { $MatchReport.summary.matched   } else { 0 }
$Unmatched     = if ($MatchReport) { $MatchReport.summary.unmatched } else { 0 }
$Coverage      = if ($MatchReport) { $MatchReport.summary.deploymentCoverage } else { "N/A" }
$DrGenerated   = if ($DrSummary)   { $DrSummary.processed  } else { 0 }
$DrPass        = if ($DrValidation){ $DrValidation.validationSummary.passed } else { 0 }
$DrFail        = if ($DrValidation){ $DrValidation.validationSummary.failed } else { 0 }
$DrRegion      = if ($DrSummary)   { $DrSummary.drRegion    } else { "N/A" }
$SubsScanned   = if ($ScanSummary) { $ScanSummary.subscriptionsScanned } else { "?" }
$TotalRes      = if ($ScanSummary) { $ScanSummary.totalResourcesFound  } else { "?" }

$OverallStatus = if ($DriftCritical -gt 0 -or $Unmatched -gt 0) { "🔴 Action Required" }
                 elseif ($DriftWarnings -gt 0)                   { "🟡 Review Recommended" }
                 else                                             { "🟢 Compliant" }

# ── Build markdown comment body ───────────────────────────────────────────────
$CriticalRows = if ($DriftReport -and $DriftCritical -gt 0) {
  ($DriftReport.driftItems | Where-Object { $_.severity -eq "critical" } | Select-Object -First 5) | ForEach-Object {
    $name = if ($_.resourceName) { $_.resourceName } else { $_.file }
    "| ``$name`` | $($_.driftType) |"
  }
} else { @("| — | No critical drift found |") }

$Comment = @"
$BOT_TAG

## 🔥 DRaaC Pipeline Report

**Status:** $OverallStatus
**PR:** #$PrId · **Run:** ``$RunId`` · **Analysed:** $Timestamp
**Pipeline:** [View run]($RunUrl)

---

### 1️⃣ Subscription Scan
| Subscriptions Scanned | $SubsScanned |
|---|---|
| Total Resources Found | $TotalRes |

---

### 2️⃣ Deployment Coverage (Code → Azure)
| IaC Files Matched to Azure | $Matched |
|---|---|
| IaC Files NOT Found in Azure | $Unmatched |
| Coverage | **$Coverage** |

$(if ($Unmatched -gt 0) { "> ⚠️ **$Unmatched IaC file(s)** define resources not found in any Azure subscription. Deploy before merging." })

---

### 3️⃣ Configuration Drift
| 🔴 Critical | $DriftCritical |
|---|---|
| 🟡 Warnings | $DriftWarnings |
| Total | $TotalDrift |

$(if ($DriftCritical -gt 0) { @"
**Top Critical Items:**

| Resource / File | Drift Type |
|---|---|
$($CriticalRows -join "`n")

> 📄 Full report: see ``CONFIGURATION-DRIFT.md`` committed to this PR branch.
"@ })

---

### 4️⃣ DR Configuration (→ ``$DrRegion``)
| DR Templates Generated | $DrGenerated |
|---|---|
| Validation Passed | $DrPass |
| Validation Failed | $DrFail |

$(if ($DrFail -gt 0) { "> ⚠️ $DrFail DR template(s) failed what-if validation. Review the ``dr-config`` artifact." })

---

### 📋 Required Actions
$(if ($DriftCritical -gt 0 -or $Unmatched -gt 0) {
  "- 🚨 **Resolve $DriftCritical critical drift item(s) before merging**`n- Deploy all IaC changes to Azure"
})
$(if ($DriftWarnings -gt 0) { "- 👀 Review warning-level items in ``CONFIGURATION-DRIFT.md``" })
$(if ($TotalDrift -eq 0 -and $Unmatched -eq 0) { "- ✅ All checks passed — safe to merge" })

---
*Auto-generated by the DRaaC Pipeline · Updates in place on re-runs*
"@

# ── Find existing bot comment via GitHub REST API ─────────────────────────────
Write-Host "INFO: Looking for existing bot comment on PR #$PrId..."

$ExistingCommentId = $null
try {
  $Comments = gh api "repos/$Repo/issues/$PrId/comments" --paginate 2>/dev/null | ConvertFrom-Json
  $BotComment = $Comments | Where-Object { $_.body -like "*$BOT_TAG*" } | Select-Object -First 1
  if ($BotComment) {
    $ExistingCommentId = $BotComment.id
    Write-Host "INFO: Found existing bot comment ID: $ExistingCommentId"
  }
} catch {
  Write-Warning "Could not list PR comments (non-fatal): $_"
}

# ── Post or update the comment ────────────────────────────────────────────────
$CommentPayload = @{ body = $Comment } | ConvertTo-Json -Compress

try {
  if ($ExistingCommentId) {
    # Update existing comment (idempotent)
    $CommentPayload | gh api "repos/$Repo/issues/comments/$ExistingCommentId" \
      --method PATCH --input - | Out-Null
    Write-Host "SUCCESS: Updated existing PR comment (ID: $ExistingCommentId)"
  } else {
    # Create new comment
    $CommentPayload | gh api "repos/$Repo/issues/$PrId/comments" \
      --method POST --input - | Out-Null
    Write-Host "SUCCESS: Created new PR comment on PR #$PrId"
  }
} catch {
  Write-Warning "Could not post PR comment (non-fatal): $_"
  Write-Host "--- COMMENT CONTENT ---"
  Write-Host $Comment
  Write-Host "-----------------------"
}

# ── Set GitHub Actions outputs for downstream use ─────────────────────────────
"DRIFT_CRITICAL=$DriftCritical"    | Out-File -FilePath $env:GITHUB_OUTPUT -Append
"DRIFT_WARNINGS=$DriftWarnings"    | Out-File -FilePath $env:GITHUB_OUTPUT -Append
"DEPLOYMENT_COVERAGE=$Coverage"    | Out-File -FilePath $env:GITHUB_OUTPUT -Append
"DR_TEMPLATES_GENERATED=$DrGenerated" | Out-File -FilePath $env:GITHUB_OUTPUT -Append

# ── Emit workflow annotations ─────────────────────────────────────────────────
if ($DriftCritical -gt 0) {
  Write-Host "::warning title=DRaaC Critical Drift::$DriftCritical critical drift item(s) detected. Review CONFIGURATION-DRIFT.md before merging."
}
if ($Unmatched -gt 0) {
  Write-Host "::warning title=DRaaC Deployment Gap::$Unmatched IaC file(s) define resources not found in Azure."
}
if ($TotalDrift -eq 0 -and $Unmatched -eq 0) {
  Write-Host "::notice title=DRaaC::All checks passed. DR coverage is complete."
}
