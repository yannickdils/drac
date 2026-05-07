#Requires -Version 7.2
# =============================================================================
# scripts/dr/Test-SkuAvailability.ps1
# Round 5 §R5.7 / E2 — DR SKU availability check.
#
# Walks every per-RG `template.json` produced by Stage-5a (generate-dr-config),
# extracts the (resource type, sku) pairs that have known SKU rules, and
# verifies each SKU is available in the DR region. Mismatches surface in the
# compliance comment with a heuristic "suggested substitute" SKU.
#
# Resource types covered:
#   Microsoft.Compute/virtualMachines              `az vm list-skus`
#   Microsoft.Compute/virtualMachineScaleSets      `az vm list-skus`
#   Microsoft.Web/serverfarms                      `az appservice list-locations --sku <name>`
#   Microsoft.Sql/servers/databases                `az sql db list-editions --location <region>`
#   Microsoft.Sql/servers                          (same as databases — checks tier)
#
# Other types are recorded as `notChecked` with reason `unsupportedTypeForSkuCheck`.
#
# Idempotent: identical inputs (same templates, same fixture) produce identical
# JSON output modulo the `checkedAt` timestamp.
#
# Fault-tolerant: per-resource `az` failures emit `notChecked` rows with the
# error captured under `reason`. The pipeline never aborts mid-run.
#
# Test seam: `-DryRun -FixtureSkusFile <path>` short-circuits all `az` calls
# and uses the fixture for SKU lookups. The fixture shape is documented at the
# top of `Get-FixtureLookup`.
#
# CI hooks: when $env:GITHUB_OUTPUT is set, append:
#   SKU_AVAILABILITY_OK=true|false   (true ⇔ no `unavailable` rows)
#   SKU_AVAILABILITY_SUMMARY=A/U/N   (available/unavailable/notChecked)
#
# Azure CLI references:
#   az vm list-skus:
#     https://learn.microsoft.com/cli/azure/vm#az-vm-list-skus
#   az appservice list-locations:
#     https://learn.microsoft.com/cli/azure/appservice#az-appservice-list-locations
#   az sql db list-editions:
#     https://learn.microsoft.com/cli/azure/sql/db#az-sql-db-list-editions
# =============================================================================
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $DrConfigDir,
    [Parameter(Mandatory)] [string] $DrRegion,
    [Parameter(Mandatory)] [string] $OutputFile,

    [switch] $DryRun,
    [string] $FixtureSkusFile,

    [switch] $FailOnUnavailable
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

function Get-SkuFromResource {
    <#
    .SYNOPSIS
    Returns @{ name; tier } from either resource.sku or resource.properties.sku.
    Both legs may be partially present; missing leg is $null.
    #>
    param($Resource)
    $sku = Get-PropertyValue -Object $Resource -Name 'sku'
    if ($null -eq $sku) {
        $props = Get-PropertyValue -Object $Resource -Name 'properties'
        if ($null -ne $props) {
            $sku = Get-PropertyValue -Object $props -Name 'sku'
        }
    }
    if ($null -eq $sku) { return $null }
    return [ordered]@{
        name = (Get-PropertyValue -Object $sku -Name 'name')
        tier = (Get-PropertyValue -Object $sku -Name 'tier')
    }
}

function Get-CheckFamily {
    <#
    .SYNOPSIS
    Maps an Azure resource type string to the SKU-check family. Returns $null
    when the type is not in scope.
    #>
    param([Parameter(Mandatory)] [string] $Type)
    $t = $Type.ToLowerInvariant()
    switch -Regex ($t) {
        '^microsoft\.compute/virtualmachines$'              { return 'vm' }
        '^microsoft\.compute/virtualmachinescalesets$'      { return 'vm' }
        '^microsoft\.web/serverfarms$'                      { return 'appservice' }
        '^microsoft\.sql/servers/databases$'                { return 'sql' }
        '^microsoft\.sql/servers$'                          { return 'sql' }
        default                                             { return $null }
    }
}

