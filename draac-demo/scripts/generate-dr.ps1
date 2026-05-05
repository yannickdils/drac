#Requires -Version 7.2
<#
.SYNOPSIS
    Generates main.dr.bicep from main.bicep by transforming for the DR region.
.DESCRIPTION
    Demo-grade DR generator. Three transformations only:
      1. Default location: westeurope -> northeurope
      2. Resource name prefix: <name> -> dr<name>
      3. Tag draac-role: primary -> dr
    Idempotent: same input always produces same output.
#>
[CmdletBinding()]
param(
    [string] $InputPath  = 'bicep/main.bicep',
    [string] $OutputPath = 'bicep/main.dr.bicep'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Test-Path $InputPath)) {
    Write-Error "Input file not found: $InputPath"
    exit 1
}

$content = Get-Content $InputPath -Raw

# Transformation 1: location default
$content = $content -replace "param location string = 'westeurope'", "param location string = 'northeurope'"
$content = $content -replace "@description\('Primary region\. Hardcoded for demo simplicity\.'\)", "@description('DR region. Hardcoded for demo simplicity.')"

# Transformation 2: storage account name (only the literal in name: 'stdraacdemo...')
$content = $content -replace "name: 'stdraacdemo\$\{nameSuffix\}'", "name: 'drstdraacdemo`${nameSuffix}'"

# Transformation 3: role tag
$content = $content -replace "'draac-role': 'primary'", "'draac-role': 'dr'"

# Header comment update
$content = $content -replace "// Primary region Storage Account for DRaaC demo\.", "// DR region Storage Account for DRaaC demo. AUTO-GENERATED from main.bicep."

Set-Content -Path $OutputPath -Value $content -Encoding UTF8 -NoNewline

Write-Host "Generated DR Bicep: $OutputPath"
Write-Host "  Source:      $InputPath"
Write-Host "  DR region:   northeurope"
Write-Host "  Name prefix: dr"
