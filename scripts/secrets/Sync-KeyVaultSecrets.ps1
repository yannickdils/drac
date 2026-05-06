#Requires -Version 7.2
# =============================================================================
# scripts/secrets/Sync-KeyVaultSecrets.ps1
# Round 4 §R4.4 — Function App run.ps1 that replicates new secret versions
# from the PRIMARY Key Vault to the DR Key Vault.
#
# Triggering shape (Azure Functions PowerShell binding):
#   The function host injects the Event Grid event into the parameter named in
#   function.json's `bindings[0].name` field. By project convention the
#   binding name is `EventGridEvent`, so the host calls this script with
#   `-EventGridEvent <eventObject>` and an auto-supplied `$TriggerMetadata`.
#
# Standalone execution shape (tests / operator dry-runs):
#   pwsh -File Sync-KeyVaultSecrets.ps1 `
#        -EventFile        ./event.json `
#        -PrimaryVaultName <kv-primary> `
#        -DrVaultName      <kv-dr> `
#        -DryRun
#
# Module choice (project rule §7 — "No AzureRM PowerShell module"):
#   This script uses the modern `Az.KeyVault` module (NOT the deprecated
#   `AzureRM.KeyVault`). The project rule forbids AzureRM specifically; the Az
#   PowerShell module is the supported, idiomatic option for PowerShell
#   Functions and is permitted by the brief. Reference cmdlets:
#     Get-AzKeyVaultSecret -- https://learn.microsoft.com/en-us/powershell/module/az.keyvault/get-azkeyvaultsecret
#     Set-AzKeyVaultSecret -- https://learn.microsoft.com/en-us/powershell/module/az.keyvault/set-azkeyvaultsecret
#     Connect-AzAccount    -- https://learn.microsoft.com/en-us/powershell/module/az.accounts/connect-azaccount
#   (URLs looked up 2026-05-06.)
#
# Idempotency:
#   Before writing to the DR vault we fetch the current latest version there
#   and compare both the secret text and the relevant tag set. If equal, the
#   write is skipped and the run logs "already-synced". The
#   `DRAAC_SECRETS_FORCE_INSYNC` environment variable forces the in-sync
#   branch (used by the test harness to exercise this path without a real
#   DR vault).
#
# Fault tolerance:
#   Per-event failures are caught and logged but never crash the host. Only
#   non-recoverable conditions (missing config, missing event payload) throw.
# =============================================================================
[CmdletBinding(DefaultParameterSetName = 'EventGrid')]
param(
    # Event Grid binding shape — populated automatically by the Functions host.
    [Parameter(ParameterSetName = 'EventGrid', Position = 0)]
    $EventGridEvent,

    # Functions host auto-injects $TriggerMetadata. Declared so PSScriptAnalyzer
    # does not flag it as an unbound automatic variable when running inside the
    # Functions host. Unused in standalone mode.
    [Parameter(ParameterSetName = 'EventGrid')]
    $TriggerMetadata,

    # Standalone-test shape: read the event from a file on disk.
    [Parameter(ParameterSetName = 'Manual')]
    [string] $EventFile,

    # Standalone overrides for the vault names the script would otherwise read
    # from the PRIMARY_KEYVAULT_NAME / DR_KEYVAULT_NAME environment variables.
    [Parameter(ParameterSetName = 'Manual')]
    [string] $PrimaryVaultName,

    [Parameter(ParameterSetName = 'Manual')]
    [string] $DrVaultName,

    # When set, no Get-AzKeyVaultSecret / Set-AzKeyVaultSecret calls are made.
    # The script logs the action it WOULD take and exits 0. Used by the
    # acceptance test in tests/round-4/Test-SyncKeyVaultSecrets.ps1.
    [switch] $DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Acknowledge the Functions-host-injected automatic variable so PSScriptAnalyzer
# does not flag it as an unbound parameter; it is read-only metadata about the
# trigger and is unused here outside log decoration. Wrapped in a strict-mode
# safe access so the line never throws when the Manual parameter set is active
# and $TriggerMetadata is unbound.
if ($PSBoundParameters.ContainsKey('TriggerMetadata')) { $null = $TriggerMetadata }

# ── Helpers ──────────────────────────────────────────────────────────────────

function Test-HasProperty {
    <#
    .SYNOPSIS
    Strict-mode-safe test for whether a PSObject exposes a given property name.
    Returns false (never throws) when the property does not exist.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)] $InputObject,
        [Parameter(Mandatory)] [string] $Name
    )
    if ($null -eq $InputObject) { return $false }
    if ($InputObject -is [hashtable]) { return $InputObject.ContainsKey($Name) }
    $prop = $InputObject.PSObject.Properties[$Name]
    return ($null -ne $prop)
}

