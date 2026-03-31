# Architecture: Azure DevOps PR Compliance Pipeline

> **Last Updated:** 2026-03-31  
> **API Versions:** Resource Graph `2024-04-01` · ARM `2021-04-01` · ADO REST `7.1`

---

## Overview

This pipeline runs on every Pull Request targeting `main` and enforces a governance rule:

> **Code changes must be deployed to Azure before they can be merged.**

It additionally generates disaster recovery configurations and tracks configuration drift over time.

---

## Pipeline Architecture

```
Pull Request → main
       │
       ▼
┌─────────────────────────────────────────────────────────┐
│  Stage 1: SCAN                                          │
│  ┌──────────────────────────────────────────────────┐  │
│  │  Azure Resource Graph API (2024-04-01)            │  │
│  │  • All subscriptions / management group           │  │
│  │  • VNets, NSGs, Compute, Storage, RBAC, Policy    │  │
│  │  • Paginated (1000/page, skip-token cursor)        │  │
│  └──────────────────────────────────────────────────┘  │
└──────────────────┬──────────────────────────────────────┘
                   │ scan-results artifact
                   ▼
┌─────────────────────────────────────────────────────────┐
│  Stage 2: EXPORT & DOCUMENT                             │
│  ┌──────────────────────────────────────────────────┐  │
│  │  ARM Export REST API (2021-04-01)                 │  │
│  │  • Per resource group: POST /exportTemplate       │  │
│  │  • ARM JSON → Bicep decompile                     │  │
│  │  • Generates ENVIRONMENT.md                        │  │
│  └──────────────────────────────────────────────────┘  │
└──────────────────┬──────────────────────────────────────┘
                   │ export-results + env-docs artifacts
         ┌─────────┴──────────┐
         ▼                    ▼
┌────────────────┐   ┌─────────────────────────────────────┐
│  Stage 3:      │   │  Stage 5: DR GENERATION             │
│  CODE REVIEW   │   │  • ARM template transformation       │
│  • git diff    │   │  • Location → DR region             │
│  • IaC parse   │   │  • VNet address space rewrite        │
│  • Name match  │   │  • Naming prefix applied            │
│  vs scan data  │   │  • Bicep generated                  │
└────────┬───────┘   │  • what-if validation               │
         │           └─────────────────────────────────────┘
         ▼
┌─────────────────────────────────────────────────────────┐
│  Stage 4: DRIFT DETECTION                               │
│  ┌──────────────────────────────────────────────────┐  │
│  │  • Deployed ∩ Code (matched)                      │  │
│  │  • Deployed ∖ Code (manual resources)             │  │
│  │  • Code ∖ Deployed (missing deployments) ← BLOCK │  │
│  │  • PR changed files ∖ deployed (← BLOCK)         │  │
│  │  Updates CONFIGURATION-DRIFT.md                   │  │
│  │  Commits back to PR branch                        │  │
│  └──────────────────────────────────────────────────┘  │
└──────────────────┬──────────────────────────────────────┘
                   │
                   ▼
┌─────────────────────────────────────────────────────────┐
│  Stage 6: FINAL REPORT                                  │
│  ┌──────────────────────────────────────────────────┐  │
│  │  ADO REST API v7.1                                │  │
│  │  • POST/PATCH PR thread comment                   │  │
│  │  • Sets pipeline variables (gate support)         │  │
│  │  • Publishes all artifacts                        │  │
│  └──────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────┘
```

---

## Stage Detail

### Stage 1 — Scan (`scan-subscriptions.ps1`)

| Item | Detail |
|---|---|
| API | `POST https://management.azure.com/providers/Microsoft.ResourceGraph/resources?api-version=2024-04-01` |
| Scope | All subscriptions the service principal can access, or a specific management group |
| Pagination | Skip-token cursor, 1000 records/page |
| Data collected | All resources, VNets, NSGs, Compute, Storage/DB, Security, RBAC, Policy, Resource Groups |
| Output | `scan-results/` artifact containing 10 categorised JSON files |

**Resource Graph query scope logic:**
```
IF management_group is set → managementGroups: [mgmt-group-id]
ELIF subscription_ids = "ALL" → fetch all enabled subscriptions
ELSE → subscriptions: [comma-separated list]
```

### Stage 2 — Export (`export-arm-templates.ps1` + `generate-env-docs.ps1`)

| Item | Detail |
|---|---|
| API | `POST .../resourcegroups/{rg}/exportTemplate?api-version=2021-04-01` |
| Options | `IncludeParameterDefaultValue,IncludeComments,SkipResourceNameParameterization` |
| Decompile | `az bicep decompile` (best-effort, non-fatal) |
| Idempotency | Skips already-exported resource groups in the same run |
| Output | `export-results/arm-templates/`, `export-results/bicep-templates/`, `env-docs/ENVIRONMENT.md` |

### Stage 3 — Review (`identify-pr-changes.ps1` + `match-code-to-deployed.ps1`)

| Item | Detail |
|---|---|
| Diff source | `git diff origin/main...HEAD` (full history checkout) |
| IaC types | `.bicep`, `.tf`, ARM `.json`, K8s manifests, Helm |
| Matching | Case-insensitive resource name lookup in scan JSON |
| Output | `review-results/deployment-match-report.json` |

