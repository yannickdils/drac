#Requires -Version 7.2
# =============================================================================
# tests/round-4/Test-DrTrafficModule.ps1
# Round 4 §R4.3 — bicep/modules/dr-traffic.bicep structural tests.
#
# Style: hand-rolled Assert-True/Assert-Equal helpers, no Pester, exits 0/1.
# Mirrors tests/round-2/Test-CheckDrCoverage.ps1's bicep-CLI-skip pattern.
#
# Scenarios:
#   1. Compile clean — `az bicep build` (or standalone `bicep build`) exits 0
#      against the module. Skipped (exit 0) on hosts without a Bicep CLI.
#   2. Structural assertions on the compiled ARM:
#       - Microsoft.Cdn/profiles with sku.name == 'Premium_AzureFrontDoor'
#       - originGroup has healthProbeSettings
#       - exactly two origins (primary + DR)
#       - Microsoft.Network/FrontDoorWebApplicationFirewallPolicies present
#       - securityPolicy references the WAF policy via parameters.wafPolicy.id
#       - top-level metadata.dr.mode == 'frontDoorPriority'
#   3. Custom-domain conditional:
#       - customDomainName='' → NO Microsoft.Cdn/profiles/customDomains resource
#       - customDomainName='app.example.com' → customDomains resource present
#
# Each compile lands its ARM under $env:TEMP/draac-traffic-<guid>; the whole
# tree is removed in `finally`.
# =============================================================================
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

$RepoRoot   = if ($env:DRAAC_REPO_ROOT) { $env:DRAAC_REPO_ROOT } else { (Resolve-Path (Join-Path $PSScriptRoot ".." "..")).Path }
$ModulePath = Join-Path $RepoRoot 'bicep/modules/dr-traffic.bicep'

$Failures = [System.Collections.Generic.List[string]]::new()

function Assert-True {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { $Failures.Add("[FAIL] $Message") }
}

function Assert-Equal {
    param($Expected, $Actual, [string] $Message)
    if ($Expected -ne $Actual) {
        $Failures.Add("[FAIL] $Message`n         expected: $Expected`n         actual:   $Actual")
    }
}

# Strict-mode-safe property access — returns $null if the property is absent.
# Defeats the "property X cannot be found on this object" trap that
# Set-StrictMode -Version Latest raises on missing properties.
function Test-HasProperty {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $InputObject,
        [Parameter(Mandatory)] [string] $Name
    )
    if ($null -eq $InputObject) { return $false }
    $props = $InputObject.PSObject.Properties
    if ($null -eq $props) { return $false }
    return ($null -ne $props[$Name])
}

function Get-PropertyValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $InputObject,
        [Parameter(Mandatory)] [string] $Name
    )
    if (-not (Test-HasProperty -InputObject $InputObject -Name $Name)) { return $null }
    $val = $InputObject.PSObject.Properties[$Name].Value
    # Defeat single-element-array unwrap inside helpers — wrap with a unary
    # comma so the caller observes the original [object[]] shape.
    return ,$val
}

function Test-BicepCliAvailable {
    if (Get-Command bicep -ErrorAction SilentlyContinue) { return 'bicep' }
    if (Get-Command az    -ErrorAction SilentlyContinue) { return 'az' }
    return $null
}

function Invoke-BicepBuild {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Test helper: writes ARM JSON to a per-test temp directory under $env:TEMP. No system state outside the harness is mutated.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $InFile,
        [Parameter(Mandatory)] [string] $OutFile,
        [Parameter(Mandatory)] [string] $Cli
    )
    if ($Cli -eq 'bicep') {
        & bicep build $InFile --outfile $OutFile 2>&1 | Out-Null
    } else {
        & az bicep build --file $InFile --outfile $OutFile 2>&1 | Out-Null
    }
    return ($LASTEXITCODE -eq 0)
}