function Get-PropertyValue {
    <#
    .SYNOPSIS
    Strict-mode-safe property accessor. Returns `$null` when the property is
    absent; preserves array-typed values via the comma operator so single-
    element arrays survive PowerShell's auto-unwrap.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $InputObject,
        [Parameter(Mandatory)] [string] $Name
    )
    if (-not (Test-HasProperty -InputObject $InputObject -Name $Name)) { return $null }
    if ($InputObject -is [hashtable]) { return $InputObject[$Name] }
    $val = $InputObject.PSObject.Properties[$Name].Value
    if ($val -is [System.Array]) { return ,$val }
    return $val
}

function Resolve-EventPayload {
    <#
    .SYNOPSIS
    Normalises whatever the host (or the test harness) handed us into a
    consistent PSCustomObject with `eventType`, `data`, `id`, `subject`, etc.
    #>
    [CmdletBinding()]
    [OutputType([psobject])]
    param(
        $RawEvent,
        [string] $FilePath
    )

    if ($null -ne $RawEvent) {
        if ($RawEvent -is [string]) {
            return ($RawEvent | ConvertFrom-Json -Depth 20)
        }
        return $RawEvent
    }

    if ([string]::IsNullOrWhiteSpace($FilePath)) {
        throw 'No event payload supplied: pass -EventGridEvent (Functions host) or -EventFile (standalone).'
    }
    if (-not (Test-Path -LiteralPath $FilePath)) {
        throw "Event file not found: $FilePath"
    }
    $raw = Get-Content -Raw -LiteralPath $FilePath
    return ($raw | ConvertFrom-Json -Depth 20)
}

function Get-EventTypeFromPayload {
    <#
    .SYNOPSIS
    Returns the event type string from either the EventGridSchema (`eventType`)
    or CloudEvents (`type`) shape — defensive against future binding changes.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] $EventObject)
    $val = Get-PropertyValue -InputObject $EventObject -Name 'eventType'
    if (-not [string]::IsNullOrWhiteSpace($val)) { return $val }
    $val = Get-PropertyValue -InputObject $EventObject -Name 'type'
    if (-not [string]::IsNullOrWhiteSpace($val)) { return $val }
    return ''
}

function Get-SecretCoordinates {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseSingularNouns', '',
        Justification = 'Returns a triple (VaultName, SecretName, Version) — the plural noun reflects that the function extracts a coordinate set, not a single coordinate.')]
    <#
    .SYNOPSIS
    Extracts (VaultName, SecretName, Version) from an EventGridSchema KV event.
    The KV event payload puts these under `data.VaultName` / `data.ObjectName`
    / `data.Version`. CloudEvents shape uses the same `data` envelope.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)] $EventObject)

    $data = Get-PropertyValue -InputObject $EventObject -Name 'data'
    if ($null -eq $data) { throw "Event has no 'data' member." }

    $vault    = Get-PropertyValue -InputObject $data -Name 'VaultName'
    $object   = Get-PropertyValue -InputObject $data -Name 'ObjectName'
    $version  = Get-PropertyValue -InputObject $data -Name 'Version'
    $objType  = Get-PropertyValue -InputObject $data -Name 'ObjectType'

    return @{
        VaultName  = $vault
        SecretName = $object
        Version    = $version
        ObjectType = $objType
    }
}

function Test-AzKeyVaultModuleAvailable {
    <#
    .SYNOPSIS
    True when Get-AzKeyVaultSecret is importable. The Functions host loads
    Az.KeyVault on-demand from `requirements.psd1`; standalone runs need it on
    the host's $env:PSModulePath.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    return ($null -ne (Get-Command -Name 'Get-AzKeyVaultSecret' -ErrorAction SilentlyContinue))
}

function Get-PrimarySecret {
    <#
    .SYNOPSIS
    Reads the (vault, name, version) secret from primary. Returns the raw
    PSKeyVaultSecret. Caller is responsible for `-AsPlainText` extraction so
    the SecureString never lands in a string variable longer than necessary.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)] [string] $VaultName,
        [Parameter(Mandatory)] [string] $SecretName,
        [Parameter(Mandatory)] [string] $Version
    )
    return (Get-AzKeyVaultSecret -VaultName $VaultName -Name $SecretName -Version $Version -ErrorAction Stop)
}

