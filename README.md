# DRaaC — Disaster Recovery as Code

> A two-loop DR pipeline for Azure: every PR to `main` produces a deployable DR companion (forward loop), and a scheduled job reverse-engineers Azure Portal changes back into the repo (reverse loop).
>
> Built on PowerShell 7.2+, Bicep, Azure CLI, and GitHub Actions / Azure DevOps.

[![Pipeline Status](https://img.shields.io/badge/pipeline-pr--compliance-blue)](.github/workflows/pr-compliance.yml)
[![DR Deploy](https://img.shields.io/badge/stage--7-dr--deploy-green)](.github/workflows/dr-deploy.yml)
[![Portal Sync](https://img.shields.io/badge/stage--8-portal--sync-orange)](.github/workflows/portal-drift-sync.yml)

---

## The Two Loops

```
                ┌── FORWARD LOOP (PR → DR) ──┐
                │                            │
   Pull Request ▼                            │
   to `main`    │   1. Scan                  │
                │   2. Export                │
                │   3. Review + DR coverage  │
                │   4. Drift detection       │
                │   5. DR generation         │
                │   6. PR comment            │
                │   7. DR deploy (post-merge)│
                └────────────────────────────┘

                ┌── REVERSE LOOP (Portal → PR) ──┐
                │                                │
   Daily 02 UTC ▼                                │
                │   8. Portal-drift sync         │
                │   • detect Portal changes      │
                │   • decompile to Bicep         │
                │   • open reconciliation PR     │
                │     (or manual-queue issue)    │
                └────────────────────────────────┘

                ┌── BASELINE (slow drift) ───────┐
                │                                │
   Push → main  ▼                                │
   + daily 03   │   9. Baseline snapshot         │
                │   • full scan to blob storage  │
                │   • diff in PR comment         │
                └────────────────────────────────┘
```

## What Each Stage Does

**Forward loop:**

| # | Stage | What Happens |
|---|---|---|
| 1 | **Scan** | Queries all Azure subscriptions via Resource Graph API and exports the full resource inventory |
| 2 | **Export & Document** | Exports ARM templates per resource group; large RGs (>150 resources) use a `Resource Graph + az resource show` fan-out; unsupported resource types are surfaced for hand-authored DR |
| 3 | **Review** | Identifies IaC files changed in the PR. Compile-then-match for Bicep (`az bicep build --stdout`), ARM-JSON parsing for ARM, regex fallback for parameterised names. Match key is the `(name, type)` tuple |
| 3.5 | **DR Coverage Gate** | Every primary Bicep file under `bicep/regions/primary/` MUST have a DR companion under `bicep/regions/dr/`. Auto-generates the companion when missing; fails the PR when generation fails. Public-facing workloads (Web/AKS/AppGateway) MUST reference `bicep/modules/dr-traffic.bicep` |
| 4 | **Drift Detection** | Compares code declarations vs deployed state; updates `CONFIGURATION-DRIFT.md` |
| 5 | **DR Generation** | Transforms exported templates into DR Bicep for the secondary region. Replication wiring per resource family (SQL failover groups, Cosmos multi-region, Storage RA-GZRS, Postgres/MySQL replicas, Redis geo-replication, Key Vault sync) |
| 6 | **Report** | Posts a structured summary comment on the PR; writes a rich `$GITHUB_STEP_SUMMARY` |
| 7 | **DR Deploy** | On merge to `main`, deploys every `bicep/regions/dr/*.bicep` to its conventional resource group. Deterministic deployment names (re-runs at the same SHA are no-ops). Health probes via `Test-DRHealth.ps1` |

**Reverse loop + baseline:**

| # | Stage | What Happens |
|---|---|---|
| 8 | **Portal-drift sync** | Daily KQL query against `resourcechanges` for `clientType == "Azure Portal"`. Coalesces by resource ID, skips read-only-only changes, then per change: `az resource show` → wrap in ARM template → `az bicep decompile` → primary + DR Bicep → open PR. Dirty decompiles are routed to a manual-queue GitHub issue |
| 9 | **Baseline snapshot** | On push to `main`, snapshots `_reports/scan/` to a blob container. `Compare-AgainstBaseline.ps1` diffs against the most recent snapshot to surface "slow drift" — items that have appeared, disappeared, or genuinely changed (read-only properties ignored) |

---

## Quick Start

### Azure DevOps
```powershell
$env:ADO_ORG     = "https://dev.azure.com/your-org"
$env:ADO_PROJECT = "your-project"
$env:ADO_PAT     = "your-pat-token"
./setup.ps1
```
Then update the `azure-compliance-pipeline-secrets` variable group in the ADO Library.

### GitHub Actions
```powershell
$env:GITHUB_REPO              = "your-org/your-repo"
$env:AZURE_SUBSCRIPTION_IDS   = "sub-id-1,sub-id-2"
$env:DR_TARGET_REGION         = "northeurope"
$env:DR_VNET_ADDRESS_PREFIX   = "10.1.0.0/16"
$env:DR_SUBNET_ADDRESS_PREFIX = "10.1.0.0/24"
./setup-github.ps1
```
Creates the App Registration, configures OIDC federated credentials, assigns Azure roles, and sets all repository secrets automatically.

---

## Repository Structure

```
.
├── .github/workflows/
│   ├── pr-compliance.yml              ← Stages 1-6 + Stage 3.5 DR coverage gate
│   ├── dr-deploy.yml                  ← Stage 7: DR deploy (push to main)
│   ├── portal-drift-sync.yml          ← Stage 8: Reverse loop (cron daily)
│   └── baseline-snapshot.yml          ← Stage 9: Baseline persistence
│
├── .azure/
│   └── pipelines/pr-compliance.yml    ← Azure DevOps mirror (Stages 1-6)
│
├── bicep/
│   ├── modules/                       ← DR replication modules (R4):
│   │   ├── dr-sql.bicep                  failover groups
│   │   ├── dr-cosmos.bicep               multi-region writes
│   │   ├── dr-storage.bicep              RA-GZRS / cross-region restore
│   │   ├── dr-keyvault.bicep             soft-delete + purge protection
│   │   ├── dr-postgres.bicep             read replica
│   │   ├── dr-mysql.bicep                read replica
│   │   ├── dr-redis.bicep                geo-replication (Premium)
│   │   ├── dr-traffic.bicep              Front Door Premium + WAF
│   │   ├── dr-keyvault-sync.bicep        Function-based KV secret sync
│   │   └── dr-keyvault-sync-drrole.bicep cross-RG role assignment
│   └── regions/
│       ├── primary/                   ← per-workload primary Bicep (gated by Stage 3.5)
│       └── dr/                        ← per-workload DR Bicep (deployed by Stage 7)
│
├── scripts/
│   ├── scan/
│   │   ├── scan-subscriptions.ps1     ← Stage 1: Resource Graph scan
│   │   └── Compare-AgainstBaseline.ps1← Stage 9b: slow-drift diff
│   ├── export/
│   │   ├── export-arm-templates.ps1   ← Stage 2a: ARM export + unsupported-types
│   │   ├── Export-LargeResourceGroup.ps1 ← Stage 2a fallback for >150-resource RGs
│   │   └── generate-env-docs.ps1      ← Stage 2b: ENVIRONMENT.md
│   ├── review/
│   │   ├── identify-pr-changes.ps1    ← Stage 3a: git diff
│   │   ├── match-code-to-deployed.ps1 ← Stage 3b: compile-then-match (Bicep)
│   │   └── check-dr-coverage.ps1      ← Stage 3.5: DR coverage gate + traffic enforcement
│   ├── drift/
│   │   ├── detect-drift.ps1           ← Stage 4a: tuple-keyed drift
│   │   ├── update-drift-readme.ps1    ← Stage 4b: CONFIGURATION-DRIFT.md
│   │   └── commit-drift-readme.ps1    ← Stage 4c: git commit (uses lib/CommitBack.psm1)
│   ├── dr/
│   │   ├── generate-dr-config.ps1     ← Stage 5a: DR template generation
│   │   ├── validate-dr-config.ps1     ← Stage 5b: DR what-if
│   │   ├── deploy-dr-region.ps1       ← Stage 7: DR deployment
│   │   ├── Test-DRHealth.ps1          ← Per-family DR health probes
│   │   ├── Test-SkuAvailability.ps1   ← Pre-deploy: SKU availability in DR region
│   │   └── Test-ApiVersionCompatibility.ps1 ← Pre-deploy: API-version compat
│   ├── sync/                          ← Stage 8 reverse loop:
│   │   ├── Find-PortalChanges.ps1
│   │   ├── Sync-PortalChange.ps1
│   │   └── Send-ToManualQueue.ps1
│   ├── secrets/
│   │   └── Sync-KeyVaultSecrets.ps1   ← Function App run.ps1 (R4.4)
│   ├── lib/                           ← Shared modules:
│   │   ├── ConvertForDR.psm1             pure-function DR transform
│   │   └── CommitBack.psm1               git auth + retry push
│   └── report/
│       ├── post-pr-comment.ps1        ← Stage 6: PR comment (ADO)
│       ├── post-pr-comment-github.ps1 ← Stage 6: PR comment (GitHub)
│       └── write-job-summary.ps1      ← Stage 6: $GITHUB_STEP_SUMMARY
│
├── data/                              ← Behaviour-driving JSON:
│   ├── reserved-names.json               B1: subnet/resource allowlist
│   ├── readonly-properties.json          B4: read-only property strip list
│   ├── dr-module-registry.json           R4.1: type → DR module dispatch
│   └── unsupported-types.json            R5.2: never-export / partial-export rules
│
├── tests/
│   ├── Invoke-Validation.ps1          ← Single-entry test runner
│   ├── bicep-build-all.ps1            ← Bicep compile gate
│   ├── round-1/ ... round-5/          ← Per-round test suites
│   └── fixtures/                      ← Synthesised + DryRun fixtures
│
├── docs/
│   ├── ARCHITECTURE.md                ← Architecture, API versions, file inventory per round
│   ├── DOCUMENTATION.md               ← Operator-facing setup + troubleshooting
│   └── IMPLEMENTATION-LOG.md          ← Round-by-round change log
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