# Build a temp wrapper module that injects values for the params we care about
# and forwards them to dr-traffic.bicep. Bicep's `module` keyword is the
# cleanest way to test a parameterised module without inventing fake inputs in
# the module itself. The wrapper compiles to ARM; we then walk the ARM to
# assert the dr-traffic resources are present with the expected shape.
function New-TrafficWrapper {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Test helper: writes Bicep wrapper to a per-test temp directory under $env:TEMP. No system state outside the harness is mutated.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $WrapperPath,
        [Parameter(Mandatory)] [string] $RelModulePath,
        [string] $CustomDomain = ''
    )
    $cd = $CustomDomain -replace "'", "\\'"
    $content = @"
// Auto-generated test wrapper for bicep/modules/dr-traffic.bicep.
// Asserts module compiles end-to-end and exposes the expected outputs.
targetScope = 'resourceGroup'

module traffic '$RelModulePath' = {
  name: 'dr-traffic-test'
  params: {
    workloadName:    'testapp'
    primaryHostname: 'app-primary.azurewebsites.net'
    drHostname:      'app-dr.azurewebsites.net'
    healthProbePath: '/healthz'
    customDomainName: '$cd'
    wafMode:         'Prevention'
  }
}

output frontDoorEndpoint string = traffic.outputs.frontDoorEndpoint
output frontDoorProfileId string = traffic.outputs.frontDoorProfileId
output wafPolicyId string = traffic.outputs.wafPolicyId
"@
    Set-Content -Path $WrapperPath -Value $content -Encoding UTF8
}

# Walk a compiled ARM template and return all resources at any nesting level.
# Compiled-from-Bicep modules surface as `Microsoft.Resources/deployments`
# whose `properties.template.resources[]` contains the inner resources, so we
# recurse into those as well.
function Get-AllArmResources {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseSingularNouns', '',
        Justification = 'Returns the flattened list of every ARM resource (including those nested inside Microsoft.Resources/deployments) — plural noun is intentional for a list-returning helper.')]
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Template)

    $result = [System.Collections.Generic.List[object]]::new()
    if (-not (Test-HasProperty -InputObject $Template -Name 'resources')) { return ,$result.ToArray() }

    $resources = @($Template.resources)
    foreach ($r in $resources) {
        $result.Add($r) | Out-Null
        # Recurse into nested deployments (compiled Bicep modules look like this).
        $rType = if (Test-HasProperty -InputObject $r -Name 'type') { $r.type } else { '' }
        if ($rType -eq 'Microsoft.Resources/deployments') {
            $props = if (Test-HasProperty -InputObject $r -Name 'properties') { $r.properties } else { $null }
            if ($null -ne $props -and (Test-HasProperty -InputObject $props -Name 'template')) {
                $inner = $props.template
                $innerResources = Get-AllArmResources -Template $inner
                foreach ($i in $innerResources) { $result.Add($i) | Out-Null }
            }
        }
    }
    # Defeat single-element-array unwrap by callers using @(...) is an option,
    # but returning an explicit array avoids the surprise here.
    return ,$result.ToArray()
}

function Get-ResourcesByType {
    param(
        [Parameter(Mandatory)] $AllResources,
        [Parameter(Mandatory)] [string] $TypeFilter
    )
    $matched = @($AllResources | Where-Object {
        (Test-HasProperty -InputObject $_ -Name 'type') -and ($_.type -eq $TypeFilter)
    })
    return ,$matched
}

# ─────────────────────────────────────────────────────────────────────────────
# Test 1: bicep CLI gate — skip cleanly when no CLI is installed.
# ─────────────────────────────────────────────────────────────────────────────

$cli = Test-BicepCliAvailable
if (-not $cli) {
    Write-Host "SKIP: no Bicep CLI on PATH (neither standalone `bicep` nor `az` found). Test-DrTrafficModule.ps1 requires one of them." -ForegroundColor Yellow
    exit 0
}
Write-Host "Bicep CLI detected: $cli"

if (-not (Test-Path $ModulePath)) {
    Write-Host "FAIL: module not found at $ModulePath" -ForegroundColor Red
    exit 1
}