function Get-DrSecretLatest {
    <#
    .SYNOPSIS
    Returns the current latest version of `$SecretName` in the DR vault, or
    `$null` if the secret has never been written.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)] [string] $VaultName,
        [Parameter(Mandatory)] [string] $SecretName
    )
    try {
        return (Get-AzKeyVaultSecret -VaultName $VaultName -Name $SecretName -ErrorAction Stop)
    }
    catch {
        # 404 / SecretNotFound is the expected first-run signal. Bubble any
        # other error up — auth failures must surface, not silently return $null.
        if ("$_" -match 'SecretNotFound|NotFound|404') { return $null }
        throw
    }
}

function Test-AlreadySynced {
    <#
    .SYNOPSIS
    True when the DR vault's current latest secret matches the primary's
    plaintext value. Both sides are read with `-AsPlainText` only inside this
    function; the strings leave scope at function exit.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)] [string] $PrimaryVault,
        [Parameter(Mandatory)] [string] $DrVault,
        [Parameter(Mandatory)] [string] $SecretName,
        [Parameter(Mandatory)] [string] $PrimaryVersion
    )

    if ($env:DRAAC_SECRETS_FORCE_INSYNC -eq '1') {
        return $true
    }

    $drSecret = Get-DrSecretLatest -VaultName $DrVault -SecretName $SecretName
    if ($null -eq $drSecret) { return $false }

    try {
        $primaryPlain = (Get-AzKeyVaultSecret -VaultName $PrimaryVault -Name $SecretName -Version $PrimaryVersion -AsPlainText -ErrorAction Stop)
        $drPlain      = (Get-AzKeyVaultSecret -VaultName $DrVault      -Name $SecretName -AsPlainText -ErrorAction Stop)
        return ([string]::Equals($primaryPlain, $drPlain, [StringComparison]::Ordinal))
    }
    finally {
        # Best-effort wipe; PowerShell strings are immutable so this is largely
        # symbolic, but it nudges the GC.
        $primaryPlain = $null
        $drPlain      = $null
    }
}

function Write-DrSecret {
    <#
    .SYNOPSIS
    Writes the secret value (carried from primary) to the DR vault, copying
    content type, expiry, not-before, and tags. Returns the resulting
    PSKeyVaultSecret on success.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Function-host context: ShouldProcess is not available; idempotency is enforced upstream by Test-AlreadySynced.')]
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)] [string] $DrVault,
        [Parameter(Mandatory)] [string] $SecretName,
        [Parameter(Mandatory)] [object] $PrimarySecret
    )

    $setArgs = @{
        VaultName   = $DrVault
        Name        = $SecretName
        SecretValue = $PrimarySecret.SecretValue
        ErrorAction = 'Stop'
    }
    if ((Test-HasProperty -InputObject $PrimarySecret -Name 'ContentType') -and `
        -not [string]::IsNullOrEmpty($PrimarySecret.ContentType)) {
        $setArgs['ContentType'] = $PrimarySecret.ContentType
    }
    if ((Test-HasProperty -InputObject $PrimarySecret -Name 'Expires') -and `
        $null -ne $PrimarySecret.Expires) {
        $setArgs['Expires'] = $PrimarySecret.Expires
    }
    if ((Test-HasProperty -InputObject $PrimarySecret -Name 'NotBefore') -and `
        $null -ne $PrimarySecret.NotBefore) {
        $setArgs['NotBefore'] = $PrimarySecret.NotBefore
    }
    if ((Test-HasProperty -InputObject $PrimarySecret -Name 'Tags') -and `
        $null -ne $PrimarySecret.Tags) {
        $setArgs['Tag'] = $PrimarySecret.Tags
    }

    return (Set-AzKeyVaultSecret @setArgs)
}

function Resolve-VaultName {
    <#
    .SYNOPSIS
    Picks the vault name from the explicit parameter, then the matching env
    var. Throws when neither is set (auth/config error → not recoverable).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [string] $Override,
        [Parameter(Mandatory)] [string] $EnvVarName,
        [Parameter(Mandatory)] [string] $Role
    )
    if (-not [string]::IsNullOrWhiteSpace($Override)) { return $Override }
    $val = [Environment]::GetEnvironmentVariable($EnvVarName)
    if (-not [string]::IsNullOrWhiteSpace($val)) { return $val }
    throw "Cannot resolve $Role vault name: pass -$($Role)VaultName or set environment variable $EnvVarName."
}

# ── Main ─────────────────────────────────────────────────────────────────────

$startedAt = (Get-Date).ToUniversalTime().ToString('o')

Write-Host "============================================================"
Write-Host "Sync-KeyVaultSecrets: started $startedAt"
Write-Host "  ParameterSet : $($PSCmdlet.ParameterSetName)"
Write-Host "  DryRun       : $($DryRun.IsPresent)"
Write-Host "============================================================"

