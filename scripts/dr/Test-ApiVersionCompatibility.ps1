#Requires -Version 7.2
# =============================================================================
# scripts/dr/Test-ApiVersionCompatibility.ps1
# Round 5 §R5.8 / E3 — DR API-version compatibility check.
#
# Walks every per-RG `template.json` under -DrConfigDir, extracts every
# (resource type, apiVersion) pair (including nested child resources), and
# verifies the apiVersion is supported by the provider in the DR region.
#
# Three failure modes:
#   incompatible    apiVersion is NOT in the provider's supported list.
#   notAvailable    apiVersion is supported, but $DrRegion is not in the
#                   resource type's `locations` list.
#   notChecked      provider/type couldn't be resolved (e.g. 3rd-party RP,
#                   az error). Always emitted with a `reason`.
#
# Substitute heuristic for `incompatible`: pick the latest GA apiVersion
# (no `-preview`/`-rc`/`-beta`) from the supported list. If no GA exists,
# fall back to the latest preview.
#
# Idempotent: identical inputs produce identical JSON output modulo
# `checkedAt` timestamp.
#
# Fault-tolerant: per-namespace `az` failure marks all resources in that
# namespace as `notChecked` and continues. The pipeline never aborts.
#
# Test seam: `-DryRun -FixtureProvidersFile <path>` short-circuits all `az`
# calls and uses the fixture for provider lookups. Fixture shape:
#   { "<namespace>": {
#       "resourceTypes": [
#         { "resourceType": "<rt>", "apiVersions": [...], "locations": [...] }
#       ] } }
#
# CI hooks: when $env:GITHUB_OUTPUT is set, append:
#   API_VERSION_COMPAT_OK=true|false   (true ⇔ no `incompatible` rows AND no `notAvailable`)
#   API_VERSION_COMPAT_SUMMARY=C/I/N   (compatible / incompatible / notAvailable)
#
# Azure CLI references:
#   az provider show:
#     https://learn.microsoft.com/cli/azure/provider#az-provider-show
# =============================================================================
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $DrConfigDir,
    [Parameter(Mandatory)] [string] $DrRegion,
    [Parameter(Mandatory)] [string] $OutputFile,

    [switch] $DryRun,
    [string] $FixtureProvidersFile,

    [switch] $FailOnIncompatible
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

# ── Helpers ──────────────────────────────────────────────────────────────────

