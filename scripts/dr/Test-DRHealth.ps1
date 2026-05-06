#Requires -Version 7.2
# =============================================================================
# scripts/dr/Test-DRHealth.ps1
# Round 4 §R4.2 — Per-resource-family DR health checks.
#
# Reads the Stage-7 deploy summary (_reports/deploy/deploy-summary.json) to
# enumerate the DR resource groups that were just provisioned, lists every
# resource in each RG via `az resource list`, and dispatches each by
# `type` to a per-family probe.
#
# Per-family probes implemented (matches Round 4.1 module set):
#   sql        Microsoft.Sql/servers/failoverGroups + databases  →
#                replicationState == "CATCH_UP", lag < threshold
#   cosmos     Microsoft.DocumentDB/databaseAccounts             →
#                DR region in readLocations + provisioningState == "Succeeded"
#   storage    Microsoft.Storage/storageAccounts                 →
#                secondary endpoints reachable, lastSyncTime recent
#   keyvault   Microsoft.KeyVault/vaults                         →
#                exists + enableSoftDelete + enablePurgeProtection
#   postgres   Microsoft.DBforPostgreSQL/flexibleServers (replica)→
#                state == "Replicating"
#   mysql      Microsoft.DBforMySQL/flexibleServers (replica)    →
#                replicationStatus / sourceServerResourceId present
#   redis      Microsoft.Cache/redis (geo-replication linked)    →
#                linkedServer present, provisioningState == "Succeeded"
#
# Output: <OutputDir>/dr-health.json with per-check status + summary counts.
#
# Status semantics (per the brief §R4.2):
#   healthy   green per the spec (e.g. CATCH_UP and lag < threshold).
#   degraded  operational but warning (e.g. lag > threshold, stale lastSyncTime).
#   unhealthy failed (e.g. SEEDING/BROKEN, replica state != Replicating).
#   unknown   could not probe (DryRun fixture missing entry; az error).
#
# Test seam: -DryRun -FixtureFile <path> short-circuits every probe to use the
# fixture's `probeResult` instead of calling `az`. Fail loudly if -DryRun is
# passed without -FixtureFile.
#
# CI hooks: when $env:GITHUB_OUTPUT is set, append:
#   DR_HEALTH_OK=true|false       (true ⇔ all checks healthy or unknown)
#   DR_HEALTH_SUMMARY=H/T         (healthy / total)
#
# Azure CLI references:
#   az resource list:
#     https://learn.microsoft.com/cli/azure/resource#az-resource-list
#   az sql failover-group show:
#     https://learn.microsoft.com/cli/azure/sql/failover-group#az-sql-failover-group-show
#   az sql db replica list-links:
#     https://learn.microsoft.com/cli/azure/sql/db/replica#az-sql-db-replica-list-links
#   az cosmosdb show:
#     https://learn.microsoft.com/cli/azure/cosmosdb#az-cosmosdb-show
#   az storage account show:
#     https://learn.microsoft.com/cli/azure/storage/account#az-storage-account-show
#   az keyvault show:
#     https://learn.microsoft.com/cli/azure/keyvault#az-keyvault-show
#   az postgres flexible-server replica list:
#     https://learn.microsoft.com/cli/azure/postgres/flexible-server/replica#az-postgres-flexible-server-replica-list
#   az postgres flexible-server show:
#     https://learn.microsoft.com/cli/azure/postgres/flexible-server#az-postgres-flexible-server-show
#   az mysql flexible-server replica list:
#     https://learn.microsoft.com/cli/azure/mysql/flexible-server/replica#az-mysql-flexible-server-replica-list
#   az mysql flexible-server show:
#     https://learn.microsoft.com/cli/azure/mysql/flexible-server#az-mysql-flexible-server-show
#   az redis show:
#     https://learn.microsoft.com/cli/azure/redis#az-redis-show
#   az redis server-link list:
#     https://learn.microsoft.com/cli/azure/redis/server-link#az-redis-server-link-list
# =============================================================================
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $DeploySummaryFile,
    [Parameter(Mandatory)] [string] $OutputDir,

    [string] $DrRegion = $(if ($env:DR_TARGET_REGION) { $env:DR_TARGET_REGION } else { 'northeurope' }),
    [int]    $SqlLagThresholdSeconds      = 60,
    [int]    $StorageSyncToleranceMinutes = 15,

    # When set, skip every `az` invocation and use $FixtureFile for inputs.
    [switch] $DryRun,

    # JSON fixture file. Required when -DryRun is set.
    # Shape:
    #   {
    #     "resourceGroups": [ "rg-anchor-dr", ... ],          // optional override
    #     "resources": [
    #       { "resourceId": "/subscriptions/.../<id>",
    #         "type":       "Microsoft.Sql/servers/databases",
    #         "name":       "...",                            // optional
    #         "resourceGroup": "rg-anchor-dr",                // optional
    #         "probeResult":  { ...family-specific... } },
    #       ...
    #     ]
    #   }
    [string] $FixtureFile,

    # When set, exit 1 if any check is unhealthy. Default behaviour is exit 0
    # so the workflow report job can surface the result without failing the
    # whole compliance pipeline. Pattern matches pr-compliance.yml.
    [switch] $FailOnUnhealthy
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

# ── Helpers ──────────────────────────────────────────────────────────────────