function Get-FixtureLookup {
    <#
    .SYNOPSIS
    Loads the fixture JSON for -DryRun mode. Expected shape:
      {
        "vmSkus":         { "<region>": [ { "name":"...", "available":true }, ... ] },
        "appserviceSkus": { "<sku-name>": ["<region>","..."] },
        "sqlEditions":    { "<region>": [ { "name":"Standard", "available":true }, ... ] }
      }
    Returns a hashtable normalised for fast lookup.
    #>
    param([string] $Path)
    if (-not (Test-Path $Path)) { throw "Fixture file not found: $Path" }
    $raw = Get-Content $Path -Raw | ConvertFrom-Json -Depth 30
    return $raw
}

function Test-VmSkuAvailable {
    param($Lookups, [string] $Region, [string] $SkuName)
    if ($null -eq $Lookups) { return @{ available = $false; reason = 'no fixture' } }
    $regionEntries = Get-PropertyValue -Object $Lookups.vmSkus -Name $Region
    if ($null -eq $regionEntries) { return @{ available = $false; reason = "no vmSkus[$Region] in fixture" } }
    foreach ($e in @($regionEntries)) {
        if ((Get-PropertyValue -Object $e -Name 'name') -eq $SkuName) {
            $av = Get-PropertyValue -Object $e -Name 'available'
            return @{ available = [bool]$av; reason = if ($av) { 'available in fixture' } else { 'not available in fixture' } }
        }
    }
    return @{ available = $false; reason = "SKU '$SkuName' not in vmSkus[$Region] fixture" }
}

function Test-AppserviceSkuAvailable {
    param($Lookups, [string] $Region, [string] $SkuName)
    if ($null -eq $Lookups) { return @{ available = $false; reason = 'no fixture' } }
    $regions = Get-PropertyValue -Object $Lookups.appserviceSkus -Name $SkuName
    if ($null -eq $regions) { return @{ available = $false; reason = "appserviceSkus[$SkuName] missing in fixture" } }
    if (@($regions) -contains $Region) {
        return @{ available = $true; reason = 'sku enabled in region' }
    }
    return @{ available = $false; reason = "sku '$SkuName' not enabled in '$Region'" }
}

function Test-SqlEditionAvailable {
    param($Lookups, [string] $Region, [string] $TierOrName)
    if ($null -eq $Lookups) { return @{ available = $false; reason = 'no fixture' } }
    $regionEntries = Get-PropertyValue -Object $Lookups.sqlEditions -Name $Region
    if ($null -eq $regionEntries) { return @{ available = $false; reason = "sqlEditions[$Region] missing in fixture" } }
    foreach ($e in @($regionEntries)) {
        if ((Get-PropertyValue -Object $e -Name 'name') -eq $TierOrName) {
            $av = Get-PropertyValue -Object $e -Name 'available'
            return @{ available = [bool]$av; reason = if ($av) { 'available in fixture' } else { 'not available in fixture' } }
        }
    }
    return @{ available = $false; reason = "edition '$TierOrName' not in sqlEditions[$Region]" }
}

# Substitute heuristic. Pure-string; deliberately conservative.
function Get-VmSubstituteSku {
    <#
    .SYNOPSIS
    Heuristic: from a Standard_D<n>s_v<v> family, suggest the same family with
    n halved (rounded down to the nearest power of 2 as a fallback). Returns
    $null if the input doesn't match the heuristic's pattern.
    #>
    param([string] $SkuName)
    if ($SkuName -match '^(Standard_)([A-Z]+)([0-9]+)([a-z]*_v[0-9]+)$') {
        $prefix  = $Matches[1]
        $family  = $Matches[2]
        $size    = [int]$Matches[3]
        $suffix  = $Matches[4]
        # Map common D-family sizes downward.
        $candidates = @(64, 32, 16, 8, 4, 2)
        foreach ($c in $candidates) {
            if ($c -lt $size) {
                return "$prefix$family$c$suffix"
            }
        }
    }
    return $null
}

function New-CheckRecord {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Factory function returning an in-memory hashtable; no system state mutation.')]
    [CmdletBinding()]
    param(
        [string] $TemplatePath,
        [string] $ResourceType,
        [string] $ResourceName,
        $Sku,
        [string] $Status,
        [string] $Reason,
        [string] $Suggested
    )
    return [ordered]@{
        resource = [ordered]@{
            type         = $ResourceType
            name         = $ResourceName
            templatePath = $TemplatePath
        }
        sku                 = [ordered]@{
            name = (Get-PropertyValue -Object $Sku -Name 'name')
            tier = (Get-PropertyValue -Object $Sku -Name 'tier')
        }
        status              = $Status
        reason              = $Reason
        suggestedSubstitute = $Suggested
    }
}

