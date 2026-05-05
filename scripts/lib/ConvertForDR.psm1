#Requires -Version 7.2
# =============================================================================
# scripts/lib/ConvertForDR.psm1
#
# Pure (no Azure / no I/O) ARM template transformation module that turns an
# exported primary-region ARM template into a DR-region equivalent.
#
# Implements the four Round 1 correctness fixes from IMPLEMENTATION-BRIEF.md:
#   B1 — Reserved-name allowlist + type-aware prefixing
#   B2 — Two-pass cross-resource reference rewriting
#   B3 — Context-aware address-space rewriting (VNet only, first prefix)
#   B4 — Read-only property sanitisation (global + per-type)
#
# Idempotent — re-running on already-transformed input is a no-op.
# Fault-tolerant — never throws on a single bad node; surfaces deferrals via
# the returned Flags object instead of via exceptions.
# =============================================================================

$script:DefaultDataDir = (Resolve-Path (Join-Path $PSScriptRoot ".." ".." "data") -ErrorAction SilentlyContinue)?.Path

# ── Helpers (not exported) ────────────────────────────────────────────────────

function Test-HasProperty {
    # Strict-mode-safe property existence check. The PSObject.Properties[name]
    # indexer returns $null when the property is missing AND when the property
    # collection is empty, so it works in both cases without requiring `.Count`
    # or `.Name` projection (both of which throw under Set-StrictMode -Version Latest
    # when the collection is empty).
    param($Object, [Parameter(Mandatory)] [string] $Name)
    if ($null -eq $Object) { return $false }
    if ($Object -isnot [System.Management.Automation.PSObject] -and `
        $Object -isnot [System.Management.Automation.PSCustomObject]) { return $false }
    return ($null -ne $Object.PSObject.Properties[$Name])
}

function Test-IsResourceObject {
    param($Node)
    if ($Node -isnot [System.Management.Automation.PSCustomObject]) { return $false }
    if (-not (Test-HasProperty $Node 'type')) { return $false }
    if (-not (Test-HasProperty $Node 'name')) { return $false }
    $t = $Node.type
    if ($t -isnot [string]) { return $false }
    return ($t.StartsWith('Microsoft.') -and $t.Contains('/'))
}

function Get-ResourceTypeDepth {
    param([Parameter(Mandatory)] [string] $Type)
    return ($Type.Split('/').Count - 1)
}

function ConvertTo-DeepClone {
    param([Parameter(Mandatory)] $Node)
    return ($Node | ConvertTo-Json -Depth 50 -Compress | ConvertFrom-Json)
}

function Read-DefaultReservedNames {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseSingularNouns', '',
        Justification = 'Returns a list of names; plural is intentional for the helper.')]
    [CmdletBinding()]
    param()
    if ($script:DefaultDataDir -and (Test-Path (Join-Path $script:DefaultDataDir 'reserved-names.json'))) {
        $obj = Get-Content (Join-Path $script:DefaultDataDir 'reserved-names.json') -Raw | ConvertFrom-Json
        $names = @()
        if (Test-HasProperty $obj 'subnetNames')        { $names += @($obj.subnetNames) }
        if (Test-HasProperty $obj 'fixedResourceNames') { $names += @($obj.fixedResourceNames) }
        return $names
    }
    return @()
}

function Read-DefaultReadOnlySchema {
    if ($script:DefaultDataDir -and (Test-Path (Join-Path $script:DefaultDataDir 'readonly-properties.json'))) {
        return (Get-Content (Join-Path $script:DefaultDataDir 'readonly-properties.json') -Raw | ConvertFrom-Json)
    }
    return [PSCustomObject]@{ global = @(); perType = [PSCustomObject]@{} }
}

function Invoke-WalkObject {
    # Generic recursive walker. Calls $Visit for every PSCustomObject node and
    # passes through arrays. $Visit may mutate the node in place.
    param(
        [Parameter(Mandatory)] $Node,
        [Parameter(Mandatory)] [scriptblock] $Visit,
        [hashtable] $Context = @{}
    )
    if ($Node -is [System.Management.Automation.PSCustomObject]) {
        & $Visit $Node $Context
        foreach ($prop in @($Node.PSObject.Properties)) {
            Invoke-WalkObject -Node $prop.Value -Visit $Visit -Context $Context
        }
    }
    elseif ($Node -is [System.Collections.IEnumerable] -and $Node -isnot [string]) {
        foreach ($item in $Node) {
            Invoke-WalkObject -Node $item -Visit $Visit -Context $Context
        }
    }
}

# ── B1: reserved-name detection (exported) ────────────────────────────────────

function Test-ReservedName {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)] [string] $Name,
        [string[]] $Reserved = @()
    )
    return ($Reserved -contains $Name)
}

# ── B4: read-only property stripping (exported) ───────────────────────────────

function Remove-ReadOnlyProperties {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Pure transform on an in-memory object; does not change system state.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseSingularNouns', '',
        Justification = 'Function name and contract are dictated by IMPLEMENTATION-BRIEF.md.')]
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)] [PSCustomObject] $Template,
        [PSCustomObject] $Schema
    )

    if (-not $Schema) { $Schema = Read-DefaultReadOnlySchema }
    $globalKeys = @()
    if ((Test-HasProperty $Schema 'global') -and $Schema.global) {
        $globalKeys = @($Schema.global)
    }
    $perTypeMap = @{}
    if ((Test-HasProperty $Schema 'perType') -and $Schema.perType) {
        foreach ($p in $Schema.perType.PSObject.Properties) {
            $perTypeMap[$p.Name] = @($p.Value)
        }
    }

    # Walker that propagates ParentType down the recursion so per-type stripping
    # can scope correctly even for sub-objects that lack their own `type` field.
    $walker = {
        param($node, $parentType)
        if ($node -is [System.Management.Automation.PSCustomObject]) {
            $localType = $parentType
            if (Test-IsResourceObject $node) { $localType = $node.type }

            if (Test-HasProperty $node 'properties') {
                $props = $node.properties
                if ($props -is [System.Management.Automation.PSCustomObject]) {
                    foreach ($g in $globalKeys) {
                        if (Test-HasProperty $props $g) {
                            $props.PSObject.Properties.Remove($g)
                        }
                    }
                    if ($localType -and $perTypeMap.ContainsKey($localType)) {
                        foreach ($k in $perTypeMap[$localType]) {
                            if (Test-HasProperty $props $k) {
                                $props.PSObject.Properties.Remove($k)
                            }
                        }
                    }
                }
            }

            foreach ($prop in @($node.PSObject.Properties)) {
                & $walker $prop.Value $localType
            }
        }
        elseif ($node -is [System.Collections.IEnumerable] -and $node -isnot [string]) {
            foreach ($item in $node) { & $walker $item $parentType }
        }
    }

    & $walker $Template $null
    return $Template
}

# ── B2: name-rewrite map builder (exported) ───────────────────────────────────

function Get-NameRewriteMap {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSReviewUnusedParameter', '',
        Justification = 'Prefix and Reserved are referenced inside the closure-captured $visit scriptblock; the analyzer does not see closure use.')]
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)] [PSCustomObject] $Template,
        [string]   $Prefix    = "dr-",
        [string[]] $Reserved  = @()
    )

    $map     = @{}
    $entries = [System.Collections.Generic.List[object]]::new()

    $visit = {
        param($node)
        if (-not (Test-IsResourceObject $node)) { return }
        $type     = $node.type
        $original = $node.name
        if ($original -isnot [string] -or [string]::IsNullOrEmpty($original)) { return }
        # Skip ARM expressions — we only map literal names.
        if ($original.StartsWith('[')) { return }

        $depth = Get-ResourceTypeDepth -Type $type
        if ($depth -ne 1) { return }   # only top-level resources go in the map

        $drName =
            if (Test-ReservedName -Name $original -Reserved $Reserved) { $original }
            elseif ($original.StartsWith($Prefix))                     { $original }   # idempotent
            else                                                       { "$Prefix$original" }

        if (-not $map.ContainsKey($original)) { $map[$original] = $drName }
        $entries.Add([PSCustomObject]@{
            Type         = $type
            OriginalName = $original
            DrName       = $drName
            Reserved     = (Test-ReservedName -Name $original -Reserved $Reserved)
        })
    }

    Invoke-WalkObject -Node $Template -Visit $visit
    return [PSCustomObject]@{
        Map     = $map
        Entries = $entries
    }
}

# ── First-pass transform (internal): names + locations + VNet address (B1, B3) ─

function Update-VnetAddressSpace {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Pure transform on an in-memory object; does not change system state.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [PSCustomObject] $Resource,
        [Parameter(Mandatory)] [string]         $VnetPrefix,
        [Parameter(Mandatory)] [string]         $SubnetPrefix,
        [Parameter(Mandatory)] [string[]]       $ReservedSubnetNames,
        [Parameter(Mandatory)] [PSCustomObject] $Flags
    )

    if (-not (Test-HasProperty $Resource 'properties')) { return }
    $props = $Resource.properties
    if ($props -isnot [System.Management.Automation.PSCustomObject]) { return }
    $vnetName = $Resource.name

    # Address space — replace first prefix only, flag if multi.
    if (Test-HasProperty $props 'addressSpace') {
        $addr = $props.addressSpace
        if ($addr -is [System.Management.Automation.PSCustomObject] -and `
            (Test-HasProperty $addr 'addressPrefixes')) {
            $existing = @($addr.addressPrefixes)
            if ($existing.Count -gt 1) {
                $Flags.requiresMultiPrefixDR += ,([PSCustomObject]@{
                    vnet               = $vnetName
                    originalPrefixes   = $existing
                    appliedFirstPrefix = $VnetPrefix
                    note               = "Only the first prefix was rewritten; remaining prefixes need offset arithmetic."
                })
            }
            $addr.addressPrefixes = @($VnetPrefix)
        }
    }

    # Subnets — replace first non-reserved subnet's addressPrefix; flag others.
    if (Test-HasProperty $props 'subnets') {
        $subnets = @($props.subnets)
        $rewritten = $false
        foreach ($subnet in $subnets) {
            if (-not $rewritten -and $subnet -is [System.Management.Automation.PSCustomObject]) {
                $sname = $subnet.name
                $isReserved = ($sname -is [string]) -and ($ReservedSubnetNames -contains $sname)
                if (-not $isReserved -and (Test-HasProperty $subnet 'properties') -and `
                    (Test-HasProperty $subnet.properties 'addressPrefix')) {
                    $subnet.properties.addressPrefix = $SubnetPrefix
                    $rewritten = $true
                }
            }
        }
        if ($subnets.Count -gt 1) {
            $Flags.requiresMultiSubnetDR += ,([PSCustomObject]@{
                vnet            = $vnetName
                subnetCount     = $subnets.Count
                appliedToFirst  = $rewritten
                appliedPrefix   = $SubnetPrefix
                note            = "Multiple subnets present; only the first non-reserved subnet was rewritten."
            })
        }
        if (-not $rewritten -and $subnets.Count -gt 0) {
            $Flags.requiresReservedSubnetDR += ,([PSCustomObject]@{
                vnet         = $vnetName
                subnetNames  = @($subnets | ForEach-Object { $_.name })
                note         = "All subnets are reserved (Gateway/Firewall/Bastion/RouteServer); manual subnet sizing required."
            })
        }
    }
}

function Invoke-Transformation {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSReviewUnusedParameter', '',
        Justification = 'All non-Template parameters are referenced inside the closure-captured $visit scriptblock.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [PSCustomObject] $Template,
        [Parameter(Mandatory)] [hashtable]      $Map,
        [Parameter(Mandatory)] [string]         $Region,
        [Parameter(Mandatory)] [string]         $VnetPrefix,
        [Parameter(Mandatory)] [string]         $SubnetPrefix,
        [Parameter(Mandatory)] [string[]]       $ReservedSubnetNames,
        [Parameter(Mandatory)] [PSCustomObject] $Flags
    )

    $visit = {
        param($node)

        # Rewrite literal `location` values to the DR region.
        if ((Test-HasProperty $node 'location') -and `
            $node.location -is [string] -and `
            -not $node.location.StartsWith('[')) {
            $node.location = $Region
        }

        if (Test-IsResourceObject $node) {
            $type  = $node.type
            $depth = Get-ResourceTypeDepth -Type $type

            # Rewrite `name` based on depth.
            if ($node.name -is [string] -and -not $node.name.StartsWith('[')) {
                if ($depth -eq 1) {
                    if ($Map.ContainsKey($node.name)) { $node.name = $Map[$node.name] }
                }
                else {
                    # Nested-type resource: name is "parent/child[/grandchild...]".
                    # Rewrite parent segments using the top-level map.
                    $segments = @($node.name.Split('/'))
                    for ($i = 0; $i -lt $segments.Count; $i++) {
                        if ($Map.ContainsKey($segments[$i])) { $segments[$i] = $Map[$segments[$i]] }
                    }
                    $node.name = ($segments -join '/')
                }
            }

            # B3: VNet-only address-space handling.
            if ($type -eq 'Microsoft.Network/virtualNetworks') {
                Update-VnetAddressSpace -Resource $node `
                    -VnetPrefix $VnetPrefix -SubnetPrefix $SubnetPrefix `
                    -ReservedSubnetNames $ReservedSubnetNames -Flags $Flags
            }
        }
    }

    Invoke-WalkObject -Node $Template -Visit $visit
    return $Template
}

# ── B2: second-pass reference rewriting (exported) ────────────────────────────

function Update-ResourceReferences {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Pure transform on an in-memory object; does not change system state.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseSingularNouns', '',
        Justification = 'Function name and contract are dictated by IMPLEMENTATION-BRIEF.md.')]
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)] [PSCustomObject] $Template,
        [Parameter(Mandatory)] [hashtable]      $Map
    )

    if ($Map.Count -eq 0) { return $Template }

    # Iterate longest-first to avoid prefix collisions
    # (e.g., `vnet-prod-shared` must be rewritten before `vnet-prod`).
    $keys = @($Map.Keys | Sort-Object -Property Length -Descending)
    $patterns = @()
    foreach ($k in $keys) {
        if ($k -eq $Map[$k]) { continue }   # nothing to rewrite (reserved or already prefixed)
        $patterns += [PSCustomObject]@{
            Original = $k
            DrName   = $Map[$k]
            Regex    = [regex]::new("(['""])$([regex]::Escape($k))(['""])")
        }
    }
    if ($patterns.Count -eq 0) { return $Template }

    $rewriteString = {
        param([string] $s)
        foreach ($p in $patterns) {
            if (-not $s.Contains($p.Original)) { continue }
            $s = $p.Regex.Replace($s, "`${1}$($p.DrName)`${2}")
        }
        return $s
    }

    $walker = {
        param($node)
        if ($node -is [System.Management.Automation.PSCustomObject]) {
            foreach ($prop in @($node.PSObject.Properties)) {
                $val = $prop.Value
                if ($val -is [string]) {
                    $new = & $rewriteString $val
                    if ($new -ne $val) { $prop.Value = $new }
                } else {
                    & $walker $val
                }
            }
        }
        elseif ($node -is [System.Collections.IList] -and $node -isnot [string]) {
            for ($i = 0; $i -lt $node.Count; $i++) {
                $item = $node[$i]
                if ($item -is [string]) {
                    $new = & $rewriteString $item
                    if ($new -ne $item) { $node[$i] = $new }
                } else {
                    & $walker $item
                }
            }
        }
    }

    & $walker $Template
    return $Template
}

# ── Main entry point (exported) ───────────────────────────────────────────────

function Convert-ForDR {
    <#
    .SYNOPSIS
    Transforms an exported ARM template into a DR-region equivalent.

    .DESCRIPTION
    Pure function: ARM template object in, transformed object out, no side
    effects, no Azure calls. Implements the four Round 1 correctness fixes
    from IMPLEMENTATION-BRIEF.md:
      - B1: reserved-name allowlist + type-aware prefixing
      - B2: cross-resource reference rewriting (two-pass)
      - B3: context-aware VNet address-space rewriting
      - B4: read-only property sanitisation

    Returns a PSCustomObject with two properties:
      - Template : the transformed ARM template object
      - Flags    : deferred-handling flags for cases the brief explicitly
                   defers (multi-prefix VNets, multi-subnet VNets,
                   all-reserved-subnet VNets). Caller persists these to
                   _reports/dr/flags.json.

    .NOTES
    Idempotent — safe to re-run on already-transformed templates.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)] [PSCustomObject] $Template,
        [Parameter(Mandatory)] [string]         $DrRegion,
        [Parameter(Mandatory)] [string]         $DrVnetPrefix,
        [Parameter(Mandatory)] [string]         $DrSubnetPrefix,
        [string]         $DrNamingPrefix     = "dr-",
        [string[]]       $ReservedNames      = @(),
        [PSCustomObject] $ReadOnlySchema
    )

    if (-not $ReservedNames -or $ReservedNames.Count -eq 0) {
        $ReservedNames = Read-DefaultReservedNames
    }
    if (-not $ReadOnlySchema) {
        $ReadOnlySchema = Read-DefaultReadOnlySchema
    }

    # Reserved subnet names are a subset of $ReservedNames intersected with the schema's subnetNames.
    # We re-read the file to keep this scoped correctly even when the caller passes a flat array.
    $reservedSubnetNames = @()
    if ($script:DefaultDataDir -and (Test-Path (Join-Path $script:DefaultDataDir 'reserved-names.json'))) {
        $obj = Get-Content (Join-Path $script:DefaultDataDir 'reserved-names.json') -Raw | ConvertFrom-Json
        if (Test-HasProperty $obj 'subnetNames') {
            $reservedSubnetNames = @($obj.subnetNames)
        }
    }

    # 1. Deep clone — never mutate the caller's input.
    $clean = ConvertTo-DeepClone -Node $Template

    # 2. B4: strip read-only props.
    $clean = Remove-ReadOnlyProperties -Template $clean -Schema $ReadOnlySchema

    # 3. Build name-rewrite map (B2 prep, also feeds B1 in pass 1).
    $mapInfo = Get-NameRewriteMap -Template $clean -Prefix $DrNamingPrefix -Reserved $ReservedNames

    # 4. First-pass transform: names, locations, B3 address-space.
    $flags = [PSCustomObject]@{
        requiresMultiPrefixDR    = @()
        requiresMultiSubnetDR    = @()
        requiresReservedSubnetDR = @()
    }
    $transformed = Invoke-Transformation -Template $clean -Map $mapInfo.Map `
        -Region $DrRegion -VnetPrefix $DrVnetPrefix -SubnetPrefix $DrSubnetPrefix `
        -ReservedSubnetNames $reservedSubnetNames -Flags $flags

    # 5. Second-pass reference rewriting (B2).
    $final = Update-ResourceReferences -Template $transformed -Map $mapInfo.Map

    return [PSCustomObject]@{
        Template = $final
        Flags    = $flags
        Map      = $mapInfo.Map
        Entries  = $mapInfo.Entries
    }
}

Export-ModuleMember -Function `
    Convert-ForDR, `
    Get-NameRewriteMap, `
    Update-ResourceReferences, `
    Remove-ReadOnlyProperties, `
    Test-ReservedName