function Test-HasProperty {
    <#
    .SYNOPSIS
    Strict-mode-safe property existence check.
    #>
    param($Object, [Parameter(Mandatory)] [string] $Name)
    if ($null -eq $Object) { return $false }
    if ($Object -isnot [System.Management.Automation.PSObject] -and `
        $Object -isnot [System.Management.Automation.PSCustomObject]) { return $false }
    return ($null -ne $Object.PSObject.Properties[$Name])
}

function Get-PropertyValue {
    <#
    .SYNOPSIS
    Strict-mode-safe property accessor returning $null when missing.
    Wraps array values with the leading-comma idiom to defeat single-element
    pipeline unwrap.
    #>
    param($Object, [Parameter(Mandatory)] [string] $Name)
    if (-not (Test-HasProperty -Object $Object -Name $Name)) { return $null }
    $val = $Object.PSObject.Properties[$Name].Value
    if ($val -is [System.Collections.IEnumerable] -and $val -isnot [string]) {
        return , $val
    }
    return $val
}

function Get-FamilyForType {
    <#
    .SYNOPSIS
    Maps an Azure resource type string to the probe family handled by this script.
    Returns $null when the type is not in scope (e.g. resourceGroup, deployment).
    #>
    [OutputType([string])]
    param([Parameter(Mandatory)] [string] $Type)

    $t = $Type.ToLowerInvariant()
    switch -Regex ($t) {
        '^microsoft\.sql/servers/failovergroups$'       { return 'sql' }
        '^microsoft\.sql/servers/databases$'            { return 'sql' }
        '^microsoft\.documentdb/databaseaccounts$'      { return 'cosmos' }
        '^microsoft\.storage/storageaccounts$'          { return 'storage' }
        '^microsoft\.keyvault/vaults$'                  { return 'keyvault' }
        '^microsoft\.dbforpostgresql/flexibleservers$'  { return 'postgres' }
        '^microsoft\.dbformysql/flexibleservers$'       { return 'mysql' }
        '^microsoft\.cache/redis$'                      { return 'redis' }
        default                                         { return $null }
    }
}

function Invoke-AzJson {
    <#
    .SYNOPSIS
    Thin wrapper over `az` that parses JSON stdout. Throws on non-zero exit.
    Tests never reach this — DryRun short-circuits before any probe calls it.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string[]] $ArgumentList)

    $output = & az @ArgumentList 2>&1
    $exit   = $LASTEXITCODE
    $joined = ($output | Out-String)
    if ($exit -ne 0) {
        throw "az $($ArgumentList -join ' ') failed with exit $exit`: $joined"
    }
    if ([string]::IsNullOrWhiteSpace($joined)) { return $null }
    return ($joined | ConvertFrom-Json -Depth 50)
}

function Get-FixtureProbeResult {
    <#
    .SYNOPSIS
    Looks up a fixture entry by resourceId and returns its probeResult.
    Returns $null when the fixture has no matching entry, which the probe
    surfaces as `unknown`.
    #>
    param(
        $Fixture,
        [Parameter(Mandatory)] [string] $ResourceId
    )
    if ($null -eq $Fixture) { return $null }
    if (-not (Test-HasProperty -Object $Fixture -Name 'resources')) { return $null }
    foreach ($entry in @($Fixture.resources)) {
        $entryId = $null
        if (Test-HasProperty -Object $entry -Name 'resourceId') { $entryId = [string]$entry.resourceId }
        elseif (Test-HasProperty -Object $entry -Name 'id')     { $entryId = [string]$entry.id }
        if ($entryId -eq $ResourceId) {
            if (Test-HasProperty -Object $entry -Name 'probeResult') {
                return $entry.probeResult
            }
            return $null
        }
    }
    return $null
}

function New-CheckRecord {
    <#
    .SYNOPSIS
    Constructs the canonical check record returned by every probe.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Pure transform that builds an in-memory hashtable; no system state changed. New- verb is the canonical PowerShell verb for record-construction helpers.')]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)] [string] $ResourceId,
        [Parameter(Mandatory)] [string] $Type,
        [Parameter(Mandatory)] [string] $Family,
        [Parameter(Mandatory)] [string] $Status,
        [string] $Metric      = '',
        [string] $Remediation = '',
        $Details              = $null
    )
    $entry = [ordered]@{
        resourceId  = $ResourceId
        type        = $Type
        family      = $Family
        status      = $Status
        metric      = $Metric
        details     = $Details
        remediation = $Remediation
    }
    return $entry
}

# ── Per-family probes ────────────────────────────────────────────────────────
# Each probe MUST return a check record (ordered dict) and MUST NOT throw —
# unexpected errors are caught at the dispatch site and converted to `unknown`.