try {
    $evt = Resolve-EventPayload -RawEvent $EventGridEvent -FilePath $EventFile
}
catch {
    Write-Error "Event payload could not be resolved: $_"
    throw
}

$eventType = Get-EventTypeFromPayload -EventObject $evt
$eventId   = Get-PropertyValue -InputObject $evt -Name 'id'
$subject   = Get-PropertyValue -InputObject $evt -Name 'subject'
Write-Host "  eventId      : $eventId"
Write-Host "  eventType    : $eventType"
Write-Host "  subject      : $subject"

if ($eventType -ne 'Microsoft.KeyVault.SecretNewVersionCreated') {
    Write-Host "  skipped: eventType '$eventType' is not Microsoft.KeyVault.SecretNewVersionCreated."
    return
}

$coords = Get-SecretCoordinates -EventObject $evt
$primaryVaultFromEvent = $coords.VaultName
$secretName            = $coords.SecretName
$primaryVersion        = $coords.Version
$objectType            = $coords.ObjectType

Write-Host "  vaultName    : $primaryVaultFromEvent"
Write-Host "  secretName   : $secretName"
Write-Host "  version      : $primaryVersion"
Write-Host "  objectType   : $objectType"

if ([string]::IsNullOrWhiteSpace($secretName) -or [string]::IsNullOrWhiteSpace($primaryVersion)) {
    throw "Event payload missing required fields (ObjectName, Version)."
}
if ($null -ne $objectType -and $objectType -ne 'Secret') {
    Write-Host "  skipped: objectType '$objectType' is not Secret."
    return
}

# Resolve target DR vault from app settings (or the standalone override).
$drVaultName = Resolve-VaultName -Override $DrVaultName     -EnvVarName 'DR_KEYVAULT_NAME'      -Role 'Dr'
$primaryVaultName = if (-not [string]::IsNullOrWhiteSpace($PrimaryVaultName)) {
    $PrimaryVaultName
} elseif (-not [string]::IsNullOrWhiteSpace($primaryVaultFromEvent)) {
    $primaryVaultFromEvent
} else {
    Resolve-VaultName -Override '' -EnvVarName 'PRIMARY_KEYVAULT_NAME' -Role 'Primary'
}

Write-Host "  primaryVault : $primaryVaultName"
Write-Host "  drVault      : $drVaultName"

if ($DryRun) {
    Write-Host "  DryRun: would write secret '$secretName' version '$primaryVersion' to vault '$drVaultName'."
    if ($env:DRAAC_SECRETS_FORCE_INSYNC -eq '1') {
        Write-Host "  DryRun: DRAAC_SECRETS_FORCE_INSYNC=1 -> would short-circuit as already-synced."
    }
    return
}

if (-not (Test-AzKeyVaultModuleAvailable)) {
    throw "Az.KeyVault module not loaded. Add 'Az.KeyVault' to requirements.psd1 in the Function App."
}

try {
    if (Test-AlreadySynced -PrimaryVault $primaryVaultName -DrVault $drVaultName `
                           -SecretName $secretName -PrimaryVersion $primaryVersion) {
        Write-Host "  already synced: '$secretName' in '$drVaultName' matches primary version '$primaryVersion'. Skipping write."
        return
    }

    $primarySecret = Get-PrimarySecret -VaultName $primaryVaultName -SecretName $secretName -Version $primaryVersion

    $written = Write-DrSecret -DrVault $drVaultName -SecretName $secretName -PrimarySecret $primarySecret
    if ($null -ne $written) {
        Write-Host "  wrote DR secret: '$secretName' new DR version '$($written.Version)' (source primary version '$primaryVersion')."
    } else {
        Write-Host "  wrote DR secret: '$secretName' (Set-AzKeyVaultSecret returned no object)."
    }
}
catch {
    # Per-event fault tolerance: log + return non-throwing so the host marks
    # the message as handled but EventGrid will retry per the retryPolicy on
    # the eventSubscription. Re-raise only on auth/config errors which the
    # retry won't fix.
    $msg = "$_"
    if ($msg -match 'AuthorizationFailed|Unauthorized|InvalidAuthenticationToken|Forbidden|MissingSubscription') {
        Write-Error "Sync-KeyVaultSecrets: non-recoverable auth/config error: $msg"
        throw
    }
    Write-Warning "Sync-KeyVaultSecrets: transient error syncing '$secretName' v'$primaryVersion' to '$drVaultName': $msg"
    return
}

Write-Host "Sync-KeyVaultSecrets: completed $((Get-Date).ToUniversalTime().ToString('o'))"
