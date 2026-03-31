#Requires -Version 7.2
# =============================================================================
# post-pr-comment.ps1
# Stage 6: Aggregate all reports and post a structured PR comment to Azure DevOps.
# Uses Azure DevOps REST API v7.1 — latest stable.
# Idempotent: updates existing bot comment if already present.
# =============================================================================
param(
  [Parameter(Mandatory)][string] $ScanDir,
  [Parameter(Mandatory)][string] $ReviewDir,
  [Parameter(Mandatory)][string] $DriftDir,
  [Parameter(Mandatory)][string] $DrDir,
  [Parameter(Mandatory)][string] $RunId,
  [Parameter(Mandatory)][string] $PrId,
  [Parameter(Mandatory)][string] $BuildUrl
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ADO_API_VERSION    = "7.1"
$ORGANIZATION       = $env:ADO_ORGANIZATION.TrimEnd('/')
$PROJECT            = [uri]::EscapeDataString($env:ADO_PROJECT)
$REPO_ID            = $env:ADO_REPO_ID
$PAT                = $env:AZURE_DEVOPS_EXT_PAT
$BASE64_PAT         = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$PAT"))
$AUTH_HEADER        = @{ Authorization = "Basic $BASE64_PAT"; "Content-Type" = "application/json" }
$BOT_TAG            = "<!-- azure-compliance-pipeline-bot -->"
$Timestamp          = (Get-Date -Format "yyyy-MM-dd HH:mm") + " UTC"

# ── Load reports ─────────────────────────────────────────────────────────────
function Load-Json($path) {
  if (Test-Path $path) {
    return Get-Content $path -Raw | ConvertFrom-Json
  }
  return $null
}

$ScanSummary   = Load-Json (Join-Path $ScanDir   "scan-summary.json")
$MatchReport   = Load-Json (Join-Path $ReviewDir "deployment-match-report.json")
$DriftReport   = Load-Json (Join-Path $DriftDir  "drift-report.json")
$DrSummary     = Load-Json (Join-Path $DrDir     "dr-summary.json")
$DrValidation  = Load-Json (Join-Path $DrDir     "dr-validation-report.json")

# ── Derive status indicators ──────────────────────────────────────────────────
$DriftCritical  = if ($DriftReport) { $DriftReport.summary.critical  } else { 0 }
$DriftWarnings  = if ($DriftReport) { $DriftReport.summary.warnings  } else { 0 }
$TotalDrift     = if ($DriftReport) { $DriftReport.summary.totalDriftItems } else { 0 }
$Matched        = if ($MatchReport) { $MatchReport.summary.matched   } else { 0 }
$Unmatched      = if ($MatchReport) { $MatchReport.summary.unmatched } else { 0 }
$Coverage       = if ($MatchReport) { $MatchReport.summary.deploymentCoverage } else { "N/A" }

$DrPass   = if ($DrValidation) { $DrValidation.validationSummary.passed } else { 0 }
$DrFail   = if ($DrValidation) { $DrValidation.validationSummary.failed } else { 0 }

$OverallStatus = if ($DriftCritical -gt 0 -or $Unmatched -gt 0) { "🔴 Action Required" }
                 elseif ($DriftWarnings -gt 0)                   { "🟡 Review Recommended" }
                 else                                              { "🟢 Compliant" }

# ── Build markdown comment ─────────────────────────────────────────────────────
$DrRegion = if ($DrSummary) { $DrSummary.drRegion } else { "N/A" }
$SubsScanned = if ($ScanSummary) { $ScanSummary.subscriptionsScanned } else { "?" }
$TotalResources = if ($ScanSummary) { $ScanSummary.totalResourcesFound } else { "?" }

$Comment = @"
$BOT_TAG

## 🔍 Azure Compliance Pipeline Report

**Status:** $OverallStatus  
**PR:** #$PrId | **Run:** ``$RunId`` | **Analysed:** $Timestamp  
**Build:** [View Pipeline Results]($BuildUrl)

---

### 1️⃣ Subscription Scan
| Metric | Value |
|---|---|
| Subscriptions Scanned | $SubsScanned |
| Total Resources Found | $TotalResources |

---

### 2️⃣ Deployment Coverage (Code → Azure)
| Metric | Value |
|---|---|
| IaC Files with Matched Deployments | $Matched |
| IaC Files with NO Azure Match | $Unmatched |
| Coverage | **$Coverage** |

$(if ($Unmatched -gt 0) { @"
> ⚠️ **$Unmatched IaC file(s) have changes that are NOT deployed to Azure.**  
> Deploy these changes or explain the discrepancy before merging.
"@ })

---

### 3️⃣ Configuration Drift
| Metric | Value |
|---|---|
| 🔴 Critical Items | $DriftCritical |
| 🟡 Warnings | $DriftWarnings |
| Total Drift Items | $TotalDrift |

$(if ($DriftCritical -gt 0) {
  $critItems = $DriftReport.driftItems | Where-Object { $_.severity -eq "critical" } | Select-Object -First 5
  $rows = $critItems | ForEach-Object {
    $name = if ($_.resourceName) { $_.resourceName } else { $_.file }
    "| ``$name`` | $($_.driftType) |"
  }
  @"
**Top Critical Items:**

| Resource / File | Drift Type |
|---|---|
$($rows -join "`n")
$(if ($DriftCritical -gt 5) { "_...and $($DriftCritical - 5) more. See CONFIGURATION-DRIFT.md_" })

> 📄 Full drift report: See ``CONFIGURATION-DRIFT.md`` in this PR's commit.
"@
})

---

### 4️⃣ DR Configuration (→ ``$DrRegion``)
| Metric | Value |
|---|---|
| DR Templates Generated | $(if ($DrSummary) { $DrSummary.processed } else { "N/A" }) |
| Validation Passed | $DrPass |
| Validation Failed | $DrFail |

$(if ($DrFail -gt 0) {
  "> ⚠️ $DrFail DR template(s) failed validation. Review the DR artifacts."
})

---

### 📋 Required Actions

$(if ($DriftCritical -gt 0 -or $Unmatched -gt 0) {
  "- 🚨 **Block merge until critical drift items are resolved**"
  "- Deploy all IaC changes to Azure before merging"
})
$(if ($DriftWarnings -gt 0) {
  "- 👀 Review warning-level drift items in ``CONFIGURATION-DRIFT.md``"
})
$(if ($TotalDrift -eq 0 -and $Unmatched -eq 0) {
  "- ✅ No action required — all resources are deployed and in sync"
})

---

_This comment is auto-generated by the Azure Compliance Pipeline._  
_Re-runs will update this comment in place._
"@

# ── Post/update PR comment via ADO REST API ───────────────────────────────────
$CommentsUri = "${ORGANIZATION}/${PROJECT}/_apis/git/repositories/${REPO_ID}/pullRequests/${PrId}/threads?api-version=${ADO_API_VERSION}"

try {
  # Fetch existing threads to find our bot comment
  $Threads = Invoke-RestMethod -Uri $CommentsUri -Headers $AUTH_HEADER -Method Get
  $ExistingThread = $Threads.value | Where-Object {
    $_.comments | Where-Object { $_.content -like "*$BOT_TAG*" }
  } | Select-Object -First 1

  if ($ExistingThread) {
    # Update first comment in existing thread
    $FirstComment = $ExistingThread.comments | Select-Object -First 1
    $UpdateUri = "${ORGANIZATION}/${PROJECT}/_apis/git/repositories/${REPO_ID}/pullRequests/${PrId}/threads/$($ExistingThread.id)/comments/$($FirstComment.id)?api-version=${ADO_API_VERSION}"
    $Body = @{ content = $Comment } | ConvertTo-Json
    Invoke-RestMethod -Uri $UpdateUri -Headers $AUTH_HEADER -Method Patch -Body $Body | Out-Null
    Write-Host "SUCCESS: Updated existing PR comment (thread $($ExistingThread.id))"
  } else {
    # Create new thread
    $Body = @{
      comments = @(@{ parentCommentId = 0; content = $Comment; commentType = 1 })
      status   = 1
    } | ConvertTo-Json -Depth 5
    Invoke-RestMethod -Uri $CommentsUri -Headers $AUTH_HEADER -Method Post -Body $Body | Out-Null
    Write-Host "SUCCESS: Created new PR comment thread"
  }
} catch {
  Write-Warning "Could not post PR comment (non-fatal): $_"
  # Dump comment to stdout for log visibility
  Write-Host "--- PR COMMENT CONTENT ---"
  Write-Host $Comment
  Write-Host "--------------------------"
}

# ── Set pipeline variables for downstream gates ───────────────────────────────
Write-Host "##vso[task.setvariable variable=DRIFT_CRITICAL;isOutput=true]$DriftCritical"
Write-Host "##vso[task.setvariable variable=DRIFT_WARNINGS;isOutput=true]$DriftWarnings"
Write-Host "##vso[task.setvariable variable=DEPLOYMENT_COVERAGE;isOutput=true]$Coverage"

# Mark pipeline as failed if critical drift exists (optional gate)
if ($DriftCritical -gt 0) {
  Write-Host "##vso[task.logissue type=warning]$DriftCritical critical drift item(s) detected. Review CONFIGURATION-DRIFT.md"
}