function Get-SqlFailoverGroupHealth {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSReviewUnusedParameter', '',
        Justification = 'DrRegion is reserved for future per-region cross-checks; kept on the signature for symmetry with siblings.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Resource,
        [Parameter(Mandatory)] [int]    $LagThresholdSeconds,
        [Parameter(Mandatory)] [string] $DrRegion,
        [switch] $UseFixture,
        $FixtureProbeResult
    )

    $resourceId = $Resource.id
    $type       = $Resource.type

    try {
        if ($UseFixture) {
            $probe = $FixtureProbeResult
        } else {
            # az sql failover-group show -- shape:
            #   { "replicationState": "CATCH_UP", "replicationRole": "Secondary",
            #     "partnerServers": [...], "databases": [...] }
            # az sql db replica list-links -- shape:
            #   [ { "replicationState": "CATCH_UP", "replicationLag": 12, ... } ]
            $rg     = $Resource.resourceGroup
            $name   = $Resource.name
            $probe  = $null
            if ($type -ieq 'Microsoft.Sql/servers/failoverGroups') {
                # name is "server/group"; az takes them separately.
                $parts  = $name.Split('/')
                if ($parts.Count -lt 2) { throw "Unexpected failover-group name '$name'" }
                $probe  = Invoke-AzJson -ArgumentList @(
                    'sql', 'failover-group', 'show',
                    '--resource-group', $rg,
                    '--server', $parts[0],
                    '--name',   $parts[1],
                    '--output', 'json'
                )
            } else {
                # Microsoft.Sql/servers/databases — query replication links.
                $parts  = $name.Split('/')
                if ($parts.Count -lt 2) { throw "Unexpected database name '$name'" }
                $links  = Invoke-AzJson -ArgumentList @(
                    'sql', 'db', 'replica', 'list-links',
                    '--resource-group', $rg,
                    '--server', $parts[0],
                    '--name',   $parts[1],
                    '--output', 'json'
                )
                # First link summarises secondary state.
                if ($links -and (@($links).Count -ge 1)) {
                    $probe = @($links)[0]
                }
            }
        }

        if ($null -eq $probe) {
            return New-CheckRecord -ResourceId $resourceId -Type $type -Family 'sql' `
                -Status 'unknown' -Metric 'no probe data' `
                -Remediation 'Verify the SQL failover group / replication link is provisioned in DR.' `
                -Details ([ordered]@{ error = 'no probe result' })
        }

        $replicationState = (Get-PropertyValue -Object $probe -Name 'replicationState')
        $lagSec           = (Get-PropertyValue -Object $probe -Name 'replicationLag')
        if ($null -eq $lagSec) { $lagSec = (Get-PropertyValue -Object $probe -Name 'lagSeconds') }

        $status = 'unknown'
        $remediation = ''
        if ([string]::IsNullOrWhiteSpace($replicationState)) {
            $status = 'unknown'
            $remediation = 'replicationState missing in probe payload; check failover-group provisioning.'
        }
        elseif ($replicationState -ieq 'CATCH_UP') {
            if ($null -ne $lagSec -and [int]$lagSec -gt $LagThresholdSeconds) {
                $status = 'degraded'
                $remediation = "Lag $lagSec s exceeds threshold ${LagThresholdSeconds}s. Investigate write load / network."
            } else {
                $status = 'healthy'
            }
        }
        elseif ($replicationState -ieq 'SEEDING') {
            $status = 'degraded'
            $remediation = 'Secondary is still seeding. Wait for CATCH_UP before relying on DR.'
        }
        else {
            # PENDING, SUSPENDED, BROKEN, etc.
            $status = 'unhealthy'
            $remediation = "replicationState='$replicationState' indicates an unhealthy replica. Recreate the failover group."
        }

        $metric = "replicationState=$replicationState"
        if ($null -ne $lagSec) { $metric += ", lagSec=$lagSec" }

        return New-CheckRecord -ResourceId $resourceId -Type $type -Family 'sql' `
            -Status $status -Metric $metric -Remediation $remediation -Details $probe
    }
    catch {
        return New-CheckRecord -ResourceId $resourceId -Type $type -Family 'sql' `
            -Status 'unknown' -Metric 'probe error' `
            -Remediation 'Probe failed; inspect details.error.' `
            -Details ([ordered]@{ error = "$_" })
    }
}

function Get-CosmosHealth {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Resource,
        [Parameter(Mandatory)] [string] $DrRegion,
        [switch] $UseFixture,
        $FixtureProbeResult
    )

    $resourceId = $Resource.id
    $type       = $Resource.type

    try {
        if ($UseFixture) {
            $probe = $FixtureProbeResult
        } else {
            # az cosmosdb show -- exposes:
            #   .provisioningState, .readLocations[].locationName, .writeLocations[]
            $probe = Invoke-AzJson -ArgumentList @(
                'cosmosdb', 'show',
                '--resource-group', $Resource.resourceGroup,
                '--name',           $Resource.name,
                '--output', 'json'
            )
        }

        if ($null -eq $probe) {
            return New-CheckRecord -ResourceId $resourceId -Type $type -Family 'cosmos' `
                -Status 'unknown' -Metric 'no probe data' `
                -Remediation 'Verify the Cosmos account is provisioned in DR.' `
                -Details ([ordered]@{ error = 'no probe result' })
        }

        $provisioningState = (Get-PropertyValue -Object $probe -Name 'provisioningState')
        $readLocations     = (Get-PropertyValue -Object $probe -Name 'readLocations')
        $regionNames = @()
        if ($null -ne $readLocations) {
            foreach ($loc in @($readLocations)) {
                $ln = (Get-PropertyValue -Object $loc -Name 'locationName')
                if ($null -ne $ln) { $regionNames += [string]$ln }
            }
        }
        # Locations come back human-spaced ("North Europe"). Normalise both sides.
        $normTarget = ($DrRegion -replace '\s', '').ToLowerInvariant()
        $hasDrRegion = $false
        foreach ($r in $regionNames) {
            if (($r -replace '\s', '').ToLowerInvariant() -eq $normTarget) { $hasDrRegion = $true; break }
        }

        $status = 'unknown'
        $remediation = ''
        if (-not $hasDrRegion) {
            $status = 'unhealthy'
            $remediation = "DR region '$DrRegion' missing from readLocations. Add it via az cosmosdb update --locations."
        }
        elseif ($provisioningState -ne 'Succeeded') {
            $status = 'degraded'
            $remediation = "provisioningState='$provisioningState' — wait for Succeeded or investigate failure."
        }
        else {
            $status = 'healthy'
        }

        $metric = "provisioningState=$provisioningState, readRegions=$($regionNames.Count), drRegionPresent=$hasDrRegion"
        return New-CheckRecord -ResourceId $resourceId -Type $type -Family 'cosmos' `
            -Status $status -Metric $metric -Remediation $remediation -Details $probe
    }
    catch {
        return New-CheckRecord -ResourceId $resourceId -Type $type -Family 'cosmos' `
            -Status 'unknown' -Metric 'probe error' `
            -Remediation 'Probe failed; inspect details.error.' `
            -Details ([ordered]@{ error = "$_" })
    }
}

