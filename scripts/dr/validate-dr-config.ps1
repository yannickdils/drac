# =============================================================================
# validate-dr-config.ps1
# Stage 5b: Validate generated DR templates using az deployment group validate.
# Non-fatal: validation failures are reported but do not block the pipeline.
# Idempotent: what-if / validate is always read-only.
# =============================================================================
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $DrDir,
    [Parameter(Mandatory)] [string] $DrRegion,
    [Parameter(Mandatory)] [string] $RunId
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

$Timestamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
$Results   = [System.Collections.Generic.List[object]]::new()
$Pass      = 0
$Fail      = 0

Write-Host "============================================================"
Write-Host "STAGE 5b: Validate DR Configuration (what-if)"
Write-Host "  DR Region: $DrRegion   Run ID: $RunId"
Write-Host "============================================================"

Get-ChildItem -Path $DrDir -Recurse -Filter "dr-metadata.json" | ForEach-Object {
    $Meta    = Get-Content $_.FullName -Raw | ConvertFrom-Json
    $SubId   = $Meta.subscriptionId
    $DrRg    = $Meta.drResourceGroup
    $BaseDir = Split-Path $_.FullName
    $TplFile = Join-Path $BaseDir "template.json"
    $ParFile = Join-Path $BaseDir "parameters.json"

    if (-not (Test-Path $TplFile)) { return }

    Write-Host "  Validating: $DrRg (sub: $SubId)"

    $Output = az deployment group validate `
        --resource-group $DrRg `
        --template-file  $TplFile `
        --parameters     $ParFile `
        --subscription   $SubId `
        --output json 2>&1

    $ParsedOutput = $Output | ConvertFrom-Json -ErrorAction SilentlyContinue
    $State        = $ParsedOutput.properties.provisioningState ?? "Failed"

    if ($State -in @("Succeeded","Accepted")) {
        $Pass++
        $Results.Add([ordered]@{ resourceGroup = $DrRg; status = "valid"; error = $null })
    } else {
        $Fail++
        $ErrMsg = $ParsedOutput.error.message ?? ($Output | Select-Object -Last 1)
        $Results.Add([ordered]@{ resourceGroup = $DrRg; status = "invalid"; error = $ErrMsg })
        Write-Warning "  Validation failed for $DrRg`: $ErrMsg"
    }
}

[ordered]@{
    runId             = $RunId
    timestamp         = $Timestamp
    validationSummary = [ordered]@{ passed = $Pass; failed = $Fail }
    results           = $Results
} | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $DrDir "dr-validation-report.json") -Encoding UTF8

Write-Host ""
Write-Host "DR VALIDATION COMPLETE  Passed: $Pass  Failed: $Fail (non-fatal)"