function Test-HasProperty {
    param($Object, [Parameter(Mandatory)] [string] $Name)
    if ($null -eq $Object) { return $false }
    if ($Object -isnot [System.Management.Automation.PSObject] -and `
        $Object -isnot [System.Management.Automation.PSCustomObject]) { return $false }
    return ($null -ne $Object.PSObject.Properties[$Name])
}

function Get-PropertyValue {
    param($Object, [Parameter(Mandatory)] [string] $Name)
    if (-not (Test-HasProperty -Object $Object -Name $Name)) { return $null }
    $val = $Object.PSObject.Properties[$Name].Value
    if ($val -is [System.Collections.IEnumerable] -and $val -isnot [string]) {
        return , $val
    }
    return $val
}

function Get-NamespaceFromType {
    <#
    .SYNOPSIS
    Returns the namespace portion of an Azure resource type. Microsoft.Sql/servers
    → 'Microsoft.Sql'. Returns $null for malformed input.
    #>
    param([Parameter(Mandatory)] [string] $Type)
    $idx = $Type.IndexOf('/')
    if ($idx -lt 1) { return $null }
    return $Type.Substring(0, $idx)
}

function Get-RelativeTypeFromType {
    <#
    .SYNOPSIS
    Microsoft.Sql/servers/databases → 'servers/databases'.
    #>
    param([Parameter(Mandatory)] [string] $Type)
    $idx = $Type.IndexOf('/')
    if ($idx -lt 1) { return $Type }
    return $Type.Substring($idx + 1)
}

function Get-RegionsCanonical {
    <#
    .SYNOPSIS
    Normalise a list of region display-names to a hash-set for membership
    checks. Treats both 'North Europe' and 'northeurope' as equivalent.
    #>
    param([object[]] $Regions)
    $set = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($r in @($Regions)) {
        if ([string]::IsNullOrWhiteSpace($r)) { continue }
        $null = $set.Add($r)
        $null = $set.Add(($r -replace '\s+',''))
    }
    # `return $set` would enumerate the HashSet to Object[]. Wrap in a single-
    # element array to preserve the HashSet through the pipeline.
    return , $set
}

function Test-IsGaApiVersion {
    <#
    .SYNOPSIS
    Returns $true when the apiVersion has no preview/beta/rc suffix.
    #>
    param([string] $ApiVersion)
    if ([string]::IsNullOrWhiteSpace($ApiVersion)) { return $false }
    return ($ApiVersion -notmatch '(?i)(preview|beta|rc|alpha|deprecated)')
}

function Get-SuggestedApiVersion {
    <#
    .SYNOPSIS
    From a list of supported versions, return the latest GA. Falls back to
    latest preview if no GA exists.
    #>
    param([object[]] $Versions)
    $arr = @($Versions | Where-Object { $_ })
    if ($arr.Count -eq 0) { return $null }
    $sorted = $arr | Sort-Object -Descending
    foreach ($v in $sorted) {
        if (Test-IsGaApiVersion -ApiVersion $v) { return $v }
    }
    return $sorted[0]
}

# ── Resource walker ──────────────────────────────────────────────────────────

function Get-AllResourceEntry {
    <#
    .SYNOPSIS
    Walks an ARM template and emits one entry per (type, apiVersion, name)
    triple, including nested child resources. Type is the FULLY-QUALIFIED
    type (e.g. 'Microsoft.Sql/servers/databases') even when nested.
    #>
    param([Parameter(Mandatory)] $Template, [Parameter(Mandatory)] [string] $TemplatePath)

    $entries = [System.Collections.Generic.List[object]]::new()

    $resources = Get-PropertyValue -Object $Template -Name 'resources'
    if ($null -eq $resources) { return , $entries }

    foreach ($r in @($resources)) {
        Add-ResourceAndChild -Resource $r -ParentType '' -TemplatePath $TemplatePath -Out $entries
    }
    return , $entries
}

function Add-ResourceAndChild {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Pure traversal helper that appends to a passed-in list.')]
    [CmdletBinding()]
    param(
        $Resource,
        [string] $ParentType,
        [string] $TemplatePath,
        [System.Collections.Generic.List[object]] $Out
    )
    $type = Get-PropertyValue -Object $Resource -Name 'type'
    if (-not $type) { return }

    $fullType = if ($ParentType) { "$ParentType/$type" } else { $type }
    $apiVersion = Get-PropertyValue -Object $Resource -Name 'apiVersion'
    $name = Get-PropertyValue -Object $Resource -Name 'name'

    $Out.Add([ordered]@{
        type         = $fullType
        apiVersion   = $apiVersion
        name         = $name
        templatePath = $TemplatePath
    }) | Out-Null

    $children = Get-PropertyValue -Object $Resource -Name 'resources'
    if ($null -ne $children) {
        foreach ($c in @($children)) {
            Add-ResourceAndChild -Resource $c -ParentType $fullType -TemplatePath $TemplatePath -Out $Out
        }
    }
}

# ── Provider lookup ──────────────────────────────────────────────────────────

function Get-FixtureProvider {
    param([string] $Path)
    if (-not (Test-Path $Path)) { throw "Fixture file not found: $Path" }
    return (Get-Content $Path -Raw | ConvertFrom-Json -Depth 30)
}

function Get-ProviderInfo {
    <#
    .SYNOPSIS
    Returns a normalised provider record:
      @{ namespace = ...
         types     = @{ '<relativeType>' = @{ apiVersions = [...]; locations = [...] } } }
    Returns $null if lookup fails.
    Cached per-namespace via the parent-scoped $azCache hashtable.
    #>
    param(
        [string] $Namespace,
        [hashtable] $Cache,
        [bool] $UseFixture,
        $FixtureProviders
    )
    if ($Cache.ContainsKey($Namespace)) { return $Cache[$Namespace] }

    if ($UseFixture) {
        if (-not (Test-HasProperty -Object $FixtureProviders -Name $Namespace)) {
            $Cache[$Namespace] = $null
            return $null
        }
        $entry = $FixtureProviders.PSObject.Properties[$Namespace].Value
        $rts = Get-PropertyValue -Object $entry -Name 'resourceTypes'
        $types = @{}
        foreach ($rt in @($rts)) {
            $relType = Get-PropertyValue -Object $rt -Name 'resourceType'
            if (-not $relType) { continue }
            # Assign-then-wrap (NOT inline @(Get-PropertyValue ...)) — inline @()
            # keeps the leading-comma wrapper, producing a nested 1xN array.
            $av = Get-PropertyValue -Object $rt -Name 'apiVersions'
            $lc = Get-PropertyValue -Object $rt -Name 'locations'
            $types[$relType.ToLowerInvariant()] = @{
                apiVersions = if ($null -eq $av) { @() } else { @($av) }
                locations   = if ($null -eq $lc) { @() } else { @($lc) }
            }
        }
        $rec = @{ namespace = $Namespace; types = $types }
        $Cache[$Namespace] = $rec
        return $rec
    }

    try {
        $json = & az provider show --namespace $Namespace --output json 2>$null
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace(($json | Out-String))) {
            $Cache[$Namespace] = $null
            return $null
        }
        $obj = $json | ConvertFrom-Json -Depth 30
        $rts = Get-PropertyValue -Object $obj -Name 'resourceTypes'
        $types = @{}
        foreach ($rt in @($rts)) {
            $relType = Get-PropertyValue -Object $rt -Name 'resourceType'
            if (-not $relType) { continue }
            $av = Get-PropertyValue -Object $rt -Name 'apiVersions'
            $lc = Get-PropertyValue -Object $rt -Name 'locations'
            $types[$relType.ToLowerInvariant()] = @{
                apiVersions = if ($null -eq $av) { @() } else { @($av) }
                locations   = if ($null -eq $lc) { @() } else { @($lc) }
            }
        }
        $rec = @{ namespace = $Namespace; types = $types }
        $Cache[$Namespace] = $rec
        return $rec
    }
    catch {
        Write-Warning "az provider show --namespace $Namespace failed: $_"
        $Cache[$Namespace] = $null
        return $null
    }
}

function New-CompatRecord {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Factory function returning an in-memory hashtable; no system state mutation.')]
    [CmdletBinding()]
    param(
        [string] $TemplatePath,
        [string] $Type,
        [string] $ApiVersion,
        [string] $Status,
        [object[]] $SupportedVersions,
        [string] $Suggested,
        [string] $Reason
    )
    return [ordered]@{
        resource          = [ordered]@{ type = $Type; templatePath = $TemplatePath }
        apiVersion        = $ApiVersion
        status            = $Status
        supportedVersions = @($SupportedVersions)
        suggestedApiVersion = $Suggested
        reason            = $Reason
    }
}

# ── Banner ───────────────────────────────────────────────────────────────────

Write-Host "============================================================"
Write-Host "STAGE 7-DR: API-version compatibility check"
Write-Host "  DR config dir: $DrConfigDir"
Write-Host "  DR region:     $DrRegion"
Write-Host "  Output:        $OutputFile"
Write-Host "  DryRun:        $DryRun"
if ($DryRun) { Write-Host "  Fixture:       $FixtureProvidersFile" }
Write-Host "============================================================"

$FixtureProviders = $null
if ($DryRun) {
    if (-not $FixtureProvidersFile) {
        Write-Error "-DryRun requires -FixtureProvidersFile"
        exit 1
    }
    $FixtureProviders = Get-FixtureProvider -Path $FixtureProvidersFile
}

$results = [System.Collections.Generic.List[object]]::new()
$azCache = @{}

if (-not (Test-Path $DrConfigDir)) {
    Write-Warning "DrConfigDir not found: $DrConfigDir — emitting empty report."
}
else {
    $templates = @(Get-ChildItem -Path $DrConfigDir -Filter 'template.json' -Recurse -File -ErrorAction SilentlyContinue)
    Write-Host "  Found $($templates.Count) template.json file(s) under $DrConfigDir"

    foreach ($tpl in $templates) {
        try {
            $template = Get-Content $tpl.FullName -Raw | ConvertFrom-Json -Depth 30
        }
        catch {
            Write-Warning "Failed to parse $($tpl.FullName): $_"
            continue
        }

        $entries = Get-AllResourceEntry -Template $template -TemplatePath $tpl.FullName
        foreach ($e in @($entries)) {
            $type = $e.type
            $apiVersion = $e.apiVersion
            if (-not $type -or -not $apiVersion) { continue }

            $namespace = Get-NamespaceFromType -Type $type
            $relType   = Get-RelativeTypeFromType -Type $type
            if (-not $namespace) {
                $results.Add((New-CompatRecord -TemplatePath $tpl.FullName -Type $type -ApiVersion $apiVersion `
                    -Status 'notChecked' -SupportedVersions @() -Suggested $null `
                    -Reason 'malformedType')) | Out-Null
                continue
            }

            $provider = Get-ProviderInfo -Namespace $namespace -Cache $azCache -UseFixture $DryRun.IsPresent -FixtureProviders $FixtureProviders
            if ($null -eq $provider) {
                $results.Add((New-CompatRecord -TemplatePath $tpl.FullName -Type $type -ApiVersion $apiVersion `
                    -Status 'notChecked' -SupportedVersions @() -Suggested $null `
                    -Reason "providerLookupFailed:$namespace")) | Out-Null
                continue
            }

            $key = $relType.ToLowerInvariant()
            if (-not $provider.types.ContainsKey($key)) {
                $results.Add((New-CompatRecord -TemplatePath $tpl.FullName -Type $type -ApiVersion $apiVersion `
                    -Status 'notChecked' -SupportedVersions @() -Suggested $null `
                    -Reason 'typeNotFoundInProvider')) | Out-Null
                continue
            }
            $supported = @($provider.types[$key].apiVersions)
            $locations = @($provider.types[$key].locations)

            # locations gate
            $locationsSet = Get-RegionsCanonical -Regions $locations
            $regionOk = ($locationsSet.Count -eq 0) -or `
                        $locationsSet.Contains($DrRegion) -or `
                        $locationsSet.Contains(($DrRegion -replace '\s+',''))

            if (-not $regionOk) {
                $results.Add((New-CompatRecord -TemplatePath $tpl.FullName -Type $type -ApiVersion $apiVersion `
                    -Status 'notAvailable' -SupportedVersions $supported -Suggested $null `
                    -Reason "type not available in region '$DrRegion'")) | Out-Null
                continue
            }

            if ($supported -contains $apiVersion) {
                $results.Add((New-CompatRecord -TemplatePath $tpl.FullName -Type $type -ApiVersion $apiVersion `
                    -Status 'compatible' -SupportedVersions $supported -Suggested $null `
                    -Reason 'supported')) | Out-Null
            }
            else {
                $suggested = Get-SuggestedApiVersion -Versions $supported
                $results.Add((New-CompatRecord -TemplatePath $tpl.FullName -Type $type -ApiVersion $apiVersion `
                    -Status 'incompatible' -SupportedVersions $supported -Suggested $suggested `
                    -Reason "apiVersion '$apiVersion' not in supported list")) | Out-Null
            }
        }
    }
}

# ── Summary + write ──────────────────────────────────────────────────────────

$checked      = $results.Count
$compatible   = @($results | Where-Object { $_.status -eq 'compatible' }).Count
$incompatible = @($results | Where-Object { $_.status -eq 'incompatible' }).Count
$notAvailable = @($results | Where-Object { $_.status -eq 'notAvailable' }).Count
$notChecked   = @($results | Where-Object { $_.status -eq 'notChecked' }).Count

$report = [ordered]@{
    drRegion  = $DrRegion
    checkedAt = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    summary   = [ordered]@{
        checked      = $checked
        compatible   = $compatible
        incompatible = $incompatible
        notAvailable = $notAvailable
        notChecked   = $notChecked
    }
    results = @($results)
}

$outDir = Split-Path $OutputFile -Parent
if ($outDir -and -not (Test-Path $outDir)) {
    $null = New-Item -ItemType Directory -Force -Path $outDir
}
$report | ConvertTo-Json -Depth 30 | Set-Content -Path $OutputFile -Encoding UTF8

Write-Host ""
Write-Host "API VERSION COMPAT COMPLETE  Checked: $checked  Compatible: $compatible  Incompatible: $incompatible  NotAvailable: $notAvailable  NotChecked: $notChecked"
Write-Host "  Report: $OutputFile"

$ok = ($incompatible -eq 0 -and $notAvailable -eq 0)
if ($env:GITHUB_OUTPUT) {
    $okStr = if ($ok) { 'true' } else { 'false' }
    Add-Content -Path $env:GITHUB_OUTPUT -Value ("API_VERSION_COMPAT_OK={0}" -f $okStr)
    Add-Content -Path $env:GITHUB_OUTPUT -Value ("API_VERSION_COMPAT_SUMMARY={0}/{1}/{2}" -f $compatible, $incompatible, $notAvailable)
}

if ($FailOnIncompatible -and ($incompatible -gt 0 -or $notAvailable -gt 0)) { exit 1 }
exit 0
