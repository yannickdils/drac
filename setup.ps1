#Requires -Version 7.2
# =============================================================================
# setup.ps1
# Bootstrap script: creates the ADO variable group and registers the pipeline
# using the Azure DevOps REST API (v7.1).
#
# Usage:
#   $env:ADO_ORG     = "https://dev.azure.com/my-org"
#   $env:ADO_PROJECT = "my-project"
#   $env:ADO_PAT     = "<personal-access-token>"
#   ./setup.ps1
#
# The PAT needs: Variable Groups (Read & Manage), Build (Read & Execute)
# =============================================================================
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$AdoOrg     = $env:ADO_ORG     ?? (Read-Host "ADO_ORG (e.g. https://dev.azure.com/my-org)")
$AdoProject = $env:ADO_PROJECT ?? (Read-Host "ADO_PROJECT")
$AdoPat     = $env:ADO_PAT     ?? (Read-Host "ADO_PAT" -AsSecureString | ConvertFrom-SecureString -AsPlainText)

$AdoApiVersion = "7.1"
$AdoOrg        = $AdoOrg.TrimEnd('/')
$Bytes         = [System.Text.Encoding]::ASCII.GetBytes(":$AdoPat")
$EncodedPat    = [Convert]::ToBase64String($Bytes)
$Headers       = @{
    Authorization  = "Basic $EncodedPat"
    "Content-Type" = "application/json"
}
$ProjectEnc = [Uri]::EscapeDataString($AdoProject)

Write-Host "========================================================"
Write-Host "DRaaC Pipeline — Azure DevOps Bootstrap Setup"
Write-Host "  Org:     $AdoOrg"
Write-Host "  Project: $AdoProject"
Write-Host "========================================================"

# ── 1. Create variable group ──────────────────────────────────────────────────
Write-Host ""
Write-Host "Step 1: Creating variable group 'azure-compliance-pipeline-secrets'..."

$vgPayload = @{
    name = "azure-compliance-pipeline-secrets"
    type = "Vsts"
    variables = @{
        AZURE_SERVICE_CONNECTION = @{ value = "REPLACE_ME"; isSecret = $false }
        AZURE_TENANT_ID          = @{ value = "REPLACE_ME"; isSecret = $false }
        AZURE_SUBSCRIPTION_IDS   = @{ value = "ALL";        isSecret = $false }
        MANAGEMENT_GROUP_ID      = @{ value = "none";       isSecret = $false }
        drTargetRegion           = @{ value = "northeurope";isSecret = $false }
        drVnetAddressPrefix      = @{ value = "10.1.0.0/16";isSecret = $false }
        drSubnetAddressPrefix    = @{ value = "10.1.0.0/24";isSecret = $false }
        drNamingPrefix           = @{ value = "dr-";        isSecret = $false }
    }
} | ConvertTo-Json -Depth 5

$vgUri = "$AdoOrg/$ProjectEnc/_apis/distributedtask/variablegroups?api-version=$AdoApiVersion"
$vgId  = $null

try {
    $vgResponse = Invoke-RestMethod -Uri $vgUri -Method Post -Headers $Headers -Body $vgPayload
    $vgId = $vgResponse.id
    Write-Host "  ✅ Variable group created with ID: $vgId"
} catch {
    Write-Warning "Variable group may already exist or creation failed: $_"

    # Try to fetch existing
    try {
        $existing = Invoke-RestMethod `
            -Uri "$AdoOrg/$ProjectEnc/_apis/distributedtask/variablegroups?groupName=azure-compliance-pipeline-secrets&api-version=$AdoApiVersion" `
            -Headers $Headers
        if ($existing.count -gt 0) {
            $vgId = $existing.value[0].id
            Write-Host "  Existing variable group ID: $vgId"
        }
    } catch {
        Write-Warning "Could not retrieve existing variable group: $_"
    }
}

