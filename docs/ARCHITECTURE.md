# Architecture: Azure DevOps PR Compliance Pipeline

> **Last Updated:** 2026-05-06
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

Push to main (paths: bicep/regions/dr/**)
       │
       ▼
┌─────────────────────────────────────────────────────────┐
│  Stage 7: DR DEPLOY  (Round 2 — .github/workflows/dr-   │
│                                  deploy.yml)             │
│  ┌──────────────────────────────────────────────────┐  │
│  │  scripts/dr/deploy-dr-region.ps1                  │  │
│  │  • Walk bicep/regions/dr/dr-*.bicep               │  │
│  │  • az group create rg-<workload>-dr (idempotent)  │  │
│  │  • what-if → _reports/deploy/whatif-*.json        │  │
│  │  • az deployment group create                     │  │
│  │       name=draac-<sha7>-rg-<workload>-dr          │  │
│  │  • Throttling retry (5/15/45/135s exp backoff)    │  │
│  │  • Per-RG fault tolerance → failures.json         │  │
│  │  • Final summary → deploy-summary.json            │  │
│  └──────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────┘
```

### Round 2 — DR coverage gate (PR time, in `review` job)

In addition to the six-stage PR pipeline, Round 2 introduces a **DR coverage gate** inside the `review` job that enforces the `bicep/regions/primary/foo.bicep` ↔ `bicep/regions/dr/dr-foo.bicep` convention. For every PR-changed primary file, the gate either confirms the DR companion exists or auto-generates one (`bicep build` → `Convert-ForDR` → `bicep decompile`) and commits it back to the PR branch via the shared `scripts/lib/CommitBack.psm1` helper. See *Stage 3 — Review* below for the full step list.

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

### Stage 3 — Review (`identify-pr-changes.ps1` + `match-code-to-deployed.ps1` + `check-dr-coverage.ps1`)

| Item | Detail |
|---|---|
| Diff source | `git diff origin/main...HEAD` (full history checkout) |
| IaC types | `.bicep`, `.tf`, ARM `.json`, K8s manifests, Helm |
| Matching | Case-insensitive resource name lookup in scan JSON |
| Output | `review-results/deployment-match-report.json`, `coverage-results/coverage-report.json` |

**File categorisation:**
- Bicep → `grep` for `name:` properties
- Terraform → `grep` for `name =` assignments
- ARM JSON → `jq` `.resources[].name`

**DR coverage gate** (Round 2 §R2.1, runs after the match step):

| Item | Detail |
|---|---|
| Script | `scripts/review/check-dr-coverage.ps1` |
| Convention | `bicep/regions/primary/<workload>.bicep` ↔ `bicep/regions/dr/dr-<workload>.bicep` |
| If companion exists | record `coverage: ok` |
| If companion missing | `bicep build` → `Convert-ForDR` (Round 1 module) → `bicep decompile` → write companion → `coverage: auto-generated` |
| If auto-generation fails | `coverage: failed` and the gate exits non-zero |
| Commit-back | Auto-generated companions are pushed to the PR branch via `scripts/lib/CommitBack.psm1` (the same helper Stage 4 uses for `CONFIGURATION-DRIFT.md`) |
| GitHub Actions output | `DR_COVERAGE_OK=true|false` |

### Stage 4 — Drift (`detect-drift.ps1` + `update-drift-readme.ps1` + `commit-drift-readme.ps1`)

| Drift Type | Severity | Action |
|---|---|---|
| `in-code-not-deployed` | 🔴 Critical | Block merge recommendation |
| `pr-change-not-deployed` | 🔴 Critical | Block merge recommendation |
| `partial-deployment` | 🔴 Critical | Block merge recommendation |
| `deployed-not-in-code` | 🟡 Warning | Review recommended |

The `CONFIGURATION-DRIFT.md` file is updated and committed back to the PR branch using the ADO system access token. The commit message includes `[skip ci]` to avoid re-triggering the pipeline.

### Stage 5 — DR (`generate-dr-config.ps1` + `validate-dr-config.ps1`)

The actual ARM template transformation lives in the **`scripts/lib/ConvertForDR.psm1`** module (introduced in Round 1 of the implementation brief). `generate-dr-config.ps1` is a thin wrapper that loads exported templates, calls `Convert-ForDR`, and persists the results.

| Transformation | Detail |
|---|---|
| Location | Literal `location` fields → `$DR_REGION` (ARM-expression locations are left alone) |
| Resource names — top-level | Prefixed with `$DR_NAMING_PREFIX` (default: `dr-`), unless the name is in the reserved-name allowlist (`data/reserved-names.json`). Top-level = `type` matches `Microsoft.X/Y` (single slash). |
| Resource names — nested types | For multi-slash types (e.g. `Microsoft.Network/virtualNetworks/virtualNetworkPeerings`), the `name` is split by `/` and each segment that matches a known top-level resource is rewritten to its DR name. |
| Cross-resource references (B2) | Two-pass rewrite: pass 1 builds an `original → dr` name map for top-level resources; pass 2 walks every string in the template and substitutes quote-bounded occurrences. Map keys are iterated longest-first to avoid prefix collisions (`vnet-prod-shared` rewritten before `vnet-prod`). |
| VNet address space (B3) | Only `Microsoft.Network/virtualNetworks` resources have `properties.addressSpace.addressPrefixes` rewritten — first prefix only; multi-prefix VNets get a `requiresMultiPrefixDR` flag. Address prefixes inside peerings, route tables, and NSG rules are left alone. |
| First subnet prefix | First non-reserved subnet's `addressPrefix` → `$DR_SUBNET_PREFIX`. Subsequent subnets get a `requiresMultiSubnetDR` flag. |
| Read-only sanitisation (B4) | Properties listed in `data/readonly-properties.json` (global + per-type) are stripped before transformation so the template is re-deployable. |
| Deferred-handling flags | Cases the transform consciously deferred surface in `_reports/dr/flags.json` — operator action required. |
| Validation | `az deployment group validate` (non-fatal, reported). Live validation is the operator's responsibility on first run; structural correctness is asserted in `tests/round-1/`. |

**Files added in Round 1:**

| File | Purpose |
|---|---|
| `scripts/lib/ConvertForDR.psm1` | Pure (no Azure / no I/O) ARM transformation module. Exports `Convert-ForDR`, `Get-NameRewriteMap`, `Update-ResourceReferences`, `Remove-ReadOnlyProperties`, `Test-ReservedName`. |
| `data/reserved-names.json` | Allowlist of subnet names (`GatewaySubnet`, `AzureFirewallSubnet`, …) and fixed resource names that must not be prefixed. |
| `data/readonly-properties.json` | Global + per-type read-only properties (`provisioningState`, `etag`, storage `primaryEndpoints`, web/site `outboundIpAddresses`, …) stripped prior to redeployment. |
| `tests/Invoke-Validation.ps1` | Single-entry test runner walking `tests/round-N/`. |
| `tests/bicep-build-all.ps1` | Bicep compilation gate (no-op until Round 4 introduces modules). |
| `tests/round-1/Test-ConvertForDR.ps1` | Module-level assertions (B1, B2, B3, B4 + idempotency). |
| `tests/round-1/Test-GenerateDrConfig-Smoke.ps1` | End-to-end smoke test of the rewired Stage-5 wrapper. |

### Stage 7 — DR Deploy (Round 2 §R2.2)

Triggers on push to `main` when `bicep/regions/dr/**` changes; can also be re-run via `workflow_dispatch`. Runs as a separate workflow `.github/workflows/dr-deploy.yml`, not as a job inside `pr-compliance.yml`, because deploy semantics differ: it must run after merge, against the post-merge SHA.

| Item | Detail |
|---|---|
| Trigger | `push: branches: [main], paths: ['bicep/regions/dr/**']` + `workflow_dispatch` |
| Concurrency | `group: draac-dr-deploy, cancel-in-progress: false` (serialised; never cancel an in-flight deploy) |
| Auth | OIDC via `azure/login@v2`, same secrets as `pr-compliance.yml` |
| RG strategy | `az group create rg-<workload>-dr --location $DR_TARGET_REGION` (idempotent) per Bicep file |
| Deployment name | `draac-<sha7>-rg-<workload>-dr` — re-runs at the same commit SHA + same template are no-ops at Azure level |
| What-if | Runs first per file, persisted to `_reports/deploy/whatif-rg-<workload>-dr.json` |
| Throttling retry | Detects `429`/`Throttling*`/`TooManyRequests`; exponential backoff `[5, 15, 45, 135]` seconds before failing |
| Per-RG fault tolerance | Each file's failure is captured in `_reports/deploy/failures.json`; the loop continues to the next file |
| Final summary | `_reports/deploy/deploy-summary.json` with `processed`, `succeeded`, `failed`, `deploymentNames`, `runId`, `commitSha` |
| `Test-DRHealth.ps1` invocation | Marked as a comment placeholder; deferred to Round 4 §R4.2 |

**Files added in Round 2:**

| File | Purpose |
|---|---|
| `bicep/regions/primary/anchor.bicep` + `bicep/regions/dr/dr-anchor.bicep` | Anchor Storage Account workload that establishes the convention. Compiles clean and serves as the smoke-test target on first install. |
| `bicep/regions/README.md` | Documents the primary/DR-pair convention and the RG-naming rule (`rg-<workload>` / `rg-<workload>-dr`). |
| `scripts/lib/CommitBack.psm1` | Shared commit-back helper extracted from `commit-drift-readme.ps1`. Exports `Push-Branch -RepoRoot -Branch -RunId -Files -Message [-MaxRetries]`. Used by both `commit-drift-readme.ps1` (Stage 4) and `check-dr-coverage.ps1` (Stage 3 DR gate). |
| `scripts/review/check-dr-coverage.ps1` | DR coverage gate. Reads `pr-changes.json`, asserts/auto-generates DR companions for changed primary Bicep files. |
| `scripts/dr/deploy-dr-region.ps1` | Stage 7 deploy script. `[switch] -DryRun` allows the test harness to exercise the script without touching Azure. |
| `.github/workflows/dr-deploy.yml` | Stage 7 GitHub Actions workflow. |
| `tests/round-2/Test-CheckDrCoverage.ps1` | Coverage gate test: happy path, missing companion (auto-gen + failed branches), idempotency, empty change set, non-Bicep change ignored. |
| `tests/round-2/Test-DeployDrRegion.ps1` | Deploy script test (uses `-DryRun`): two-file walk, deterministic deployment names stable across re-runs, throttling-retry helper unit cases. |

### Stage 8 — Portal Drift Sync (Round 3 §R3.1–§R3.4)

Triggered on a daily schedule (`02:00 UTC`, well within Resource Graph's 14-day change-table retention) plus `workflow_dispatch`. Reverse-engineers changes made in the Azure Portal back into the repo as PRs (or `portal-sync-manual` issues when Bicep decompile is too dirty for automation).

| Item | Detail |
|---|---|
| Trigger | `schedule: cron "0 2 * * *"` + `workflow_dispatch (lookback-hours optional input)` |
| Concurrency | `group: draac-portal-drift-sync, cancel-in-progress: false` (sync runs serialised) |
| Auth | OIDC `azure/login@v2`; `GITHUB_TOKEN` for `gh pr create` / `gh issue create` |
| Detection | `Find-PortalChanges.ps1` runs the §R3.2 KQL against `resourcechanges` over the last `LookbackHours` (default 24) |
| Filter rules | (1) Skip if every changed property is in `data/readonly-properties.json`'s `global` list (no real change). (2) Skip system-managed resources by name OR RG: `NetworkWatcher*`, `DefaultResourceGroup*`, `cloud-shell*`, `AzureBackupRG*`. |
| Coalescing | Coalesce-then-skip — multiple changes against the same `targetResourceId` collapse into one entry holding the latest snapshot, then skip rules apply to that snapshot |
| Per-change pipeline | `Sync-PortalChange.ps1`: `az resource show` → wrap as ARM → `bicep decompile`. Clean output → `Convert-ForDR` (Round 1 module) → write primary + DR Bicep → branch `portal-sync/<yyyyMMddUTC>-<sha256-12>` → `Push-Branch` (CommitBack helper) → `gh pr create` |
| Dirty decompile fallback | `Send-ToManualQueue.ps1`: writes the original ARM JSON to `_reports/sync/manual-queue/<sha256-12>.json`, then `gh issue create --label portal-sync-manual` with reviewer checklist + `changedBy` mention/assignment. Idempotent: existing open issue with the same hash → no-op. |
| Deduplication | Both branches and issues are keyed by 12 hex chars of `SHA-256(lower(resourceId))`. Branches are scoped per UTC day (`yyyyMMdd-<hash>`) so a same-day re-run is a no-op; issues are open-issue-deduplicated by hash search. |
| Outputs | `_reports/sync/portal-changes.json`, `portal-changes-skipped.json`, `portal-changes-summary.json`, `sync-summary.json`, `manual-queue-summary.json` |

**Files added in Round 3:**

| File | Purpose |
|---|---|
| `.github/workflows/portal-drift-sync.yml` | Stage 8 workflow. Two jobs (detect → sync); `Send-ToManualQueue` runs inline inside the sync job per change rather than as a third top-level job. |
| `scripts/sync/Find-PortalChanges.ps1` | Detection. KQL via `az graph query`; `-DryRun -FixtureFile <path>` test seam exercises the same filter/coalesce pipeline against hand-rolled JSON. |
| `scripts/sync/Sync-PortalChange.ps1` | Per-change reverse-engineering. Type-slug naming (`microsoft-network-virtualnetworks` etc.), 12-char SHA-256 hash for branch + manual-queue alignment, `gh pr list --search` dedup. `-DryRun` skips all `az` / `gh` / `git` calls. Two env-var hooks for tests: `DRAAC_SYNC_FORCE_DIRTY_RESOURCE_IDS` and `DRAAC_SYNC_FORCE_EXISTING_PRS`. |
| `scripts/sync/Send-ToManualQueue.ps1` | Manual-queue fallback. Hash-keyed dedup against existing open `portal-sync-manual` issues. ARM JSON snapshot to `_reports/sync/manual-queue/<hash>.json`. Best-effort `--assignee` on `changedBy` when it looks like a GitHub login; mention-only otherwise. |
| `tests/round-3/Test-FindPortalChanges.ps1` | Detection test: 7-row mixed fixture (vnet-x coalescing, NetworkWatcher / AzureBackupRG / readonly-only skips), idempotency, malformed-row tolerance, `-DryRun` requires `-FixtureFile`. |
| `tests/round-3/Test-SyncPortalChange.ps1` | Per-change pipeline test: clean + dirty decompile cases via env-var force, two-change run, idempotency on branch-name re-derivation, helper unit tests. |
| `tests/round-3/Test-SendToManualQueue.ps1` | Manual-queue test: ARM snapshot path + hash determinism, `-DryRun` outcomes, dedup short-circuit on simulated existing issue. |
| `tests/fixtures/portal-changes/mixed.json` + `malformed.json` | Detection fixtures. |

### Round 4 — Make DR real (R4.1–R4.4)

Round 4 closes the gap between "DR companion files exist" and "DR is actually a working failover destination". Empty resource shells aren't DR — data has to replicate, traffic has to route, secrets have to sync. The round adds:

- **R4.1** — Per-resource-family DR Bicep modules under `bicep/modules/dr-*.bicep`. `Convert-ForDR` gains a registry-driven dispatch step that records which top-level resources should be replaced with module references (vs. naive copies) in the auto-generated DR companion. The registry lives at `data/dr-module-registry.json` and is loaded via `Initialize-DefaultDrModuleRegistry`.
- **R4.2** — `scripts/dr/Test-DRHealth.ps1` runs per-family probes against deployed DR resources after Stage 7 finishes. Output `_reports/dr-health/dr-health.json`; `DR_HEALTH_OK=true|false` exposed via `$GITHUB_OUTPUT` for the PR comment.
- **R4.3** — `bicep/modules/dr-traffic.bicep` — Azure Front Door Premium with primary (priority 1) + DR (priority 2) origins, WAF, optional custom domain. The Stage 3 DR coverage gate (`check-dr-coverage.ps1`) enforces that any PR touching a public-facing workload type (`Microsoft.Web/sites`, `Microsoft.ContainerService/managedClusters`, `Microsoft.Network/applicationGateways`) ships a DR companion that references this module.
- **R4.4** — `bicep/modules/dr-keyvault-sync.bicep` (+ a sub-module for the cross-RG role assignment) deploys a PowerShell-runtime Function App in the primary region. `scripts/secrets/Sync-KeyVaultSecrets.ps1` is the Function's `run.ps1` — Event Grid fires it on `Microsoft.KeyVault.SecretNewVersionCreated`, it reads the new secret version from the primary vault and writes it to the DR vault. Idempotent (skips if the DR vault already has the same value), `-DryRun` test seam.

#### R4.1 module-dispatch contract

`Convert-ForDR` returns a `Dispatched` array of records: `{ type, originalName, drName, module, resource }`. Dispatch runs *before* the name-rewrite transform so `originalName` is the input-template name and `drName` reflects the rewrite map (including the parent-segment rewrite for nested types like `Microsoft.Sql/servers/databases`). `Convert-ForDR` does NOT mutate the template based on dispatch — the caller (today: `check-dr-coverage.ps1`'s auto-gen path; future: a post-decompile rewriter) decides whether to swap naive resource declarations for `module` references. Default registry (loaded from `data/dr-module-registry.json`):

| Type | Module | Replication |
|---|---|---|
| `Microsoft.Sql/servers/databases` | `dr-sql.bicep` | Failover groups + automatic policy |
| `Microsoft.DocumentDB/databaseAccounts` | `dr-cosmos.bicep` | Multi-region writes + automatic failover |
| `Microsoft.Storage/storageAccounts` | `dr-storage.bicep` | RA-GZRS (Standard) / cross-region restore intent (Premium) |
| `Microsoft.KeyVault/vaults` | `dr-keyvault.bicep` | Soft-delete + purge protection (secrets sync via R4.4) |
| `Microsoft.DBforPostgreSQL/flexibleServers` | `dr-postgres.bicep` | Read replica (`createMode: Replica`) |
| `Microsoft.DBforMySQL/flexibleServers` | `dr-mysql.bicep` | Read replica (`createMode: Replica`) |
| `Microsoft.Cache/Redis` | `dr-redis.bicep` | Geo-replication via `linkedServers` (Premium-only — `@allowed` enforces) |

Cross-RG caveats baked in at module level: `dr-sql.bicep` and `dr-redis.bicep` use `existing` references to the primary server/cache. They must be deployed against the **primary** RG (the failover group / linked server lives there). `dr-keyvault-sync.bicep` invokes a sub-module `dr-keyvault-sync-drrole.bicep` with `scope: resourceGroup(<sub>, <rg>)` derived from the DR vault's id, because role assignments to a resource in another RG must be deployed in that RG (Bicep BCP139).

#### R4.4 secrets-sync architectural decision

DRaaC adopts **option (b): replicated Key Vaults with an event-driven sync runbook.** Each protected workload owns two vaults — `kv-<workload>` in the primary region and `kv-<workload>-dr` in the DR region — and an Event Grid system topic on `Microsoft.KeyVault.SecretNewVersionCreated` fires a PowerShell-runtime Azure Function (`Sync-KeyVaultSecrets`, see `scripts/secrets/Sync-KeyVaultSecrets.ps1`) that reads the new secret version from the primary vault and writes it to the DR vault. The Function App lives in the primary region (low-latency to the Event Grid system topic and the primary KV). Auth uses a system-assigned managed identity with `Key Vault Secrets User` on the primary vault and `Key Vault Secrets Officer` on the DR vault.

| Why (b)? | Detail |
|---|---|
| Blast radius matches the rest of DRaaC | Every other family in §R4.1 replicates per-workload (failover groups, multi-region Cosmos, GRS/RA-GRS storage). Per-workload KV pairs keep the DR boundary workload-scoped — a vault compromise or accidental purge in one workload never spills into another. |
| Idempotency + replayability are cheap | Event Grid retries up to 30 times over 24 h; the script's pre-write idempotency check (`Test-AlreadySynced`) makes any retry a no-op. No external state (queue, durable function) needed. |
| Operator mental model is simple | If the primary region is gone, point the workload at `kv-<workload>-dr`. The DR vault has `enablePurgeProtection: true` and `softDeleteRetentionInDays: 90` so a botched failover is recoverable inside the brief's RPO. |

**Alternatives considered** (kept reversible):

- **Shared global Key Vault with Private Endpoints.** Cheaper (one vault, one set of secrets, no sync code) but Azure Key Vault is *not* multi-region — the PE only routes traffic; if the vault's home region is down, every workload is down. Single-blast-radius failure mode unacceptable for the workloads in scope. Also, RBAC/access-policy changes propagate instantly across all workloads, increasing change risk.
- **Managed HSM with multi-region replication.** Azure Managed HSM is the only HSM-backed Microsoft offering that *can* replicate cryptographic material across regions in the same security domain. Cost is an order of magnitude higher (~$3/h per HSM minimum), the API surface differs from `Microsoft.KeyVault/vaults` (parallel code path through the rest of DRaaC), and the brief's workload set does not require FIPS 140-2 Level 3 hardware roots of trust. RTO/RPO is better but the cost/complexity delta does not pay off for the documented threat model.

**Reversibility:** to migrate off (b) later, deprovision per-workload DR vaults, point workloads at the new target, and decommission the sync Function + Event Grid system topic. The existing `Sync-KeyVaultSecrets.ps1` script can be re-purposed as a one-shot importer with a single `-EventFile` per secret. Existing replicated vaults stay in soft-delete for the retention window (90 days) as a rollback path before being purged.

**Files added in Round 4:**

| File | Purpose |
|---|---|
| `bicep/modules/dr-sql.bicep` | SQL DB DR via failover group + automatic policy. API `2023-08-01`. |
| `bicep/modules/dr-cosmos.bicep` | Multi-region Cosmos with automatic failover. API `2024-11-15`. |
| `bicep/modules/dr-storage.bicep` | Storage with RA-GZRS (Standard) / cross-region restore intent (Premium). API `2024-01-01`. |
| `bicep/modules/dr-keyvault.bicep` | Key Vault with soft-delete + purge protection. API `2024-11-01`. |
| `bicep/modules/dr-postgres.bicep` | Postgres read replica. API `2024-08-01`. |
| `bicep/modules/dr-mysql.bicep` | MySQL read replica. API `2024-12-30`. |
| `bicep/modules/dr-redis.bicep` | Redis geo-replication (Premium-only). API `2024-11-01`. |
| `bicep/modules/dr-traffic.bicep` | Azure Front Door Premium + WAF + optional custom domain. API `2025-06-01` / `2025-11-01`. |
| `bicep/modules/dr-keyvault-sync.bicep` | Function App + Event Grid system topic + role assignments + storage + App Insights + UAMI. APIs `2025-03-01` (Web), `2025-08-01` (Storage), `2025-02-15` (EventGrid), `2024-11-30` (ManagedIdentity), `2022-04-01` (Authorization), `2020-02-02` (Insights). |
| `bicep/modules/dr-keyvault-sync-drrole.bicep` | Cross-RG role-assignment sub-module (DR side). |
| `data/dr-module-registry.json` | Type → module mapping consumed by `Convert-ForDR`'s dispatch step. |
| `scripts/dr/Test-DRHealth.ps1` | Per-family DR health probes; `-DryRun -FixtureFile` test seam. Outputs `_reports/dr-health/dr-health.json` + `DR_HEALTH_OK` / `DR_HEALTH_SUMMARY` GitHub Actions outputs. |
| `scripts/secrets/Sync-KeyVaultSecrets.ps1` | The Function App's `run.ps1`. Two parameter sets (`EventGrid` / `Manual`) so both the Functions host and the test harness can drive it. `-DryRun` skips all `Az.KeyVault` calls. |
| `tests/round-4/Test-ConvertForDR-Dispatch.ps1` | Convert-ForDR dispatch contract (empty registry no-op, populated registry records 2 dispatches, idempotency, registry init from disk). |
| `tests/round-4/Test-CheckDrCoverage-FrontDoor.ps1` | R4.3 gate: public-facing primary + companion missing dr-traffic.bicep → coverage failed. |
| `tests/round-4/Test-DrModules-Compile.ps1` | Per-module `bicep build` + structural assertion (`metadata.dr` block present). Skip-if-no-CLI guard. |
| `tests/round-4/Test-DRHealth.ps1` | 6 scenarios: all-healthy / idempotent / SQL degraded / Postgres unhealthy / missing fixture / unknown via missing probeResult. |
| `tests/round-4/Test-DrTrafficModule.ps1` | Compile + structural (Premium SKU, two origins, WAF/security policy linkage, custom-domain conditional). |
| `tests/round-4/Test-SyncKeyVaultSecrets.ps1` | Happy path / wrong event type / forced in-sync / Bicep compile. |
| `tests/fixtures/dr-health/all-healthy.json` | Shared base fixture; tests mutate per-scenario. |

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
Edit `scripts/lib/ConvertForDR.psm1` — naming logic lives in `Get-NameRewriteMap` and `Invoke-Transformation`. `scripts/dr/generate-dr-config.ps1` is a thin wrapper and rarely needs touching for transformation changes.

### Add a reserved subnet/resource name (so it stays unprefixed)
Edit `data/reserved-names.json` — add to `subnetNames` or `fixedResourceNames`. No code change needed; the module loads this file on each run.

### Mark a property as read-only (strip it before DR redeploy)
Edit `data/readonly-properties.json` — add to `global` (every type) or `perType.<provider/type>` (one resource type). No code change needed.

### Support Terraform state comparison
Add a new script `scripts/review/match-terraform-state.ps1` that uses `terraform show -json` output and calls the same scan data for lookup.
