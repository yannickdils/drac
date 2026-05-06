# Azure DevOps PR Compliance Pipeline — Documentation

> **Version:** 1.0.0
> **API Versions:** Resource Graph `2024-04-01` · ARM `2021-04-01` · ADO REST `7.1`
> **Last Updated:** 2026-05-06

---

## Table of Contents

1. [Quick Start](#quick-start)
2. [Prerequisites](#prerequisites)
3. [Setup Guide](#setup-guide)
4. [Pipeline Stages](#pipeline-stages)
5. [Configuration Reference](#configuration-reference)
6. [Output Files](#output-files)
7. [Reading CONFIGURATION-DRIFT.md](#reading-configuration-driftmd)
8. [Disaster Recovery Templates](#disaster-recovery-templates)
9. [Troubleshooting](#troubleshooting)
10. [FAQ](#faq)

---

## Quick Start

```bash
# 1. Copy this directory into your repository
cp -r azure-compliance-pipeline/* /path/to/your-repo/

# 2. Register the pipeline in Azure DevOps
#    Path: .azure/pipelines/pr-compliance.yml
#    Trigger: PR to main (configured in YAML)

# 3. Create the variable group (see Setup Guide)

# 4. Create a pull request to main → pipeline runs automatically
```

---

## Prerequisites

| Requirement | Minimum Version | Notes |
|---|---|---|
| Azure DevOps | Cloud / Server 2022+ | For YAML pipeline support |
| Azure CLI | 2.57+ | Pre-installed on `ubuntu-latest` agent |
| Bicep CLI | Latest | Auto-installed by pipeline |
| `jq` | 1.6+ | Auto-installed by pipeline |
| PowerShell | 7.2+ | Pre-installed on `ubuntu-latest` agent |
| Service Principal | — | Needs Reader + Contribute on repos |

---

## Setup Guide

### 1. Create the Azure Service Connection

In Azure DevOps → Project Settings → Service connections:

1. **New service connection** → Azure Resource Manager → Service Principal (automatic)
2. Grant access to your subscription(s) or management group
3. Note the **service connection name** — you'll need it in the variable group

### 2. Grant Service Principal Permissions

```bash
# Grant Reader on the management group (or individual subscriptions)
az role assignment create \
  --assignee "<service-principal-app-id>" \
  --role "Reader" \
  --scope "/providers/Microsoft.Management/managementGroups/<mg-id>"

# Grant Contributor on the DR subscription (for what-if validation)
az role assignment create \
  --assignee "<service-principal-app-id>" \
  --role "Contributor" \
  --scope "/subscriptions/<dr-subscription-id>"
```

### 3. Create the Variable Group

In Azure DevOps → Pipelines → Library → **+ Variable group**:

**Name:** `azure-compliance-pipeline-secrets`

| Variable | Example Value | Secret? |
|---|---|---|
| `AZURE_SERVICE_CONNECTION` | `my-azure-connection` | No |
| `AZURE_TENANT_ID` | `xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx` | No |
| `AZURE_SUBSCRIPTION_IDS` | `sub-id-1,sub-id-2` or `ALL` | No |
| `MANAGEMENT_GROUP_ID` | `my-management-group` or `none` | No |
| `drTargetRegion` | `northeurope` | No |
| `drVnetAddressPrefix` | `10.1.0.0/16` | No |
| `drSubnetAddressPrefix` | `10.1.0.0/24` | No |
| `drNamingPrefix` | `dr-` | No |

### 4. Register the Pipeline

1. In Azure DevOps → Pipelines → **New pipeline**
2. Choose your repository
3. Select **Existing Azure Pipelines YAML file**
4. Path: `.azure/pipelines/pr-compliance.yml`
5. Save (do not run yet)

### 5. Configure Branch Policy (Optional but Recommended)

In Azure DevOps → Repos → Branches → `main` → Branch policies:

1. **Build validation** → Select the compliance pipeline
2. Set to **Required** for full enforcement
3. This prevents merging PRs where critical drift is detected

---

## Pipeline Stages

### Stage 1: Scan Azure Subscriptions

**What it does:** Queries all Azure subscriptions using Azure Resource Graph API, collecting a comprehensive snapshot of deployed resources.

**Script:** `scripts/scan/scan-subscriptions.ps1`

**Output files in `scan-results/`:**
- `all-resources.json` — Complete resource inventory
- `vnets.json` — Virtual network configurations
- `nsgs.json` — Network security groups
- `compute.json` — VMs, VMSS, AKS, App Services
- `storage-databases.json` — Storage, SQL, Cosmos, Redis
- `security.json` — Key Vaults, Managed Identities
- `rbac.json` — Role assignments
- `policies.json` — Policy assignments
- `resource-groups.json` — Resource group metadata
- `networking-advanced.json` — App Gateways, Load Balancers
- `scan-summary.json` — Run metadata

---

### Stage 2: Export & Document Environment

**What it does:** Exports ARM templates for every resource group discovered in Stage 1, then generates an environment documentation markdown file.

**Scripts:** `scripts/export/export-arm-templates.ps1`, `scripts/export/generate-env-docs.ps1`

**Key behaviours:**
- Uses the ARM export REST API with `IncludeParameterDefaultValue,IncludeComments`
- Attempts Bicep decompilation (best-effort, non-fatal)
- Skips already-exported resource groups for idempotency
- Tracks and reports failed exports without stopping the pipeline

**Output files in `export-results/`:**
- `arm-templates/<sub-id>/<rg-name>/template.json`
- `arm-templates/<sub-id>/<rg-name>/parameters.json`
- `bicep-templates/<sub-id>/<rg-name>/*.bicep`
- `export-index.json`
- `export-summary.json`

**Output files in `env-docs/`:**
- `ENVIRONMENT.md` — Auto-generated environment overview

---

### Stage 3: Review Code vs Deployed State

**What it does:** Identifies files changed in the PR, categorises them by IaC type, and cross-references the resource names defined in those files against the scan results.

**Scripts:** `scripts/review/identify-pr-changes.ps1`, `scripts/review/match-code-to-deployed.ps1`

**Detection logic:**
- Bicep: `grep` for `name:` properties (string literals only)
- Terraform: `grep` for `name =` assignments
- ARM JSON: `jq .resources[].name`
- Matching: case-insensitive substring comparison against `all-resources.json`

**Deployment statuses:**
- `all-deployed` — All resources found in Azure ✅
- `partially-deployed` — Some resources found ⚠️
- `not-deployed` — No resources found ❌
- `no-resources-extracted` — Could not parse resource names
- `not-iac` — Non-infrastructure file

---

### Stage 4: Configuration Drift Detection

**What it does:** Performs a three-way analysis: deployed resources vs code declarations vs PR changes.

**Scripts:** `scripts/drift/detect-drift.ps1`, `scripts/drift/update-drift-readme.ps1`, `scripts/drift/commit-drift-readme.ps1`

**Drift categories detected:**

| Type | How detected | Severity |
|---|---|---|
| IaC defined but not deployed | Name from code not found in scan | 🔴 Critical |
| PR change not deployed | Changed IaC file with no Azure match | 🔴 Critical |
| Partial deployment | Some resources in file found, others not | 🔴 Critical |
| Deployed but not in code | Azure resource with no IaC definition | 🟡 Warning |

**CONFIGURATION-DRIFT.md updates:**
- The file is updated by `update-drift-readme.ps1`
- The update is committed back to the **PR branch** (not main)
- Reviewers can see the drift report directly in the PR's file changes
- Each PR entry is idempotently upserted (re-runs update the same entry)

---

### Stage 5: Disaster Recovery Configuration

**What it does:** Takes exported ARM templates and generates DR-ready versions targeted at the secondary region. As of Round 1 of the implementation brief, the actual transformation lives in **`scripts/lib/ConvertForDR.psm1`** — `generate-dr-config.ps1` is a thin wrapper.

**Scripts:** `scripts/dr/generate-dr-config.ps1`, `scripts/dr/validate-dr-config.ps1`
**Module:** `scripts/lib/ConvertForDR.psm1`
**Data files:** `data/reserved-names.json`, `data/readonly-properties.json`

**Transformations applied (Round 1 correctness fixes B1–B4 from `IMPLEMENTATION-BRIEF.md`):**

1. **B1 — Type-aware name prefixing.** Top-level resource names (whose `type` is `Microsoft.X/Y` — single slash) get `$DR_NAMING_PREFIX`. Names listed in `data/reserved-names.json` (`GatewaySubnet`, `AzureFirewallSubnet`, etc.) are preserved exactly. Nested resource names (subnet names inside a VNet, NSG rule names) are NEVER prefixed.
2. **B2 — Cross-resource reference rewriting.** ARM expressions like `[resourceId('Microsoft.Network/virtualNetworks', 'vnet-prod')]`, `[reference('vnet-prod')]`, and `dependsOn` arrays are rewritten so they point at the DR-prefixed names. Nested-type resource names (e.g. `vnet-hub/peer-to-spoke`) get their parent segments rewritten.
3. **B3 — Context-aware address-space rewriting.** Only `Microsoft.Network/virtualNetworks` resources have their address space rewritten to `$DR_VNET_PREFIX`. Multi-prefix VNets keep only the first prefix and surface a `requiresMultiPrefixDR` flag in `_reports/dr/flags.json`. Address prefixes inside peerings, route tables, and NSG rules are left alone.
4. **B4 — Read-only property sanitisation.** Properties listed in `data/readonly-properties.json` (global like `provisioningState`/`etag`, plus per-type like storage `primaryEndpoints` and web/site `outboundIpAddresses`) are stripped before the transform so the template can be redeployed cleanly.
5. **`location` fields** → `$DR_REGION` (literal values only; ARM expressions are left alone).
6. DR parameters file generated.
7. Deployment PowerShell script generated (what-if safe by default).
8. **`flags.json`** generated, listing every deferred-handling case (multi-prefix VNets, multi-subnet VNets, all-reserved-subnet VNets) for operator review.

**Validation:**
- Runs `az deployment group validate` on each generated template (non-fatal, reported).
- Structural correctness is also asserted offline by `tests/round-1/Test-ConvertForDR.ps1` and the rewire smoke test `tests/round-1/Test-GenerateDrConfig-Smoke.ps1`. Run them with:
  ```powershell
  pwsh tests/Invoke-Validation.ps1 -Round 1
  ```

---

### Stage 3.5: DR Coverage Gate (Round 2 §R2.1)

**What it does:** Inside the existing `review` job of `pr-compliance.yml`, a new step asserts that every PR-changed file under `bicep/regions/primary/` has a matching `bicep/regions/dr/dr-<workload>.bicep` companion. When missing, the gate auto-generates the companion (`bicep build` → `Convert-ForDR` → `bicep decompile`) and commits it back to the PR branch.

**Script:** `scripts/review/check-dr-coverage.ps1`

**Convention** (operator-authored — see `bicep/regions/README.md`):

```
bicep/regions/
├── primary/<workload>.bicep    ← you author this
└── dr/dr-<workload>.bicep      ← gate auto-generates this when missing
```

**Outputs:**

| Item | Where |
|---|---|
| Per-file coverage report | `_reports/coverage/coverage-report.json` |
| GitHub Actions output | `DR_COVERAGE_OK=true|false` (consumable by downstream jobs) |
| Commit-back | Auto-generated companions pushed to PR branch as `chore(draac): auto-generate DR companions [skip ci]` |

**Coverage states per primary file:**

| State | Meaning | Gate result |
|---|---|---|
| `ok` | DR companion already in repo | pass |
| `auto-generated` | Companion missing; gate generated & committed it | pass (re-validates green on next push) |
| `failed` | Auto-generation failed (e.g. Bicep decompile dirty) | **block** — exits non-zero; reviewer must hand-author the companion |

**Adding a new workload:** Drop a new `bicep/regions/primary/<workload>.bicep` in your PR. The gate auto-generates `dr/dr-<workload>.bicep` on first push; review the diff and merge.

---

### Stage 7: DR Deploy (Round 2 §R2.2)

**What it does:** On push to `main` whose changes touch `bicep/regions/dr/**`, this workflow deploys every `dr-*.bicep` to its conventional resource group in the DR region.

**Workflow:** `.github/workflows/dr-deploy.yml`
**Script:** `scripts/dr/deploy-dr-region.ps1`

**Behaviours:**

- **Resource group convention:** `dr/dr-<workload>.bicep` deploys to RG `rg-<workload>-dr` in `$DR_TARGET_REGION`. The script `az group create`s it idempotently before deploying.
- **Deterministic deployment name:** `draac-<sha7>-rg-<workload>-dr`. Re-running the workflow at the same commit SHA against the same template is a no-op at the Azure level (Azure deduplicates by deployment name within an RG).
- **What-if first:** Each file gets a what-if pass (`_reports/deploy/whatif-rg-<workload>-dr.json`) before the actual deployment.
- **Throttling retry:** Detects `429`/`ThrottlingException`/`TooManyRequests`; exponential backoff `5s → 15s → 45s → 135s` before failing the file.
- **Per-RG fault tolerance:** A single file's failure does not abort the run. Failures land in `_reports/deploy/failures.json`; the run summary at `_reports/deploy/deploy-summary.json` lists what succeeded and what didn't.
- **Concurrency:** `group: draac-dr-deploy, cancel-in-progress: false` — never cancels an in-flight deploy.

**Required secrets** (already required by `pr-compliance.yml` — no new secrets):

| Secret | Purpose |
|---|---|
| `AZURE_CLIENT_ID` / `AZURE_TENANT_ID` / `AZURE_SUBSCRIPTION_ID` | OIDC federated auth |
| `DR_TARGET_REGION` | DR region (e.g. `northeurope`) |

**Manual re-run:** Trigger via the Actions tab → "DRaaC DR Deploy" → "Run workflow". Useful for re-deploying without a code change (e.g. after manually deleting an RG).

**Test-DRHealth invocation point:** A comment placeholder in `deploy-dr-region.ps1` marks where the post-deploy health check will hook in once Round 4 §R4.2 is implemented.

---

### Stage 8: Portal Drift Sync (Round 3 §R3.1–§R3.4)

**What it does:** Once a day at 02:00 UTC (and on demand via `workflow_dispatch`), DRaaC scans Azure for resource changes that were made through the Portal (or otherwise outside this repo) and reverse-engineers them into PRs — or files a `portal-sync-manual` issue when Bicep decompile is too dirty for automation.

**Workflow:** `.github/workflows/portal-drift-sync.yml`
**Scripts:** `scripts/sync/Find-PortalChanges.ps1`, `scripts/sync/Sync-PortalChange.ps1`, `scripts/sync/Send-ToManualQueue.ps1`

**Two jobs:**

1. **detect** — runs `Find-PortalChanges.ps1` against the Resource Graph `resourcechanges` table over the last 24 h (configurable via `workflow_dispatch` input). Filters out global read-only-property changes (using `data/readonly-properties.json`'s `global` list — i.e. real *content* changes, not framework-internal noise) and Azure system-managed resources (`NetworkWatcher*`, `DefaultResourceGroup*`, `cloud-shell*`, `AzureBackupRG*`). Coalesces multiple changes against the same resource into one entry holding the latest snapshot. Outputs `portal-changes.json`. Sets `has-changes` job output.

2. **sync** (only runs if `has-changes == 'true'`) — runs `Sync-PortalChange.ps1`. Per change:
   - `az resource show` for the live ARM JSON → wrap as a single-resource ARM template.
   - `bicep decompile`. Clean (no warnings, exit 0): produce primary + DR Bicep via `Convert-ForDR`, branch `portal-sync/<yyyyMMddUTC>-<sha256-12>`, push, open a PR titled `[portal-sync] Reconcile portal change to <resource-name>`.
   - Dirty (warnings or non-zero exit): `Send-ToManualQueue.ps1` snapshots the ARM JSON to `_reports/sync/manual-queue/<sha256-12>.json` and opens a `portal-sync-manual` issue with reviewer checklist + decompile output + ARM template. Existing open issue with the same hash → no-op.

**PR / issue dedup:** Both branches and issues are keyed by 12 hex chars of `SHA-256(lower(resourceId))`. Branches are scoped per UTC day (`yyyyMMdd-<hash>`) so a same-day re-run is a no-op. `gh pr list --search` checks for existing open PRs before creating; same for issues.

**Required secrets** (no new secrets; re-uses what `pr-compliance.yml` already needs):

| Secret | Purpose |
|---|---|
| `AZURE_CLIENT_ID` / `AZURE_TENANT_ID` / `AZURE_SUBSCRIPTION_ID` | OIDC auth |
| `DR_TARGET_REGION`, `DR_VNET_ADDRESS_PREFIX`, `DR_SUBNET_ADDRESS_PREFIX` | passed through to `Convert-ForDR` |

**OIDC subject:** the workflow runs on a schedule (i.e. against `refs/heads/main`), so the App Registration's federated credential needs the `repo:<owner>/<repo>:ref:refs/heads/main` subject — same one Round 2's `dr-deploy.yml` requires. If you set up DRaaC with only the PR-scope subject, run `setup-github.ps1` again to add the main subject.

**Manual triggering:** Actions tab → "DRaaC Portal Drift Sync" → "Run workflow". Optionally pass a custom `lookback-hours`.

**What appears in the repo:**

- A PR titled `[portal-sync] Reconcile portal change to <resource-name>` with primary + DR Bicep, list of changed properties, reviewer checklist, and a portal link to the resource.
- Or an issue labelled `portal-sync-manual` with the ARM JSON, decompile warnings, and reviewer instructions.

**Re-running on the same day:** Idempotent — branches are stable per (day, resource-id), so the second run is a no-op against any open PRs from the first.

---

### Stage 7-DR: DR Module Library + Health + Traffic + Secrets Sync (Round 4)

**What it does:** Closes the gap between "DR companion files exist" and "DR is actually a working failover destination." Round 4 ships a per-resource-family DR Bicep module library, post-deploy health probes, an Azure Front Door traffic-routing module, and an event-driven Key Vault secrets-sync runbook.

#### R4.1 — DR module library (`bicep/modules/dr-*.bicep`)

| Module | Family | Replication |
|---|---|---|
| `dr-sql.bicep` | `Microsoft.Sql/servers/databases` | Failover groups + automatic policy |
| `dr-cosmos.bicep` | `Microsoft.DocumentDB/databaseAccounts` | Multi-region writes + automatic failover |
| `dr-storage.bicep` | `Microsoft.Storage/storageAccounts` | RA-GZRS (Standard) / cross-region restore intent (Premium) |
| `dr-keyvault.bicep` | `Microsoft.KeyVault/vaults` | Soft-delete + purge protection (secrets sync handled by R4.4) |
| `dr-postgres.bicep` | `Microsoft.DBforPostgreSQL/flexibleServers` | Read replica (`createMode: Replica`) |
| `dr-mysql.bicep` | `Microsoft.DBforMySQL/flexibleServers` | Read replica (`createMode: Replica`) |
| `dr-redis.bicep` | `Microsoft.Cache/Redis` | Geo-replication via `linkedServers` (Premium-only) |

`Convert-ForDR` reads `data/dr-module-registry.json` to know which types should be replaced with module references in the auto-generated DR companion. Caller-side wiring (post-decompile rewrite) is deferred to Round 5; for now the dispatch step records the intent and surfaces it on `Convert-ForDR`'s `Dispatched` field.

**Cross-RG deploys.** `dr-sql.bicep` and `dr-redis.bicep` use `existing` references to the primary server / cache, so the deployment must target the **primary** RG (the failover group / linked server lives there). Stage 7's `deploy-dr-region.ps1` is unchanged in this round; an operator wiring these modules will need to drive the deployment with `--resource-group rg-<workload>` (primary) for these two families instead of the `-dr` default.

#### R4.2 — DR health probes (`scripts/dr/Test-DRHealth.ps1`)

Runs after Stage 7 succeeds. Reads the Stage 7 `_reports/deploy/deploy-summary.json`, walks each DR resource group, and dispatches per-family probes (SQL `replicationState == "CATCH_UP"` and lag, Cosmos `provisioningState` and DR region in `readLocations`, Storage secondary endpoints + `lastSyncTime` recency, KV `enablePurgeProtection`/`enableSoftDelete`, Postgres/MySQL replica `state`, Redis `linkedServers` state).

```powershell
pwsh scripts/dr/Test-DRHealth.ps1 \
    -DeploySummaryFile _reports/deploy/deploy-summary.json \
    -OutputDir _reports/dr-health \
    -DrRegion northeurope \
    -SqlLagThresholdSeconds 60 \
    -StorageSyncToleranceMinutes 15
```

Outputs `_reports/dr-health/dr-health.json` and writes `DR_HEALTH_OK=true|false` + `DR_HEALTH_SUMMARY=<healthy>/<total>` to `$GITHUB_OUTPUT` so the PR comment can summarise health. Per-resource probe failures are logged + skipped (status `unknown`); only `degraded` or `unhealthy` flip `DR_HEALTH_OK` to false.

`-DryRun -FixtureFile <json>` runs the entire pipeline against a hand-rolled fixture so the test harness exercises the full flow without an Azure subscription.

#### R4.3 — Azure Front Door traffic routing (`bicep/modules/dr-traffic.bicep`)

A mandatory traffic-routing module for any workload that exposes any of `Microsoft.Web/sites`, `Microsoft.ContainerService/managedClusters`, or `Microsoft.Network/applicationGateways`. The DR coverage gate (`scripts/review/check-dr-coverage.ps1`) **fails any PR** where a public-facing primary's DR companion does NOT contain a `dr-traffic.bicep` reference. Auto-generated companions cannot synthesise this wiring; the gate's failure message includes a remediation hint with a copy-paste-ready `module traffic '../../modules/dr-traffic.bicep' = { ... }` snippet.

Module shape (Front Door Premium):
- Origin group with primary (priority 1, weight 1000) + DR (priority 2, weight 1000) origins
- Health probes (HTTPS HEAD on `healthProbePath`, default `/`, 30s interval, 3-of-4 success threshold ≈ 90s failover window)
- WAF policy (Microsoft Default Rule Set v2.1 + Bot Manager v1.1, mode `Detection` or `Prevention`)
- Optional custom domain — emits `Microsoft.Cdn/profiles/customDomains` only when `customDomainName` parameter is non-empty

#### R4.4 — Key Vault secrets-sync runbook (`bicep/modules/dr-keyvault-sync.bicep` + `scripts/secrets/Sync-KeyVaultSecrets.ps1`)

DRaaC's chosen KV strategy is **replicated vaults with an event-driven sync runbook** (option (b) in the brief). One-time deploy of `dr-keyvault-sync.bicep` per workload provisions:

- A PowerShell-runtime Function App (Y1 consumption, Linux, PowerShell 7.4) in the primary region
- An Event Grid system topic on the primary KV (`topicType: 'Microsoft.KeyVault.vaults'`) with an event subscription filtering to `Microsoft.KeyVault.SecretNewVersionCreated`
- Two role assignments — `Key Vault Secrets User` on the primary vault (inline) + `Key Vault Secrets Officer` on the DR vault (via the `dr-keyvault-sync-drrole.bicep` cross-RG sub-module — cross-RG role assignments cannot be inline in Bicep)
- App Insights for the Function

`scripts/secrets/Sync-KeyVaultSecrets.ps1` is the Function's `run.ps1`. It reads the new secret version from the primary vault via the system MI (`Az.KeyVault`), checks if the DR vault already holds the same value (idempotency short-circuit), and writes if not. `-DryRun` and the `DRAAC_SECRETS_FORCE_INSYNC` env var make the script test-driveable.

**Operator action on first install:** the brief's R4.5 acceptance — deploy a workload with SQL DB + Storage + KV through the full pipeline, manually trigger Front Door health-probe failure on primary, run `Test-DRHealth.ps1` — is left to the operator with a sandbox subscription. Round 4 ships the building blocks; the integration test against a live subscription is in the deferrals list (`docs/NEXT-SESSION-BRIEF.md`).

### Stage 6: Final Report & PR Annotation

**What it does:** Aggregates all reports and posts (or updates) a structured comment on the PR.

**Script:** `scripts/report/post-pr-comment.ps1`

**Uses ADO REST API v7.1:**
- `GET /pullRequests/{id}/threads` — find existing bot comment
- `POST /pullRequests/{id}/threads` — create new comment
- `PATCH /pullRequests/{id}/threads/{tid}/comments/{cid}` — update existing

The bot comment includes a unique HTML tag `<!-- azure-compliance-pipeline-bot -->` that allows it to find and update its own comment on re-runs.

---

## Configuration Reference

### Pipeline Parameters (queue-time overridable)

| Parameter | Default | Description |
|---|---|---|
| `drTargetRegion` | From variable group | Azure region for DR configuration |
| `drVnetAddressPrefix` | From variable group | VNet CIDR block for DR |
| `drSubnetAddressPrefix` | From variable group | Subnet CIDR for DR |
| `drNamingPrefix` | `dr-` | Prefix added to DR resource names |

### Adjusting Scan Scope

To scan a management group instead of individual subscriptions:
- Set `MANAGEMENT_GROUP_ID` in the variable group
- Set `AZURE_SUBSCRIPTION_IDS` to `none`

To scan specific subscriptions only:
- Set `AZURE_SUBSCRIPTION_IDS` to a comma-separated list
- Leave `MANAGEMENT_GROUP_ID` as `none`

---

## Output Files

### Key files for human review

| File | Location | Purpose |
|---|---|---|
| `CONFIGURATION-DRIFT.md` | Repo root (committed to PR) | Drift history per PR |
| `ENVIRONMENT.md` | `env-docs/` artifact | Current environment state |
| `drift-report.json` | `drift-results/` artifact | Machine-readable drift data |
| `DR-README.md` | `dr-config/` artifact | DR configuration overview |
| `deployment-match-report.json` | `review-results/` artifact | Code-to-Azure match results |

---

## Reading CONFIGURATION-DRIFT.md

Each PR run adds an entry to the top of the file:

```markdown
## PR #42 · feature/my-feature · 2026-03-31

> **Status:** 🔴 CRITICAL
> **Pipeline Run:** `12345`

### Summary
| Metric | Count |
| Critical Drift Items | 2 |
...

### Critical Items
| Resource / File | Drift Type | Description |
| `my-vm` | in-code-not-deployed | IaC defines this resource... |
```

**Action Required if status is 🔴:**
- The resource named in the critical item must be deployed to Azure
- OR the IaC definition must be removed if the resource is intentionally absent
- Re-run the pipeline after fixing to get a 🟢 status

---

## Disaster Recovery Templates

DR templates are generated in the `dr-config/` artifact:

```
dr-config/
  arm/
    <subscription-id>/
      dr-<resource-group-name>/
        template.json       ← Transformed ARM template
        parameters.json     ← DR-specific parameters
        deploy-dr.ps1        ← Deployment script (what-if by default)
        dr-metadata.json    ← Transformation audit trail
  bicep/
    <subscription-id>/
      dr-<resource-group-name>/
        *.bicep             ← Decompiled Bicep (best-effort)
  dr-index.json             ← Index of all DR configs
  dr-validation-report.json ← Validation results
  DR-README.md              ← Usage instructions
```

**To deploy DR configuration:**
```bash
# 1. Download the dr-config artifact
# 2. Review the what-if output
cd dr-config/arm/<sub-id>/dr-<rg-name>
chmod +x deploy-dr.ps1
./deploy-dr.ps1   # Runs what-if only

# 3. Edit deploy-dr.ps1 to uncomment the deploy command
# 4. Re-run to deploy
```

---

## Troubleshooting

### Pipeline fails at scan stage with 403

- The service principal does not have `Reader` on the subscriptions
- Run: `az role assignment create --assignee <sp-id> --role Reader --scope /subscriptions/<id>`

### "All exports failed"

- Check that the service principal has `Reader` on resource groups
- Some resources (e.g., Azure Data Factory) cannot be exported — these are logged as warnings

### CONFIGURATION-DRIFT.md commit fails

- Ensure the pipeline's **Build Service** identity has `Contribute` permission on the repository
- In ADO → Project Settings → Repositories → Security → `<Project> Build Service`

### DR templates fail validation

- This is non-fatal; review `dr-validation-report.json` in the artifact
- Common causes: missing required parameters, unsupported resource types in target region
- Manually edit the template or add the missing parameters

### DR template references the original (un-prefixed) resource name

- Round 1's B2 fix should rewrite quote-bounded references in ARM expressions. If you see leftovers, the resource is likely referenced via something other than a quoted string literal (e.g. concatenated parameters).
- Inspect `tests/round-1/Test-ConvertForDR.ps1`'s peered-VNet assertions to see the exact patterns covered, and add a fixture that captures the new pattern before patching `scripts/lib/ConvertForDR.psm1`.

### "GatewaySubnet" got renamed to "dr-GatewaySubnet"

- This means `data/reserved-names.json` was not loaded. Either the file is missing or `generate-dr-config.ps1` was invoked from a working directory where the relative path could not resolve.
- The script resolves data files relative to the script's own location (`$PSScriptRoot/../../data/`), so it should not depend on the caller's CWD. Check that the repo layout is intact.

### "Could not compute diff"

- Ensure `fetchDepth: 0` in the checkout step (already set in the pipeline)
- Check that `origin/main` is fetchable from the agent

---

## FAQ

**Q: Does this pipeline actually block PRs from merging?**  
A: Not by itself — it sets pipeline output variables. To enforce blocking, configure the pipeline as a **required build validation** in branch policies and optionally add a check gate reading `DRIFT_CRITICAL`.

**Q: What happens if a resource is in Azure but the name is parameterised in IaC?**  
A: Parameterised names (e.g., `[parameters('name')]`) are skipped during name extraction. To improve coverage, use literal names in your IaC or extend the extraction logic in `match-code-to-deployed.ps1`.

**Q: How do I exclude certain subscriptions from scanning?**  
A: Set `AZURE_SUBSCRIPTION_IDS` to a comma-separated list of only the subscriptions you want to include.

**Q: How do I exclude certain resources from drift detection?**  
A: In `detect-drift.ps1`, add name patterns to the exclusion block:
```bash
[[ "$rname" =~ ^(NetworkWatcher|DefaultResourceGroup|MyIgnoredResource) ]] && continue
```

**Q: Can this pipeline run on self-hosted agents?**  
A: Yes. Ensure Azure CLI 2.57+, `jq` 1.6+, and PowerShell 7.2+ are installed. The Bicep CLI is auto-installed.

**Q: Can I use this with Terraform instead of Bicep?**  
A: Stage 3 already extracts Terraform resource names for matching. For drift detection with Terraform state, add a script that runs `terraform show -json` and compares with the scan data.