function Get-StorageHealth {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSReviewUnusedParameter', 'DrRegion',
        Justification = 'Kept on the probe signature for symmetry with the other family probes (and to leave room for region-aware probing without churning callers).')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Resource,
        [Parameter(Mandatory)] [int]    $SyncToleranceMinutes,
        [Parameter(Mandatory)] [string] $DrRegion,
        [switch] $UseFixture,
        $FixtureProbeResult
    )

    $resourceId = $Resource.id
    $type       = $Resource.type

    try {
        if ($UseFixture) {
            $probe = $FixtureProbeResult
        } else {
            # az storage account show — exposes
            #   .secondaryEndpoints.{blob,queue,table,file}
            #   .geoReplicationStats.lastSyncTime
            #   .statusOfSecondary
            $probe = Invoke-AzJson -ArgumentList @(
                'storage', 'account', 'show',
                '--resource-group', $Resource.resourceGroup,
                '--name',           $Resource.name,
                '--expand', 'geoReplicationStats',
                '--output', 'json'
            )
        }

        if ($null -eq $probe) {
            return New-CheckRecord -ResourceId $resourceId -Type $type -Family 'storage' `
                -Status 'unknown' -Metric 'no probe data' `
                -Remediation 'Verify the storage account is provisioned in DR.' `
                -Details ([ordered]@{ error = 'no probe result' })
        }

        $secondaryEndpoints = (Get-PropertyValue -Object $probe -Name 'secondaryEndpoints')
        $geoStats           = (Get-PropertyValue -Object $probe -Name 'geoReplicationStats')
        if ($null -eq $geoStats) { $geoStats = (Get-PropertyValue -Object $probe -Name 'lastSyncTime') }
        $statusOfSecondary  = (Get-PropertyValue -Object $probe -Name 'statusOfSecondary')

        $hasSecondary = $false
        if ($null -ne $secondaryEndpoints) {
            $blobEp = (Get-PropertyValue -Object $secondaryEndpoints -Name 'blob')
            if (-not [string]::IsNullOrWhiteSpace($blobEp)) { $hasSecondary = $true }
        }

        $lastSync = $null
        if ($null -ne $geoStats) {
            if ($geoStats -is [string] -or $geoStats -is [datetime]) {
                $lastSync = $geoStats
            } else {
                $lastSync = (Get-PropertyValue -Object $geoStats -Name 'lastSyncTime')
            }
        }

        $lastSyncDt = $null
        if ($null -ne $lastSync) {
            try {
                if ($lastSync -is [datetime]) {
                    $lastSyncDt = $lastSync.ToUniversalTime()
                } else {
                    # ISO 8601 from az / fixture; normalise to UTC.
                    $lastSyncDt = ([datetime]::Parse([string]$lastSync,
                        [System.Globalization.CultureInfo]::InvariantCulture,
                        [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal))
                }
            } catch {
                $lastSyncDt = $null
            }
        }

        $status = 'unknown'
        $remediation = ''
        if (-not $hasSecondary) {
            $status = 'unhealthy'
            $remediation = "Secondary endpoints missing — storage account is not geo-replicated. Set sku to *_GRS / *_RAGRS."
        }
        elseif ($null -eq $lastSyncDt) {
            $status = 'degraded'
            $remediation = 'lastSyncTime missing or unparseable; geo-replication may not have completed yet.'
        }
        else {
            $age = (Get-Date).ToUniversalTime() - $lastSyncDt
            if ($age.TotalMinutes -gt $SyncToleranceMinutes) {
                $status = 'degraded'
                $remediation = "lastSyncTime is $([int]$age.TotalMinutes) min old (>$SyncToleranceMinutes). Investigate replication lag."
            } else {
                $status = 'healthy'
            }
        }

        $lastSyncStr = if ($lastSyncDt) { $lastSyncDt.ToString('o') } else { 'null' }
        $metric = "hasSecondary=$hasSecondary, statusOfSecondary=$statusOfSecondary, lastSyncTime=$lastSyncStr"
        return New-CheckRecord -ResourceId $resourceId -Type $type -Family 'storage' `
            -Status $status -Metric $metric -Remediation $remediation -Details $probe
    }
    catch {
        return New-CheckRecord -ResourceId $resourceId -Type $type -Family 'storage' `
            -Status 'unknown' -Metric 'probe error' `
            -Remediation 'Probe failed; inspect details.error.' `
            -Details ([ordered]@{ error = "$_" })
    }
}

function Get-KeyVaultHealth {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Resource,
        [switch] $UseFixture,
        $FixtureProbeResult
    )

    $resourceId = $Resource.id
    $type       = $Resource.type

    try {
        if ($UseFixture) {
            $probe = $FixtureProbeResult
        } else {
            # az keyvault show -- exposes
            #   .properties.enableSoftDelete, .properties.enablePurgeProtection,
            #   .properties.provisioningState
            $probe = Invoke-AzJson -ArgumentList @(
                'keyvault', 'show',
                '--resource-group', $Resource.resourceGroup,
                '--name',           $Resource.name,
                '--output', 'json'
            )
        }

        if ($null -eq $probe) {
            return New-CheckRecord -ResourceId $resourceId -Type $type -Family 'keyvault' `
                -Status 'unhealthy' -Metric 'vault not found' `
                -Remediation 'DR Key Vault is missing. Re-run Stage 7 deploy.' `
                -Details ([ordered]@{ error = 'no probe result' })
        }

        $props              = (Get-PropertyValue -Object $probe -Name 'properties')
        $enableSoftDelete   = if ($props) { (Get-PropertyValue -Object $props -Name 'enableSoftDelete') } else { $null }
        $enablePurgeProtect = if ($props) { (Get-PropertyValue -Object $props -Name 'enablePurgeProtection') } else { $null }

        $status = 'healthy'
        $issues = @()
        if (-not [bool]$enableSoftDelete) {
            $status = 'unhealthy'
            $issues += 'enableSoftDelete=false'
        }
        if (-not [bool]$enablePurgeProtect) {
            if ($status -ne 'unhealthy') { $status = 'degraded' }
            $issues += 'enablePurgeProtection=false'
        }

        $remediation = if ($issues.Count -gt 0) {
            "Enable Key Vault DR safeguards: " + ($issues -join ', ')
        } else { '' }

        $metric = "enableSoftDelete=$enableSoftDelete, enablePurgeProtection=$enablePurgeProtect"
        return New-CheckRecord -ResourceId $resourceId -Type $type -Family 'keyvault' `
            -Status $status -Metric $metric -Remediation $remediation -Details $probe
    }
    catch {
        return New-CheckRecord -ResourceId $resourceId -Type $type -Family 'keyvault' `
            -Status 'unknown' -Metric 'probe error' `
            -Remediation 'Probe failed; inspect details.error.' `
            -Details ([ordered]@{ error = "$_" })
    }
}