Write-Host ""
Write-Host "  ⚠️  ACTION REQUIRED: Update these variables in the ADO Library:"
Write-Host "     AZURE_SERVICE_CONNECTION → your ADO service connection name"
Write-Host "     AZURE_TENANT_ID          → your Azure tenant ID"
Write-Host "     AZURE_SUBSCRIPTION_IDS   → comma-separated IDs or ALL"
Write-Host "     drTargetRegion           → DR target region"
Write-Host "     drVnetAddressPrefix      → DR VNet CIDR"
Write-Host "     drSubnetAddressPrefix    → DR subnet CIDR"
Write-Host ""
Write-Host "     URL: $AdoOrg/$AdoProject/_library?itemType=VariableGroups"

# ── 2. Get repository ID ──────────────────────────────────────────────────────
Write-Host ""
Write-Host "Step 2: Fetching repository ID..."

$reposUri  = "$AdoOrg/$ProjectEnc/_apis/git/repositories?api-version=$AdoApiVersion"
$repos     = Invoke-RestMethod -Uri $reposUri -Headers $Headers
$repoCount = $repos.count

Write-Host "  Found $repoCount repository(ies)"

$repoId   = "REPLACE_WITH_REPO_ID"
$repoName = "REPLACE_WITH_REPO_NAME"

if ($repoCount -eq 1) {
    $repoId   = $repos.value[0].id
    $repoName = $repos.value[0].name
    Write-Host "  Using repository: $repoName ($repoId)"
} else {
    Write-Host "  Multiple repos found — set REPO_NAME and re-run, or create the pipeline manually:"
    $repos.value | ForEach-Object { Write-Host "  - $($_.name)  $($_.id)" }
}

# ── 3. Create pipeline definition ─────────────────────────────────────────────
Write-Host ""
Write-Host "Step 3: Creating pipeline definition..."

$pipelinePayload = @{
    name   = "DRaaC PR Compliance — Azure Deployment Validation"
    folder = "\compliance"
    configuration = @{
        type       = "yaml"
        path       = "/.azure/pipelines/pr-compliance.yml"
        repository = @{
            id   = $repoId
            name = $repoName
            type = "azureReposGit"
        }
    }
} | ConvertTo-Json -Depth 5

$pipelineUri = "$AdoOrg/$ProjectEnc/_apis/pipelines?api-version=$AdoApiVersion"
$pipelineId  = $null

try {
    $pipelineResponse = Invoke-RestMethod -Uri $pipelineUri -Method Post -Headers $Headers -Body $pipelinePayload
    $pipelineId = $pipelineResponse.id
    Write-Host "  ✅ Pipeline created with ID: $pipelineId"
    Write-Host "  URL: $AdoOrg/$AdoProject/_build?definitionId=$pipelineId"
} catch {
    Write-Warning "Pipeline creation failed — create manually: $_"
    Write-Host "  Path: .azure/pipelines/pr-compliance.yml"
}

# ── 4. Branch policy guidance ─────────────────────────────────────────────────
Write-Host ""
Write-Host "Step 4: Branch policy setup (manual step)"
Write-Host ""
Write-Host "  To require this pipeline as a PR gate on 'main':"
Write-Host "  1. Go to: $AdoOrg/$AdoProject/_settings/repositories"
Write-Host "  2. Select your repo → Policies → Branch Policies → main"
Write-Host "  3. Add Build Validation → Select 'DRaaC PR Compliance' pipeline"
Write-Host "  4. Set to Required"
Write-Host ""
Write-Host "========================================================"
Write-Host "SETUP COMPLETE"
Write-Host ""
Write-Host "Next steps:"
Write-Host "  1. Update variable group: $AdoOrg/$AdoProject/_library?itemType=VariableGroups"
Write-Host "  2. Configure branch policy (Step 4 above)"
Write-Host "  3. Create a test PR to main to verify the pipeline runs"
Write-Host "========================================================"
