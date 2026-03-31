# Azure DevOps PR Compliance Pipeline

> Validates that every code change merged to `main` has been deployed to Azure.  
> Detects configuration drift, exports environment state, and generates DR-ready infrastructure templates.

[![Pipeline Status](https://img.shields.io/badge/pipeline-pr--compliance-blue)](/.azure/pipelines/pr-compliance.yml)

---

## What This Does

On every **Pull Request to `main`**, this pipeline automatically:

| # | Stage | What Happens |
|---|---|---|
| 1 | **Scan** | Queries all Azure subscriptions via Resource Graph API and exports the full resource inventory |
| 2 | **Export & Document** | Exports ARM templates per resource group and generates `ENVIRONMENT.md` |
| 3 | **Review** | Identifies IaC files changed in the PR and checks if those resources are deployed in Azure |
| 4 | **Drift Detection** | Compares code declarations vs deployed state; updates `CONFIGURATION-DRIFT.md` in the PR |
| 5 | **DR Generation** | Transforms exported templates into DR-ready Bicep for the secondary region |
| 6 | **Report** | Posts a structured summary comment on the PR with status badges and action items |

---

## Quick Start

### Azure DevOps
```bash
export ADO_ORG="https://dev.azure.com/your-org"
export ADO_PROJECT="your-project"
export ADO_PAT="your-pat-token"
./setup.ps1
```
Then update the `azure-compliance-pipeline-secrets` variable group in the ADO Library.

### GitHub Actions
```bash
export GITHUB_REPO="your-org/your-repo"
export AZURE_SUBSCRIPTION_IDS="sub-id-1,sub-id-2"
export DR_TARGET_REGION="northeurope"
export DR_VNET_ADDRESS_PREFIX="10.1.0.0/16"
export DR_SUBNET_ADDRESS_PREFIX="10.1.0.0/24"
./setup-github.ps1
```
Creates the App Registration, configures OIDC federated credentials, assigns Azure roles, and sets all repository secrets automatically.

---

## Repository Structure

```
.
├── .azure/
│   ├── pipelines/
│   │   └── pr-compliance.yml          ← Main pipeline definition
│   └── variable-group-template.yml    ← Variable group reference
│
├── scripts/
│   ├── scan/
│   │   └── scan-subscriptions.ps1      ← Stage 1: Resource Graph scan
│   ├── export/
│   │   ├── export-arm-templates.ps1    ← Stage 2a: ARM template export
│   │   └── generate-env-docs.ps1       ← Stage 2b: ENVIRONMENT.md generation
│   ├── review/
│   │   ├── identify-pr-changes.ps1     ← Stage 3a: Git diff analysis
│   │   └── match-code-to-deployed.ps1  ← Stage 3b: Code ↔ Azure matching
│   ├── drift/
│   │   ├── detect-drift.ps1            ← Stage 4a: Drift analysis
│   │   ├── update-drift-readme.ps1    ← Stage 4b: CONFIGURATION-DRIFT.md update
│   │   └── commit-drift-readme.ps1     ← Stage 4c: Git commit & push
│   ├── dr/
│   │   ├── generate-dr-config.ps1      ← Stage 5a: DR template generation
│   │   └── validate-dr-config.ps1      ← Stage 5b: DR what-if validation
│   └── report/
│       └── post-pr-comment.ps1        ← Stage 6: PR comment posting
│
├── docs/
│   ├── ARCHITECTURE.md                ← System architecture & API versions
│   └── DOCUMENTATION.md               ← Full user documentation
│
├── CONFIGURATION-DRIFT.md             ← Auto-updated drift log (committed by pipeline)
├── setup.ps1                           ← Bootstrap script
└── README.md                          ← This file
```

---

## API Versions

| Azure Service | API Version |
|---|---|
| Azure Resource Graph | `2024-04-01` |
| Azure Resource Manager | `2021-04-01` |
| Azure DevOps REST API | `7.1` |

---

## PR Comment Example

When the pipeline runs, it posts a comment like this on your PR:

```
## 🔍 Azure Compliance Pipeline Report

**Status:** 🔴 Action Required
**PR:** #42 | **Run:** `5678`

### Deployment Coverage (Code → Azure)
| IaC Files with Matched Deployments | 8   |
| IaC Files with NO Azure Match       | 2   |
| Coverage                            | 80% |

### Configuration Drift
| 🔴 Critical Items | 2 |
| 🟡 Warnings       | 5 |

### Required Actions
- 🚨 2 critical drift item(s) detected. Deploy before merging.
```

---

## Configuration

See [docs/DOCUMENTATION.md](docs/DOCUMENTATION.md) for full configuration reference.

### Azure DevOps — Variable Group `azure-compliance-pipeline-secrets`

| Variable | Description |
|---|---|
| `AZURE_SERVICE_CONNECTION` | ADO service connection name |
| `AZURE_SUBSCRIPTION_IDS` | Comma-separated IDs or `ALL` |
| `MANAGEMENT_GROUP_ID` | Management group (overrides subscriptions) |
| `drTargetRegion` | DR target region (e.g. `northeurope`) |
| `drVnetAddressPrefix` | DR VNet CIDR (e.g. `10.1.0.0/16`) |
| `drSubnetAddressPrefix` | DR subnet CIDR (e.g. `10.1.0.0/24`) |

### GitHub Actions — Repository Secrets

| Secret | Description |
|---|---|
| `AZURE_CLIENT_ID` | App Registration client ID (set by `setup-github.ps1`) |
| `AZURE_TENANT_ID` | Azure AD tenant ID |
| `AZURE_SUBSCRIPTION_ID` | Primary subscription for CLI context |
| `AZURE_SUBSCRIPTION_IDS` | Comma-separated IDs or `ALL` |
| `DR_TARGET_REGION` | DR target region (e.g. `northeurope`) |
| `DR_VNET_ADDRESS_PREFIX` | DR VNet CIDR (e.g. `10.1.0.0/16`) |
| `DR_SUBNET_ADDRESS_PREFIX` | DR subnet CIDR (e.g. `10.1.0.0/24`) |

### Platform Comparison

| Concern | Azure DevOps | GitHub Actions |
|---|---|---|
| Trigger file | `.azure/pipelines/pr-compliance.yml` | `.github/workflows/pr-compliance.yml` |
| Authentication | Service Connection (SP or OIDC) | `azure/login@v2` with OIDC |
| Azure CLI task | `AzureCLI@2` | `azure/cli@v2` |
| PowerShell task | `PowerShell@2` | `pwsh` inline step |
| PR comment | ADO REST API v7.1 | `gh` CLI + GitHub REST API |
| Secrets store | ADO Variable Groups (Library) | GitHub Repository Secrets |
| Artifacts | ADO Pipeline Artifacts | `actions/upload-artifact@v4` |
| Job summary | — | `$GITHUB_STEP_SUMMARY` |
| Shared scripts | ✅ All bash + PowerShell scripts | ✅ Same scripts, zero changes |

---

## Required Permissions

### Azure (both platforms)

| Scope | Role |
|---|---|
| Subscriptions (primary) | `Reader` |
| Subscriptions (DR) | `Contributor` (for what-if validation) |

### Azure DevOps

| Resource | Permission |
|---|---|
| ADO Repository | `Contribute` |
| ADO Pull Requests | `Contribute to pull requests` |

### GitHub Actions

| Permission | Why |
|---|---|
| `id-token: write` | OIDC token exchange with Azure |
| `contents: write` | Commit `CONFIGURATION-DRIFT.md` to PR branch |
| `pull-requests: write` | Post PR comment |

---

## Links

- [Architecture](docs/ARCHITECTURE.md)
- [Full Documentation](docs/DOCUMENTATION.md)
- [Configuration Drift Log](CONFIGURATION-DRIFT.md)
- [Azure Resource Graph Docs](https://learn.microsoft.com/en-us/azure/governance/resource-graph/)
- [ARM Template Export Docs](https://learn.microsoft.com/en-us/azure/azure-resource-manager/templates/export-template-cli)
- [GitHub Actions azure/login@v2](https://github.com/Azure/login)
- [Configuring OIDC for GitHub + Azure](https://learn.microsoft.com/en-us/azure/developer/github/connect-from-azure-oidc)