**File categorisation:**
- Bicep → `grep` for `name:` properties
- Terraform → `grep` for `name =` assignments
- ARM JSON → `jq` `.resources[].name`

### Stage 4 — Drift (`detect-drift.ps1` + `update-drift-readme.ps1` + `commit-drift-readme.ps1`)

| Drift Type | Severity | Action |
|---|---|---|
| `in-code-not-deployed` | 🔴 Critical | Block merge recommendation |
| `pr-change-not-deployed` | 🔴 Critical | Block merge recommendation |
| `partial-deployment` | 🔴 Critical | Block merge recommendation |
| `deployed-not-in-code` | 🟡 Warning | Review recommended |

The `CONFIGURATION-DRIFT.md` file is updated and committed back to the PR branch using the ADO system access token. The commit message includes `[skip ci]` to avoid re-triggering the pipeline.

### Stage 5 — DR (`generate-dr-config.ps1` + `validate-dr-config.ps1`)

| Transformation | Detail |
|---|---|
| Location | All resource `location` fields → `$DR_REGION` |
| VNet address space | `addressPrefixes` array → `[$DR_VNET_PREFIX]` |
| Subnet address prefix | `addressPrefix` → `$DR_SUBNET_PREFIX` |
| Resource names | Prefixed with `$DR_NAMING_PREFIX` (default: `dr-`) |
| Validation | `az deployment group validate` (non-fatal, reported) |

### Stage 6 — Report (`post-pr-comment.ps1`)

| Item | Detail |
|---|---|
| API | ADO REST API v7.1: `GET/POST/PATCH /pullRequests/{id}/threads` |
| Idempotency | Finds existing bot comment by `<!-- azure-compliance-pipeline-bot -->` tag and PATCHes it |
| Gate signals | Sets `DRIFT_CRITICAL`, `DRIFT_WARNINGS`, `DEPLOYMENT_COVERAGE` as pipeline output variables |

---

## Service Principal Requirements

The Azure DevOps service connection's managed identity / service principal needs:

| Scope | Role | Purpose |
|---|---|---|
| Management Group or Subscriptions | `Reader` | Resource Graph queries |
| Subscriptions | `Reader` | ARM template export |
| Subscriptions (DR) | `Contributor` | DR resource group creation (for what-if) |
| ADO Repository | `Contribute` | Commit `CONFIGURATION-DRIFT.md` |
| ADO Pull Requests | `Contribute to pull requests` | Post PR comments |

---

## Variable Group: `azure-compliance-pipeline-secrets`

| Variable | Required | Description |
|---|---|---|
| `AZURE_SERVICE_CONNECTION` | ✅ | ADO service connection name |
| `AZURE_TENANT_ID` | ✅ | Azure AD tenant ID |
| `AZURE_SUBSCRIPTION_IDS` | ✅ | Comma-separated subscription IDs, or `ALL` |
| `MANAGEMENT_GROUP_ID` | Optional | Management group ID (overrides subscription list) |
| `drTargetRegion` | ✅ | DR target region (e.g., `northeurope`) |
| `drVnetAddressPrefix` | ✅ | DR VNet CIDR (e.g., `10.1.0.0/16`) |
| `drSubnetAddressPrefix` | ✅ | DR subnet CIDR (e.g., `10.1.0.0/24`) |
| `drNamingPrefix` | Optional | Resource name prefix (default: `dr-`) |

---

## Artifacts Published

| Artifact | Contents |
|---|---|
| `scan-results` | 10 JSON files of Azure resource data |
| `export-results` | ARM templates + Bicep per resource group |
| `env-docs` | `ENVIRONMENT.md` environment documentation |
| `review-results` | PR change analysis and deployment match report |
| `drift-results` | Drift report JSON |
| `dr-config` | DR Bicep templates, parameters, deploy scripts |
| `compliance-reports` | All of the above combined |

---

## Idempotency & Fault Tolerance

- All scripts use `set -euo pipefail` with explicit error handling
- `scan-subscriptions.ps1`: failed subscription queries are logged, not fatal
- `export-arm-templates.ps1`: failed exports are skipped; summary tracks failures
- `generate-dr-config.ps1`: per-RG failures are tracked individually
- `validate-dr-config.ps1`: runs with `continueOnError: true` in the pipeline
- `commit-drift-readme.ps1`: 3-retry push with rebase; falls back gracefully
- `post-pr-comment.ps1`: comment post failure is non-fatal; dumps to log

---

## Extending the Pipeline

### Add a new resource type to scan
Edit `scripts/scan/scan-subscriptions.ps1` and add a `run_resource_graph_query` call with a new KQL query.

### Change drift severity rules
Edit `scripts/drift/detect-drift.ps1` — adjust the `severity` field in `DRIFT_ITEMS`.

### Add a new naming convention for DR
Edit `scripts/dr/generate-dr-config.ps1` — extend the `transform` jq function.

### Support Terraform state comparison
Add a new script `scripts/review/match-terraform-state.ps1` that uses `terraform show -json` output and calls the same scan data for lookup.