# ── Banner ───────────────────────────────────────────────────────────────────

Write-Host "============================================================"
Write-Host "STAGE 7-DR: SKU availability check"
Write-Host "  DR config dir: $DrConfigDir"
Write-Host "  DR region:     $DrRegion"
Write-Host "  Output:        $OutputFile"
Write-Host "  DryRun:        $DryRun"
if ($DryRun) { Write-Host "  Fixture:       $FixtureSkusFile" }
Write-Host "============================================================"

# ── Load fixture (DryRun only) ───────────────────────────────────────────────

$Lookups = $null
if ($DryRun) {
    if (-not $FixtureSkusFile) {
        Write-Error "-DryRun requires -FixtureSkusFile"
        exit 1
    }
    $Lookups = Get-FixtureLookup -Path $FixtureSkusFile
}

# ── Walk DR templates ────────────────────────────────────────────────────────

$results = [System.Collections.Generic.List[object]]::new()

if (-not (Test-Path $DrConfigDir)) {
    Write-Warning "DrConfigDir not found: $DrConfigDir — emitting empty report."
}
else {
    $templates = @(Get-ChildItem -Path $DrConfigDir -Filter 'template.json' -Recurse -File -ErrorAction SilentlyContinue)
    Write-Host "  Found $($templates.Count) template.json file(s) under $DrConfigDir"

    # Memoise az lookups per (family, region) for non-DryRun mode.
    $azCache = @{}

    foreach ($tpl in $templates) {
        try {
            $template = Get-Content $tpl.FullName -Raw | ConvertFrom-Json -Depth 30
        }
        catch {
            Write-Warning "Failed to parse $($tpl.FullName): $_"
            continue
        }
        $resources = Get-PropertyValue -Object $template -Name 'resources'
        if ($null -eq $resources) { continue }

        foreach ($r in @($resources)) {
            $type = Get-PropertyValue -Object $r -Name 'type'
            $name = Get-PropertyValue -Object $r -Name 'name'
            $sku  = Get-SkuFromResource -Resource $r
            if ($null -eq $sku) { continue }

            $family = if ($type) { Get-CheckFamily -Type $type } else { $null }
            if ($null -eq $family) {
                $results.Add((New-CheckRecord -TemplatePath $tpl.FullName -ResourceType $type `
                    -ResourceName $name -Sku $sku -Status 'notChecked' `
                    -Reason 'unsupportedTypeForSkuCheck' -Suggested $null)) | Out-Null
                continue
            }

            $skuName = $sku.name
            if (-not $skuName) {
                # SQL templates often only carry tier. Use tier as fallback.
                $skuName = $sku.tier
            }

            try {
                switch ($family) {
                    'vm' {
                        $check = if ($DryRun) {
                            Test-VmSkuAvailable -Lookups $Lookups -Region $DrRegion -SkuName $skuName
                        } else {
                            $cacheKey = "vm::$DrRegion"
                            if (-not $azCache.ContainsKey($cacheKey)) {
                                $json = & az vm list-skus --location $DrRegion --output json 2>$null
                                if ($LASTEXITCODE -ne 0) { throw "az vm list-skus failed for $DrRegion" }
                                $azCache[$cacheKey] = ($json | ConvertFrom-Json -Depth 20)
                            }
                            $skus = $azCache[$cacheKey]
                            $hit = @($skus | Where-Object { $_.name -eq $skuName -and $_.resourceType -in @('virtualMachines', 'virtualMachineScaleSets') })
                            if ($hit.Count -gt 0) {
                                @{ available = $true; reason = 'sku found in az vm list-skus' }
                            } else {
                                @{ available = $false; reason = "sku '$skuName' not present in az vm list-skus[$DrRegion]" }
                            }
                        }
                    }
                    'appservice' {
                        $check = if ($DryRun) {
                            Test-AppserviceSkuAvailable -Lookups $Lookups -Region $DrRegion -SkuName $skuName
                        } else {
                            $cacheKey = "appservice::$skuName"
                            if (-not $azCache.ContainsKey($cacheKey)) {
                                $json = & az appservice list-locations --sku $skuName --output json 2>$null
                                if ($LASTEXITCODE -ne 0) { throw "az appservice list-locations failed for $skuName" }
                                $azCache[$cacheKey] = ($json | ConvertFrom-Json -Depth 10)
                            }
                            $locs = @($azCache[$cacheKey] | ForEach-Object { $_.name })
                            if ($locs -contains $DrRegion -or $locs -contains ($DrRegion -replace ' ', '')) {
                                @{ available = $true; reason = 'sku enabled in region' }
                            } else {
                                @{ available = $false; reason = "sku '$skuName' not enabled in '$DrRegion'" }
                            }
                        }
                    }
                    'sql' {
                        $check = if ($DryRun) {
                            Test-SqlEditionAvailable -Lookups $Lookups -Region $DrRegion -TierOrName ($sku.tier ? $sku.tier : $skuName)
                        } else {
                            $cacheKey = "sql::$DrRegion"
                            if (-not $azCache.ContainsKey($cacheKey)) {
                                $json = & az sql db list-editions --location $DrRegion --available --output json 2>$null
                                if ($LASTEXITCODE -ne 0) { throw "az sql db list-editions failed for $DrRegion" }
                                $azCache[$cacheKey] = ($json | ConvertFrom-Json -Depth 20)
                            }
                            $needle = if ($sku.tier) { $sku.tier } else { $skuName }
                            $editions = @($azCache[$cacheKey] | Where-Object { $_.name -eq $needle })
                            if ($editions.Count -gt 0) {
                                @{ available = $true; reason = 'edition found in az sql db list-editions' }
                            } else {
                                @{ available = $false; reason = "edition '$needle' not in az sql db list-editions[$DrRegion]" }
                            }
                        }
                    }
                }
            }
            catch {
                $results.Add((New-CheckRecord -TemplatePath $tpl.FullName -ResourceType $type `
                    -ResourceName $name -Sku $sku -Status 'notChecked' `
                    -Reason "az error: $_" -Suggested $null)) | Out-Null
                continue
            }

            $status = if ($check.available) { 'available' } else { 'unavailable' }
            $suggested = $null
            if (-not $check.available -and $family -eq 'vm') {
                $suggested = Get-VmSubstituteSku -SkuName $skuName
            }

            $results.Add((New-CheckRecord -TemplatePath $tpl.FullName -ResourceType $type `
                -ResourceName $name -Sku $sku -Status $status `
                -Reason $check.reason -Suggested $suggested)) | Out-Null
        }
    }
}