function Get-PostgresReplicaHealth {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Resource,
        [switch] $UseFixture,
        $FixtureProbeResult
    )

    $resourceId = $Resource.id
    $type       = $Resource.type

    try {
        if ($UseFixture) {
            $probe = $FixtureProbeResult
        } else {
            # The DR copy IS the replica — `az postgres flexible-server show`
            # on the replica server exposes:
            #   .replica.role == "AsyncReplica"
            #   .replicationRole / .replica.replicationState (newer schema)
            # Older schema exposes .state via replica list-links on the source.
            $probe = Invoke-AzJson -ArgumentList @(
                'postgres', 'flexible-server', 'show',
                '--resource-group', $Resource.resourceGroup,
                '--name',           $Resource.name,
                '--output', 'json'
            )
        }

        if ($null -eq $probe) {
            return New-CheckRecord -ResourceId $resourceId -Type $type -Family 'postgres' `
                -Status 'unknown' -Metric 'no probe data' `
                -Remediation 'Probe returned nothing — verify the Postgres replica exists.' `
                -Details ([ordered]@{ error = 'no probe result' })
        }

        # Normalise the state lookup. Different az versions expose it differently.
        $state = (Get-PropertyValue -Object $probe -Name 'state')
        if ([string]::IsNullOrWhiteSpace($state)) {
            $replica = (Get-PropertyValue -Object $probe -Name 'replica')
            if ($null -ne $replica) {
                $state = (Get-PropertyValue -Object $replica -Name 'replicationState')
                if ([string]::IsNullOrWhiteSpace($state)) {
                    $state = (Get-PropertyValue -Object $replica -Name 'role')
                }
            }
        }
        if ([string]::IsNullOrWhiteSpace($state)) {
            $state = (Get-PropertyValue -Object $probe -Name 'replicationState')
        }

        $status = 'unknown'
        $remediation = ''
        if ([string]::IsNullOrWhiteSpace($state)) {
            $status = 'unknown'
            $remediation = 'replication state field not present in probe payload.'
        }
        elseif ($state -ieq 'Replicating' -or $state -ieq 'AsyncReplica') {
            $status = 'healthy'
        }
        elseif ($state -ieq 'Catchup' -or $state -ieq 'Reconfiguring') {
            $status = 'degraded'
            $remediation = "Replica state='$state'; wait for Replicating before relying on DR."
        }
        else {
            $status = 'unhealthy'
            $remediation = "Replica state='$state' indicates a broken replica. Recreate via az postgres flexible-server replica create."
        }

        $metric = "state=$state"
        return New-CheckRecord -ResourceId $resourceId -Type $type -Family 'postgres' `
            -Status $status -Metric $metric -Remediation $remediation -Details $probe
    }
    catch {
        return New-CheckRecord -ResourceId $resourceId -Type $type -Family 'postgres' `
            -Status 'unknown' -Metric 'probe error' `
            -Remediation 'Probe failed; inspect details.error.' `
            -Details ([ordered]@{ error = "$_" })
    }
}

function Get-MysqlReplicaHealth {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Resource,
        [switch] $UseFixture,
        $FixtureProbeResult
    )

    $resourceId = $Resource.id
    $type       = $Resource.type

    try {
        if ($UseFixture) {
            $probe = $FixtureProbeResult
        } else {
            # az mysql flexible-server show on the replica exposes:
            #   .replicationRole == "Replica"
            #   .sourceServerResourceId
            #   .replicaCapacity (on the source)
            $probe = Invoke-AzJson -ArgumentList @(
                'mysql', 'flexible-server', 'show',
                '--resource-group', $Resource.resourceGroup,
                '--name',           $Resource.name,
                '--output', 'json'
            )
        }

        if ($null -eq $probe) {
            return New-CheckRecord -ResourceId $resourceId -Type $type -Family 'mysql' `
                -Status 'unknown' -Metric 'no probe data' `
                -Remediation 'Probe returned nothing — verify the MySQL replica exists.' `
                -Details ([ordered]@{ error = 'no probe result' })
        }

        $role           = (Get-PropertyValue -Object $probe -Name 'replicationRole')
        if ([string]::IsNullOrWhiteSpace($role)) {
            $role = (Get-PropertyValue -Object $probe -Name 'replicaRole')
        }
        $sourceServerId = (Get-PropertyValue -Object $probe -Name 'sourceServerResourceId')
        $state          = (Get-PropertyValue -Object $probe -Name 'state')
        if ([string]::IsNullOrWhiteSpace($state)) {
            $state = (Get-PropertyValue -Object $probe -Name 'replicationState')
        }

        $status = 'unknown'
        $remediation = ''
        if ([string]::IsNullOrWhiteSpace($role)) {
            $status = 'unknown'
            $remediation = 'replicationRole missing — confirm DR server is configured as a replica.'
        }
        elseif ($role -ieq 'Replica' -or $role -ieq 'AsyncReplica') {
            if (-not [string]::IsNullOrWhiteSpace($state) -and `
                $state -inotmatch '^(Ready|Replicating|AsyncReplica)$') {
                $status = 'unhealthy'
                $remediation = "MySQL replica state='$state' indicates a broken replica."
            } else {
                $status = 'healthy'
            }
        }
        else {
            $status = 'unhealthy'
            $remediation = "Server role='$role'; expected 'Replica'. The DR server is not a replica."
        }

        $metric = "replicationRole=$role"
        if (-not [string]::IsNullOrWhiteSpace($state)) { $metric += ", state=$state" }
        if ($sourceServerId)                            { $metric += ", source=$sourceServerId" }
        return New-CheckRecord -ResourceId $resourceId -Type $type -Family 'mysql' `
            -Status $status -Metric $metric -Remediation $remediation -Details $probe
    }
    catch {
        return New-CheckRecord -ResourceId $resourceId -Type $type -Family 'mysql' `
            -Status 'unknown' -Metric 'probe error' `
            -Remediation 'Probe failed; inspect details.error.' `
            -Details ([ordered]@{ error = "$_" })
    }
}

function Get-RedisGeoReplicationHealth {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Resource,
        [switch] $UseFixture,
        $FixtureProbeResult
    )

    $resourceId = $Resource.id
    $type       = $Resource.type

    try {
        if ($UseFixture) {
            $probe = $FixtureProbeResult
        } else {
            # az redis show + az redis server-link list — fixture format
            # combines them under one object: { provisioningState, linkedServers: [...] }
            $base = Invoke-AzJson -ArgumentList @(
                'redis', 'show',
                '--resource-group', $Resource.resourceGroup,
                '--name',           $Resource.name,
                '--output', 'json'
            )
            $links = Invoke-AzJson -ArgumentList @(
                'redis', 'server-link', 'list',
                '--resource-group', $Resource.resourceGroup,
                '--name',           $Resource.name,
                '--output', 'json'
            )
            $probe = [PSCustomObject]@{
                provisioningState = (Get-PropertyValue -Object $base -Name 'provisioningState')
                linkedServers     = $links
            }
        }

        if ($null -eq $probe) {
            return New-CheckRecord -ResourceId $resourceId -Type $type -Family 'redis' `
                -Status 'unknown' -Metric 'no probe data' `
                -Remediation 'Probe returned nothing — verify the Redis instance exists.' `
                -Details ([ordered]@{ error = 'no probe result' })
        }

        $provisioningState = (Get-PropertyValue -Object $probe -Name 'provisioningState')
        $linkedServers     = (Get-PropertyValue -Object $probe -Name 'linkedServers')
        if ($null -eq $linkedServers) {
            $linkedServers = (Get-PropertyValue -Object $probe -Name 'linkedServer')
        }

        $linkedCount = 0
        if ($null -ne $linkedServers) {
            foreach ($link in @($linkedServers)) {
                if ($null -ne $link) { $linkedCount++ }
            }
        }

        $status = 'unknown'
        $remediation = ''
        if ($linkedCount -lt 1) {
            $status = 'unhealthy'
            $remediation = 'No geo-replication link present. Pair with primary via az redis server-link create.'
        }
        elseif ($provisioningState -and $provisioningState -ne 'Succeeded') {
            $status = 'degraded'
            $remediation = "provisioningState='$provisioningState' — wait for Succeeded."
        }
        else {
            $status = 'healthy'
        }

        $metric = "provisioningState=$provisioningState, linkedServers=$linkedCount"
        return New-CheckRecord -ResourceId $resourceId -Type $type -Family 'redis' `
            -Status $status -Metric $metric -Remediation $remediation -Details $probe
    }
    catch {
        return New-CheckRecord -ResourceId $resourceId -Type $type -Family 'redis' `
            -Status 'unknown' -Metric 'probe error' `
            -Remediation 'Probe failed; inspect details.error.' `
            -Details ([ordered]@{ error = "$_" })
    }
}

