#Requires -Version 7.2
<#
.SYNOPSIS
    Posts a DR coverage status comment to the current PR.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $RepoFull,    # owner/repo
    [Parameter(Mandatory)] [string] $PrNumber,
    [Parameter(Mandatory)] [string] $Status       # 'ok' or 'generated' or 'error'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$BotTag = '<!-- draac-demo-bot -->'

$body = switch ($Status) {
    'ok'        { "$BotTag`n## DRaaC Demo Status`n`nDR Bicep is in sync with primary. Safe to merge." }
    'generated' { "$BotTag`n## DRaaC Demo Status`n`nDR Bicep was auto-generated to match primary. Review the diff and merge to deploy." }
    'error'     { "$BotTag`n## DRaaC Demo Status`n`nDR generation failed. See workflow logs." }
    default     { throw "Unknown status: $Status" }
}

# Find existing bot comment
$existing = gh api "repos/$RepoFull/issues/$PrNumber/comments" --paginate |
    ConvertFrom-Json |
    Where-Object { $_.body -like "*$BotTag*" } |
    Select-Object -First 1

$payload = @{ body = $body } | ConvertTo-Json -Compress

if ($existing) {
    $payload | gh api "repos/$RepoFull/issues/comments/$($existing.id)" --method PATCH --input - | Out-Null
    Write-Host "Updated existing PR comment."
} else {
    $payload | gh api "repos/$RepoFull/issues/$PrNumber/comments" --method POST --input - | Out-Null
    Write-Host "Posted new PR comment."
}