# ── Summary + write ──────────────────────────────────────────────────────────

$checked      = $results.Count
$available    = @($results | Where-Object { $_.status -eq 'available' }).Count
$unavailable  = @($results | Where-Object { $_.status -eq 'unavailable' }).Count
$notChecked   = @($results | Where-Object { $_.status -eq 'notChecked' }).Count

$report = [ordered]@{
    drRegion  = $DrRegion
    checkedAt = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    summary   = [ordered]@{
        checked     = $checked
        available   = $available
        unavailable = $unavailable
        notChecked  = $notChecked
    }
    results = @($results)
}

$outDir = Split-Path $OutputFile -Parent
if ($outDir -and -not (Test-Path $outDir)) {
    $null = New-Item -ItemType Directory -Force -Path $outDir
}
$report | ConvertTo-Json -Depth 30 | Set-Content -Path $OutputFile -Encoding UTF8

Write-Host ""
Write-Host "SKU AVAILABILITY COMPLETE  Checked: $checked  Available: $available  Unavailable: $unavailable  NotChecked: $notChecked"
Write-Host "  Report: $OutputFile"

$ok = ($unavailable -eq 0)
if ($env:GITHUB_OUTPUT) {
    $okStr = if ($ok) { 'true' } else { 'false' }
    Add-Content -Path $env:GITHUB_OUTPUT -Value ("SKU_AVAILABILITY_OK={0}" -f $okStr)
    Add-Content -Path $env:GITHUB_OUTPUT -Value ("SKU_AVAILABILITY_SUMMARY={0}/{1}/{2}" -f $available, $unavailable, $notChecked)
}

if ($FailOnUnavailable -and $unavailable -gt 0) { exit 1 }
exit 0