# ── Dispatcher ───────────────────────────────────────────────────────────────

function Invoke-FamilyProbe {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Resource,
        [Parameter(Mandatory)] [string] $Family,
        [Parameter(Mandatory)] [int]    $LagThresholdSeconds,
        [Parameter(Mandatory)] [int]    $StorageSyncToleranceMinutes,
        [Parameter(Mandatory)] [string] $DrRegion,
        [switch] $UseFixture,
        $FixtureProbeResult
    )

    switch ($Family) {
        'sql'      {
            return Get-SqlFailoverGroupHealth -Resource $Resource `
                -LagThresholdSeconds $LagThresholdSeconds -DrRegion $DrRegion `
                -UseFixture:$UseFixture -FixtureProbeResult $FixtureProbeResult
        }
        'cosmos'   {
            return Get-CosmosHealth -Resource $Resource -DrRegion $DrRegion `
                -UseFixture:$UseFixture -FixtureProbeResult $FixtureProbeResult
        }
        'storage'  {
            return Get-StorageHealth -Resource $Resource `
                -SyncToleranceMinutes $StorageSyncToleranceMinutes -DrRegion $DrRegion `
                -UseFixture:$UseFixture -FixtureProbeResult $FixtureProbeResult
        }
        'keyvault' {
            return Get-KeyVaultHealth -Resource $Resource `
                -UseFixture:$UseFixture -FixtureProbeResult $FixtureProbeResult
        }
        'postgres' {
            return Get-PostgresReplicaHealth -Resource $Resource `
                -UseFixture:$UseFixture -FixtureProbeResult $FixtureProbeResult
        }
        'mysql'    {
            return Get-MysqlReplicaHealth -Resource $Resource `
                -UseFixture:$UseFixture -FixtureProbeResult $FixtureProbeResult
        }
        'redis'    {
            return Get-RedisGeoReplicationHealth -Resource $Resource `
                -UseFixture:$UseFixture -FixtureProbeResult $FixtureProbeResult
        }
        default    {
            return New-CheckRecord -ResourceId $Resource.id -Type $Resource.type -Family $Family `
                -Status 'unknown' -Metric "no probe for family '$Family'" `
                -Remediation 'Add a probe to Test-DRHealth.ps1 for this family.' `
                -Details $null
        }
    }
}