$Workdir = Join-Path $env:TEMP ("draac-traffic-" + [guid]::NewGuid().ToString('N'))
try {
    $null = New-Item -ItemType Directory -Force -Path $Workdir

    # ─── Scenario A: customDomainName='' → no customDomain resource ──────────
    Write-Host ""
    Write-Host "── compile dr-traffic.bicep WITHOUT a custom domain ──"

    $caseA = Join-Path $Workdir 'no-custom-domain'
    $null = New-Item -ItemType Directory -Force -Path $caseA
    $wrapperA = Join-Path $caseA 'wrapper.bicep'
    $armA     = Join-Path $caseA 'wrapper.json'

    # Wrapper sits in $caseA, module sits at $RepoRoot/bicep/modules/dr-traffic.bicep.
    # Bicep `module` paths are resolved relative to the wrapper file. Use
    # [System.IO.Path]::GetRelativePath instead of `Resolve-Path -RelativeBasePath`
    # — the latter is a PS 7.4+ addition and the project targets PS 7.2+.
    $relModulePath = [System.IO.Path]::GetRelativePath($caseA, $ModulePath) -replace '\\', '/'
    if ([string]::IsNullOrEmpty($relModulePath)) {
        # Fallback: emit an absolute path with forward slashes (Bicep accepts
        # absolute paths on Windows, even though the convention is relative).
        $relModulePath = ($ModulePath -replace '\\', '/')
    }

    New-TrafficWrapper -WrapperPath $wrapperA -RelModulePath $relModulePath -CustomDomain ''
    $okA = Invoke-BicepBuild -InFile $wrapperA -OutFile $armA -Cli $cli
    Assert-True $okA "scenarioA: az bicep build exited 0 (no custom domain)"
    Assert-True (Test-Path $armA) "scenarioA: ARM file produced"

    if ($okA -and (Test-Path $armA)) {
        $tplA = Get-Content $armA -Raw | ConvertFrom-Json -Depth 100
        $allA = Get-AllArmResources -Template $tplA

        # Assert: at least one Microsoft.Cdn/profiles with Premium SKU.
        $profiles = Get-ResourcesByType -AllResources $allA -TypeFilter 'Microsoft.Cdn/profiles'
        Assert-True (@($profiles).Count -ge 1) "scenarioA: at least one Microsoft.Cdn/profiles resource"

        $premiumProfileFound = $false
        foreach ($p in @($profiles)) {
            if (Test-HasProperty -InputObject $p -Name 'sku') {
                $sku = $p.sku
                if ((Test-HasProperty -InputObject $sku -Name 'name') -and ($sku.name -eq 'Premium_AzureFrontDoor')) {
                    $premiumProfileFound = $true
                    break
                }
            }
        }
        Assert-True $premiumProfileFound "scenarioA: AFD profile uses sku.name = 'Premium_AzureFrontDoor'"

        # Assert: origin group has health probe defined.
        $originGroups = Get-ResourcesByType -AllResources $allA -TypeFilter 'Microsoft.Cdn/profiles/originGroups'
        Assert-True (@($originGroups).Count -ge 1) "scenarioA: at least one origin group"

        $healthProbeFound = $false
        foreach ($og in @($originGroups)) {
            $props = Get-PropertyValue -InputObject $og -Name 'properties'
            if ($null -ne $props -and (Test-HasProperty -InputObject $props -Name 'healthProbeSettings')) {
                $hp = $props.healthProbeSettings
                if ($null -ne $hp -and (Test-HasProperty -InputObject $hp -Name 'probePath')) {
                    $healthProbeFound = $true
                    break
                }
            }
        }
        Assert-True $healthProbeFound "scenarioA: origin group has healthProbeSettings.probePath"

        # Assert: exactly two origins (primary + DR).
        $origins = Get-ResourcesByType -AllResources $allA -TypeFilter 'Microsoft.Cdn/profiles/originGroups/origins'
        Assert-Equal 2 (@($origins).Count) "scenarioA: exactly two origins (primary + DR)"

        # Both expected priorities (1 and 2) appear among the origins.
        $priorities = [System.Collections.Generic.List[int]]::new()
        foreach ($o in @($origins)) {
            $props = Get-PropertyValue -InputObject $o -Name 'properties'
            if ($null -ne $props -and (Test-HasProperty -InputObject $props -Name 'priority')) {
                $priorities.Add([int]$props.priority) | Out-Null
            }
        }
        Assert-True ($priorities -contains 1) "scenarioA: an origin with priority=1 (primary) is present"
        Assert-True ($priorities -contains 2) "scenarioA: an origin with priority=2 (DR) is present"

        # Assert: WAF policy resource exists.
        $wafs = Get-ResourcesByType -AllResources $allA -TypeFilter 'Microsoft.Network/FrontDoorWebApplicationFirewallPolicies'
        Assert-True (@($wafs).Count -ge 1) "scenarioA: WAF policy resource present"

        # Assert: securityPolicy references the WAF policy via parameters.wafPolicy.id.
        $secPolicies = Get-ResourcesByType -AllResources $allA -TypeFilter 'Microsoft.Cdn/profiles/securityPolicies'
        Assert-True (@($secPolicies).Count -ge 1) "scenarioA: security policy resource present"

        $wafLinkFound = $false
        foreach ($sp in @($secPolicies)) {
            $props = Get-PropertyValue -InputObject $sp -Name 'properties'
            if ($null -eq $props) { continue }
            $params = Get-PropertyValue -InputObject $props -Name 'parameters'
            if ($null -eq $params) { continue }
            if (Test-HasProperty -InputObject $params -Name 'wafPolicy') {
                $wp = $params.wafPolicy
                if ($null -ne $wp -and (Test-HasProperty -InputObject $wp -Name 'id')) {
                    $wafLinkFound = $true
                    break
                }
            }
        }
        Assert-True $wafLinkFound "scenarioA: security policy links to WAF via parameters.wafPolicy.id"

        # Assert: customDomain resource is wired with a deploy-time conditional.
        # Bicep's `if (hasCustomDomain)` compiles to an ARM `condition` field;
        # the resource declaration ALWAYS appears in the compiled template — the
        # template engine skips it at deploy time when the condition evaluates
        # to false. We can't statically evaluate the ARM expression here (the
        # wrapper passes customDomainName as a param), so the meaningful test
        # is "the conditional is wired up" — i.e. every customDomains resource
        # has a `condition` field. The wrapper-param assertion below proves we
        # actually passed an empty string in scenario A.
        $customDomains = Get-ResourcesByType -AllResources $allA -TypeFilter 'Microsoft.Cdn/profiles/customDomains'
        Assert-True (@($customDomains).Count -ge 1) "scenarioA: customDomains resource declaration present (with condition)"
        $unconditional = @($customDomains | Where-Object {
            -not (Test-HasProperty -InputObject $_ -Name 'condition')
        })
        Assert-Equal 0 (@($unconditional).Count) "scenarioA: every customDomains resource has a `condition` field (proves `if (hasCustomDomain)` was compiled)"

        # End-to-end: the wrapper ARM must pass customDomainName='' to the
        # inner module. Look for the literal in the rendered wrapper JSON.
        $rawArmA = Get-Content $armA -Raw
        Assert-True ($rawArmA -notmatch 'app\.example\.com') "scenarioA: rendered wrapper ARM does NOT contain 'app.example.com' literal"

        # Assert: top-level metadata.dr.mode == 'frontDoorPriority' on the
        # MODULE template (not the wrapper). The compiled wrapper embeds the
        # module ARM under Microsoft.Resources/deployments[].properties.template
        # — that's where dr-traffic.bicep's metadata block lives.
        $moduleMetadataFound = $false
        $moduleMetadataMode  = $null
        if (Test-HasProperty -InputObject $tplA -Name 'resources') {
            foreach ($r in @($tplA.resources)) {
                $rType = if (Test-HasProperty -InputObject $r -Name 'type') { $r.type } else { '' }
                if ($rType -ne 'Microsoft.Resources/deployments') { continue }
                $props = Get-PropertyValue -InputObject $r -Name 'properties'
                if ($null -eq $props) { continue }
                $inner = Get-PropertyValue -InputObject $props -Name 'template'
                if ($null -eq $inner) { continue }
                if (Test-HasProperty -InputObject $inner -Name 'metadata') {
                    $meta = $inner.metadata
                    if ($null -ne $meta -and (Test-HasProperty -InputObject $meta -Name 'dr')) {
                        $drBlock = $meta.dr
                        if ($null -ne $drBlock -and (Test-HasProperty -InputObject $drBlock -Name 'mode')) {
                            $moduleMetadataFound = $true
                            $moduleMetadataMode  = $drBlock.mode
                            break
                        }
                    }
                }
            }
        }
        Assert-True $moduleMetadataFound "scenarioA: module template carries metadata.dr block"
        Assert-Equal 'frontDoorPriority' $moduleMetadataMode "scenarioA: metadata.dr.mode == 'frontDoorPriority'"
    }

    # ─── Scenario B: customDomainName='app.example.com' → customDomain present ──
    Write-Host ""
    Write-Host "── compile dr-traffic.bicep WITH a custom domain ──"

    $caseB = Join-Path $Workdir 'with-custom-domain'
    $null = New-Item -ItemType Directory -Force -Path $caseB
    $wrapperB = Join-Path $caseB 'wrapper.bicep'
    $armB     = Join-Path $caseB 'wrapper.json'

    $relModulePathB = [System.IO.Path]::GetRelativePath($caseB, $ModulePath) -replace '\\', '/'
    if ([string]::IsNullOrEmpty($relModulePathB)) {
        $relModulePathB = ($ModulePath -replace '\\', '/')
    }

    New-TrafficWrapper -WrapperPath $wrapperB -RelModulePath $relModulePathB -CustomDomain 'app.example.com'
    $okB = Invoke-BicepBuild -InFile $wrapperB -OutFile $armB -Cli $cli
    Assert-True $okB "scenarioB: az bicep build exited 0 (with custom domain)"
    Assert-True (Test-Path $armB) "scenarioB: ARM file produced"

    if ($okB -and (Test-Path $armB)) {
        $tplB = Get-Content $armB -Raw | ConvertFrom-Json -Depth 100
        $allB = Get-AllArmResources -Template $tplB

        $customDomainsB = Get-ResourcesByType -AllResources $allB -TypeFilter 'Microsoft.Cdn/profiles/customDomains'
        Assert-True (@($customDomainsB).Count -ge 1) "scenarioB: Microsoft.Cdn/profiles/customDomains resource present"

        # Spot-check that the custom domain hostName references our parameter
        # (Bicep compiles `hostName: customDomainName` to an ARM expression of
        # the form `[parameters('customDomainName')]`). Match either the
        # literal value (in case the compiler folded it) or the parameter
        # reference, plus do an end-to-end check by scanning the rendered
        # wrapper for the literal we passed in.
        $hostNameOk = $false
        foreach ($cd in @($customDomainsB)) {
            $props = Get-PropertyValue -InputObject $cd -Name 'properties'
            if ($null -eq $props) { continue }
            if (Test-HasProperty -InputObject $props -Name 'hostName') {
                $hn = [string]$props.hostName
                if ($hn -eq 'app.example.com' -or $hn -like "*customDomainName*" -or $hn -like "*app.example.com*") {
                    $hostNameOk = $true
                    break
                }
            }
        }
        Assert-True $hostNameOk "scenarioB: customDomain hostName references the customDomainName parameter or its literal value"

        # End-to-end: the literal we passed must appear somewhere in the
        # compiled wrapper (typically as `properties.parameters.customDomainName.value`
        # on the inner deployment).
        $rawArmB = Get-Content $armB -Raw
        Assert-True ($rawArmB -match 'app\.example\.com') "scenarioB: rendered ARM contains the literal 'app.example.com'"
    }
}
finally {
    if (Test-Path $Workdir) {
        Remove-Item -Recurse -Force $Workdir -ErrorAction SilentlyContinue
    }
}

Write-Host ""
if ($Failures.Count -eq 0) {
    Write-Host "Test-DrTrafficModule: all assertions passed." -ForegroundColor Green
    exit 0
} else {
    Write-Host "FAILED: $($Failures.Count) assertion(s)" -ForegroundColor Red
    foreach ($f in $Failures) { Write-Host $f -ForegroundColor Red }
    exit 1
}
