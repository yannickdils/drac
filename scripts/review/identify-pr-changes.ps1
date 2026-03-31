#Requires -Version 7.2
# =============================================================================
# identify-pr-changes.ps1
# Stage 3a: Identify files changed in the PR and categorise by IaC type.
# Idempotent: same git diff = same output.
# =============================================================================
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $BaseCommit,
    [Parameter(Mandatory)] [string] $HeadCommit,
    [Parameter(Mandatory)] [string] $OutputDir
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

$null = New-Item -ItemType Directory -Force -Path $OutputDir

Write-Host "============================================================"
Write-Host "STAGE 3a: Identify PR Changes"
Write-Host "  Base: $BaseCommit   Head: $HeadCommit"
Write-Host "============================================================"

$BaseRef = "origin/$($BaseCommit -replace '^refs/heads/','')"

git fetch --all --quiet 2>$null

# Get changed files
$DiffOutput = git diff --name-status "$BaseRef...$HeadCommit" 2>$null
if (-not $DiffOutput) {
    Write-Warning "Could not compute diff — treating all IaC files as changed"
    $DiffOutput = Get-ChildItem -Recurse -Include "*.bicep","*.json","*.ps1","*.yaml","*.yml" |
        Where-Object { $_.FullName -notmatch "\.git" } |
        ForEach-Object { "M`t$($_.Name)" }
}

# ── Categorise a file path ────────────────────────────────────────────────────
function Get-IaCCategory([string]$Path) {
    $l = $Path.ToLower()
    if ($l -match '\.bicep$')                              { return "bicep" }
    elseif ($l -match '(arm|template).*\.json$')           { return "arm-template" }
    elseif ($l -match 'pipeline.*(\.yml|\.yaml)$')         { return "pipeline" }
    elseif ($l -match 'manifest.*(\.yml|\.yaml)$')         { return "k8s-manifest" }
    elseif ($l -match 'helm/')                             { return "helm" }
    elseif ($l -match 'dockerfile')                        { return "dockerfile" }
    elseif ($l -match '\.json$')                           { return "config-json" }
    elseif ($l -match '\.(ps1|psm1|psd1)$')               { return "powershell" }
    else                                                   { return "other" }
}

function Get-RgHint([string]$Path) {
    if ($Path -match '(rg[-_][a-z0-9\-]+|resourcegroup[s]?/[^/]+|environments/[^/]+)') {
        return ($Matches[1] -split '/')[-1]
    }
    return ""
}

# Build changes array
$Changes = [System.Collections.Generic.List[hashtable]]::new()

foreach ($Line in ($DiffOutput -split "`n")) {
    $Line = $Line.Trim()
    if (-not $Line) { continue }
    $Parts  = $Line -split "`t", 2
    $Status = $Parts[0].Trim()
    $File   = if ($Parts.Count -gt 1) { $Parts[1].Trim() } else { continue }

    # Skip deleted files for deployment check
    if ($Status -eq "D") { continue }

    $Changes.Add([ordered]@{
        status            = $Status
        path              = $File
        category          = Get-IaCCategory $File
        resourceGroupHint = Get-RgHint $File
    })
}

$Changes | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $OutputDir "pr-changes.json") -Encoding UTF8

$IaCCount = ($Changes | Where-Object { $_.category -ne "other" }).Count
Write-Host "INFO: $($Changes.Count) files changed ($IaCCount IaC-related)"

[ordered]@{
    baseCommit        = $BaseCommit
    headCommit        = $HeadCommit
    totalChanged      = $Changes.Count
    iacRelatedChanged = $IaCCount
    changes           = $Changes
} | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $OutputDir "pr-changes-summary.json") -Encoding UTF8

Write-Host "PR CHANGES IDENTIFIED: $($Changes.Count) files ($IaCCount IaC)"