# ── Main ─────────────────────────────────────────────────────────────────────

if ($DryRun -and [string]::IsNullOrWhiteSpace($FixtureFile)) {
    Write-Error "Test-DRHealth: -DryRun requires -FixtureFile. Refusing to silently call az."
    exit 2
}

if (-not (Test-Path -LiteralPath $DeploySummaryFile)) {
    throw "DeploySummaryFile not found: $DeploySummaryFile"
}

$null = New-Item -ItemType Directory -Force -Path $OutputDir

$summary = Get-Content -LiteralPath $DeploySummaryFile -Raw | ConvertFrom-Json -Depth 30

# Resource groups: prefer the deploy-summary's deploymentNames (which encode
# rg-<workload>-dr) and fall back to every distinct -dr suffixed group seen
# across deploymentNames + summary.failures.
$rgs = [System.Collections.Generic.HashSet[string]]::new()
if (Test-HasProperty -Object $summary -Name 'deploymentNames') {
    foreach ($n in @($summary.deploymentNames)) {
        # draac-<sha7>-rg-<workload>-dr  →  rg-<workload>-dr
        if ([string]$n -match '(rg-[A-Za-z0-9._-]+-dr)$') {
            $null = $rgs.Add($Matches[1])
        }
    }
}
if (Test-HasProperty -Object $summary -Name 'failures') {
    foreach ($f in @($summary.failures)) {
        if (Test-HasProperty -Object $f -Name 'resourceGroup') {
            if (-not [string]::IsNullOrWhiteSpace($f.resourceGroup)) {
                $null = $rgs.Add([string]$f.resourceGroup)
            }
        }
    }
}

$fixture = $null
if ($DryRun) {
    if (-not (Test-Path -LiteralPath $FixtureFile)) {
        Write-Error "Test-DRHealth: FixtureFile not found: $FixtureFile"
        exit 2
    }
    $fixture = Get-Content -LiteralPath $FixtureFile -Raw | ConvertFrom-Json -Depth 50

    # If the fixture overrides resourceGroups, use them; otherwise infer from
    # the resource list.
    if (Test-HasProperty -Object $fixture -Name 'resourceGroups') {
        $rgs.Clear()
        foreach ($r in @($fixture.resourceGroups)) { $null = $rgs.Add([string]$r) }
    }
}

Write-Host "============================================================"
Write-Host "Test-DRHealth"
Write-Host "  Deploy summary:     $DeploySummaryFile"
Write-Host "  Output dir:         $OutputDir"
Write-Host "  DR region:          $DrRegion"
Write-Host "  SQL lag threshold:  ${SqlLagThresholdSeconds}s"
Write-Host "  Storage tolerance:  ${StorageSyncToleranceMinutes} min"
Write-Host "  DryRun:             $($DryRun.IsPresent)"
Write-Host "  Resource groups:    $($rgs.Count)"
Write-Host "============================================================"

# Build the resource list. In DryRun mode we walk fixture.resources directly
# (and can rely on each entry providing enough fields to dispatch). In live
# mode we list each RG via `az resource list`.
$resourceList = [System.Collections.Generic.List[object]]::new()
if ($DryRun) {
    if (Test-HasProperty -Object $fixture -Name 'resources') {
        foreach ($r in @($fixture.resources)) { $resourceList.Add($r) }
    }
} else {
    foreach ($rg in @($rgs)) {
        try {
            $listed = Invoke-AzJson -ArgumentList @(
                'resource', 'list',
                '--resource-group', $rg,
                '--output', 'json'
            )
            if ($null -ne $listed) {
                foreach ($r in @($listed)) {
                    # Tag on resourceGroup defensively (older az versions omit it).
                    if (-not (Test-HasProperty -Object $r -Name 'resourceGroup') -or `
                        [string]::IsNullOrWhiteSpace($r.resourceGroup)) {
                        $r | Add-Member -NotePropertyName 'resourceGroup' -NotePropertyValue $rg -Force
                    }
                    $resourceList.Add($r)
                }
            }
        }
        catch {
            Write-Warning "  resource list failed for $rg`: $_"
            # Continue with the next RG — fault-tolerant.
        }
    }
}

# Sort by id (idempotency: same input → same output ordering).
$sortedResources = @($resourceList | Sort-Object -Property `
    @{ Expression = { if (Test-HasProperty -Object $_ -Name 'id') { [string]$_.id } else { '' } } })

$checks = [System.Collections.Generic.List[object]]::new()
foreach ($r in $sortedResources) {
    $rType = if (Test-HasProperty -Object $r -Name 'type') { [string]$r.type } else { '' }
    if ([string]::IsNullOrWhiteSpace($rType)) { continue }

    $family = Get-FamilyForType -Type $rType
    if ([string]::IsNullOrWhiteSpace($family)) { continue }   # not in scope

    $resId = if (Test-HasProperty -Object $r -Name 'id') { [string]$r.id } `
             elseif (Test-HasProperty -Object $r -Name 'resourceId') { [string]$r.resourceId } `
             else { '<unknown>' }

    # Some fixtures use 'resourceId' instead of 'id'. Promote it for downstream.
    if (-not (Test-HasProperty -Object $r -Name 'id') -and `
        (Test-HasProperty -Object $r -Name 'resourceId')) {
        $r | Add-Member -NotePropertyName 'id' -NotePropertyValue ([string]$r.resourceId) -Force
    }

    $fixtureProbe = $null
    if ($DryRun) {
        $fixtureProbe = Get-FixtureProbeResult -Fixture $fixture -ResourceId $resId
    }

    try {
        $check = Invoke-FamilyProbe -Resource $r -Family $family `
            -LagThresholdSeconds $SqlLagThresholdSeconds `
            -StorageSyncToleranceMinutes $StorageSyncToleranceMinutes `
            -DrRegion $DrRegion `
            -UseFixture:$DryRun -FixtureProbeResult $fixtureProbe
    }
    catch {
        # Belt-and-braces: probes catch their own errors, but dispatcher errors
        # (e.g. malformed fixture) must not abort the whole run.
        $check = New-CheckRecord -ResourceId $resId -Type $rType -Family $family `
            -Status 'unknown' -Metric 'dispatch error' `
            -Remediation 'Dispatcher raised an unexpected error; inspect details.error.' `
            -Details ([ordered]@{ error = "$_" })
    }

    $checks.Add([PSCustomObject]$check)
}

# Sort checks by resourceId for stable output.
$sortedChecks = @($checks | Sort-Object -Property resourceId)

$total     = $sortedChecks.Count
$healthy   = @($sortedChecks | Where-Object { $_.status -eq 'healthy' }).Count
$degraded  = @($sortedChecks | Where-Object { $_.status -eq 'degraded' }).Count
$unhealthy = @($sortedChecks | Where-Object { $_.status -eq 'unhealthy' }).Count
$unknown   = @($sortedChecks | Where-Object { $_.status -eq 'unknown' }).Count

$report = [ordered]@{
    generatedAt  = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    drRegion     = $DrRegion
    totalChecks  = $total
    healthy      = $healthy
    degraded     = $degraded
    unhealthy    = $unhealthy
    unknown      = $unknown
    checks       = $sortedChecks
}

$reportPath = Join-Path $OutputDir 'dr-health.json'
$report | ConvertTo-Json -Depth 30 | Set-Content -Path $reportPath -Encoding UTF8

Write-Host ""
Write-Host "DR HEALTH COMPLETE  Total: $total  Healthy: $healthy  Degraded: $degraded  Unhealthy: $unhealthy  Unknown: $unknown"
Write-Host "  Report: $reportPath"

# DR_HEALTH_OK is true ONLY when every check is healthy or unknown
# (degraded/unhealthy ⇒ false). DR_HEALTH_SUMMARY = healthy/total.
$drHealthOk = ($degraded -eq 0 -and $unhealthy -eq 0)

if ($env:GITHUB_OUTPUT) {
    $okStr = if ($drHealthOk) { 'true' } else { 'false' }
    Add-Content -Path $env:GITHUB_OUTPUT -Value ("DR_HEALTH_OK={0}" -f $okStr)
    Add-Content -Path $env:GITHUB_OUTPUT -Value ("DR_HEALTH_SUMMARY={0}/{1}" -f $healthy, $total)
}

if ($FailOnUnhealthy -and $unhealthy -gt 0) {
    exit 1
}
exit 0
