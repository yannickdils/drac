# Integrating DRaaC into an Existing Repository

> Companion to [Quick Start in README.md](../README.md#quick-start) and the [Setup Guide in DOCUMENTATION.md](DOCUMENTATION.md#setup-guide).
>
> The Quick Start assumes a greenfield repo. This guide covers what changes when you drop DRaaC into a repo that **already** has CI, IaC, branch protection, or production traffic.

---

## When to use this guide

You are here because at least one of these is true about your target repo:

- It already has files under `.github/workflows/`, `bicep/`, `scripts/`, or `data/`.
- It has its own CI on `main` that you don't want DRaaC to fight with.
- Branch protection on `main` is already configured (and may already be enforcing required checks you don't want to break).
- There is real traffic served from resources defined in IaC, so a first-run mistake has blast radius.

If none of that applies, the [Quick Start](../README.md#quick-start) is shorter and equivalent.

---

## TL;DR — the seven phases

| Phase | What you do | Reversible? |
|---|---|---|
| 1. Pre-flight audit | Read-only checks: file collisions, branch protection, federated creds, DR-region quota | yes |
| 2. Drop-in (additive) | Copy DRaaC files; resolve any collisions in a feature branch | yes |
| 3. Bootstrap | Run `setup-github.ps1` (or `setup.ps1` for ADO) | mostly — leaves App Reg + secrets |
| 4. Migrate primary IaC | Move existing primary Bicep into `bicep/regions/primary/<workload>.bicep` | yes (rename only) |
| 5. First PR | Open one PR; let Stage 3.5 auto-generate DR companions; **review the diff** | yes |
| 6. Seed the baseline | One push to `main` to create the first Stage 9 snapshot | yes |
| 7. Verify all 9 stages | Smoke-test forward loop, reverse loop, and slow drift | n/a |

Each phase is independently reversible up to Phase 5; once you merge a PR with auto-generated DR companions, rollback means deleting those files (they are pure additions).

---

## Agent-driven setup (alternative to manual Phases 1–3)

If you'd rather hand the audit, drop-in, and bootstrap to an AI coding agent (Claude Code, Copilot CLI, Cursor, Codex, …), this section gives you the MCP-server inventory, the one-time auth, and the paste-ready prompts. The agent does the keyboard work; you keep approval authority on every destructive step.

### What an agent can drive

| Phase | Agent-drivable? | What stays human |
|---|---|---|
| 1 Pre-flight audit | yes (read-only) | reading the report |
| 2 Drop-in | yes — copies files, opens PR | resolving collisions in `data/*.json` (behaviour-driving) |
| 3 Bootstrap | yes — but **confirm each Azure write** | approving App Reg creation, branch-protection overwrite |
| 4 Primary-Bicep migration | partly — agent renames; **you** decide what is in scope | deciding which workloads go first, hand-authoring Front Door wiring |
| 5 First PR | agent opens, monitors, summarises | **reviewing auto-generated DR companions before merge** |
| 6 Baseline seed | yes | n/a (push-on-merge) |
| 7 Smoke tests | yes | sandbox-subscription deploys (Stage 7), Portal-change tests (Stage 8) |

The **bold** items are the ones the agent must hand back to you. Don't let an agent merge the first PR; the auto-generated DR companions need eyes.

### MCP servers required

Pick the matrix that matches your CI target (GitHub or Azure DevOps). All three Microsoft + GitHub servers are first-party as of May 2026.

#### GitHub flavour

| Server | Purpose | Install (Claude Code) |
|---|---|---|
| [`github/github-mcp-server`](https://github.com/github/github-mcp-server) | Repo + secrets + branch protection + workflow runs | `claude mcp add github --transport http https://api.githubcopilot.com/mcp/ --header "Authorization: Bearer $GITHUB_PAT"` |
| [`microsoft/mcp` (Azure)](https://github.com/microsoft/mcp) | App Registration, federated creds, role assignments, Resource Graph | `/plugin marketplace add microsoft/azure-skills` then `/plugin install azure@azure-skills` |
| [Microsoft Learn MCP](https://learn.microsoft.com/training/support/mcp-get-started) | Grounding answers in current Azure docs | `/plugin marketplace add microsoftdocs/mcp` then `/plugin install microsoft-docs@microsoft-docs-marketplace` |
| [Bicep MCP](https://learn.microsoft.com/azure/azure-resource-manager/bicep/bicep-mcp-server) | Bicep authoring help during Phase 4 migration | `dnx -y Azure.Bicep.McpServer` (requires .NET 10 SDK) |

#### Azure DevOps flavour

| Server | Purpose | Install |
|---|---|---|
| [`microsoft/azure-devops-mcp`](https://github.com/microsoft/azure-devops-mcp) | Service connection, variable group, pipeline registration, branch policy | `claude mcp add ado -- npx -y @azure-devops/mcp <your-ado-org>` (or use the [public-preview remote endpoint](https://learn.microsoft.com/en-us/azure/devops/mcp-server/remote-mcp-server)) |
| [`microsoft/mcp` (Azure)](https://github.com/microsoft/mcp) | Same as above | same as above |
| Microsoft Learn MCP | Same as above | same as above |
| Bicep MCP | Same as above | same as above |

### One-time auth

The MCP servers delegate to the standard CLI tokens. Log in once before pasting the prompts:

```powershell
# Azure (used by the Azure MCP server + your shell)
az login --tenant <your-tenant-id>
az account set --subscription <primary-sub-id>

# GitHub flavour
gh auth login --hostname github.com --git-protocol https --web

# Azure DevOps flavour
az devops login --organization https://dev.azure.com/<your-ado-org>
```

Verify the agent sees the servers (Claude Code):

```
/mcp
```

You should see `github` (or `ado`), `azure`, and `microsoft-learn` listed as connected.

### The prompts

Paste these in order. Each prompt is self-contained — the agent doesn't need prior context. Each one ends with an explicit "stop and confirm" gate where the next step is destructive.

#### Prompt 1 — Pre-flight audit (Phase 1)

```
You're integrating DRaaC (https://github.com/<your-fork>/drac) into the
repository at <path-or-clone-url>. This is read-only. Don't write anything
yet.

Run the Phase 1 audit from docs/INTEGRATION.md§Phase-1:
1. List file collisions against the DRaaC tree.
2. Capture current branch protection on `main` and report which contexts
   would be lost if DRaaC's six required-check contexts overwrite them.
3. List federated credentials on any App Registration named
   `draac-pipeline-<org>-<repo>` and report whether the two subjects DRaaC
   needs (`pull_request` and `ref:refs/heads/main`) already exist with a
   different mapping.
4. Confirm DR-region quota for VM cores, public IPs, Key Vault, and Front
   Door Premium in <DR_TARGET_REGION>.
5. List existing GitHub Actions workflows that auto-commit to PR branches
   (race risk with Stage 4c).

Produce a single Markdown report. End with a section "Decisions needed"
listing each item I have to call before Phase 2.
```

#### Prompt 2 — Drop-in + integration PR (Phase 2)

```
Phase 2 of docs/INTEGRATION.md. Branch from `main` as
`feat/draac-integration`. Copy DRaaC into the repo (skip .git/, _reports/,
dr-config/, node_modules/). For each collision flagged in the Phase 1
report I just approved:
 - applied my decision verbatim — do not improvise.
 - if I marked an item "ask", stop and ask before moving on.

When the working tree is clean, commit with the message
`chore(draac): integration drop-in (Phase 2)` and push the branch. Open
a PR titled `DRaaC integration` against `main` with the body summarising
what was added and pointing reviewers to the Phase 1 report.

Do NOT run setup-github.ps1 in this prompt — that's Phase 3.
```

#### Prompt 3 — Bootstrap (Phase 3) — *destructive, confirm gates*

```
Phase 3 of docs/INTEGRATION.md. Drive setup-github.ps1 step-by-step using
the Azure + GitHub MCP servers. Confirm with me before EACH of these
writes:
 - creating or reusing the App Registration (Step 2)
 - creating either federated credential (Step 3)
 - assigning Reader/Contributor roles (Step 4)
 - setting any GitHub repo secret (Step 5)
 - PUTting branch protection on `main` (Step 6) — show me the diff vs
   what's currently configured first
 - PUTting the merge-queue config (Step 6b)

Use these env vars:
  GITHUB_REPO=<org>/<repo>
  AZURE_SUBSCRIPTION_IDS=<comma-list-or-ALL>
  DR_TARGET_REGION=<region>
  DR_VNET_ADDRESS_PREFIX=<cidr/16>
  DR_SUBNET_ADDRESS_PREFIX=<cidr/24>

After each confirmed step, verify the result via the corresponding MCP
tool (e.g. read back the secret list, the branch-protection contexts).
Stop on the first error; do not retry destructively.

When done, run the verification block from
docs/INTEGRATION.md§Phase-3 and paste the output.
```

For the **Azure DevOps flavour**, replace the bullet list above with: service connection (Manual), variable group `azure-compliance-pipeline-secrets` (with the variables from [DOCUMENTATION.md§3-Create-the-Variable-Group](DOCUMENTATION.md#3-create-the-variable-group)), pipeline registration of `.azure/pipelines/pr-compliance.yml`, and branch policy "Build validation".

#### Prompt 4 — Primary-Bicep migration (Phase 4)

```
Phase 4 of docs/INTEGRATION.md. For each existing primary Bicep file in
the repo (excluding bicep/regions/dr/ and bicep/modules/), produce a
migration plan that:
 - maps the file to bicep/regions/primary/<workload>.bicep
 - flags whether the workload is "public-facing" (exposes Web/AKS/AppGW)
   — those need a hand-authored DR companion with a dr-traffic.bicep
   reference; the auto-generator will fail the PR otherwise
 - lists every reference to the file from elsewhere in the repo that will
   need a path update

Output as a Markdown table. Don't move any files yet — show me the table
and wait for approval. Once I approve, do the renames in a single commit
to the same `feat/draac-integration` branch and push.
```

#### Prompt 5 — First PR walkthrough (Phase 5)

```
Phase 5 of docs/INTEGRATION.md. Watch the integration PR through the six
forward-loop jobs. Use the GitHub MCP to poll job status. When all six
report:

 - Stage 3.5 auto-generated DR companions: list every committed-back file
   with a one-line "what this file replicates" summary so I can spot-check
   without reading the diff.
 - Stage 4 CONFIGURATION-DRIFT.md: extract the critical-items section
   verbatim. Don't summarise — I need the raw list.
 - Stage 6 PR comment: paste the rendered Markdown as-is.

If any job fails, fetch the failing step's logs via GitHub MCP and
diagnose. Suggest the smallest possible fix. Do NOT push the fix without
my approval.

Do NOT merge. Stop after the report.
```

#### Prompt 6 — Baseline seed (Phase 6)

```
Phase 6 of docs/INTEGRATION.md. After the integration PR is merged
(I'll tell you), watch baseline-snapshot.yml. Once it lands a blob in
the draac-baseline container, verify by listing blobs via the Azure MCP
and confirm latest.txt is present. Report the blob URL and timestamp.
```

#### Prompt 7 — Smoke-test (Phase 7)

```
Phase 7 of docs/INTEGRATION.md. Drive the four smoke tests:
 1. Coverage gate — open a throwaway PR adding a trivial primary file
    with no companion. Verify Stage 3.5 commits a dr/ file back. Close
    the PR without merging.
 2. DR deploy — confirm dr-deploy.yml ran on the integration merge and
    that deployment names follow the `draac-<sha7>-rg-<workload>-dr`
    pattern. List the resource groups in the DR region via Azure MCP.
 3. Portal sync — make a tag change to a non-prod resource via Azure MCP
    (ASK ME FIRST, with the exact resource ID and tag value). Trigger
    portal-drift-sync.yml manually. Wait for completion. Report the
    resulting PR or manual-queue issue URL.
 4. Slow drift — when the next PR runs, confirm Section 6️⃣ of the PR
    comment shows a non-zero baseline reference timestamp.

Stop and ask before any Azure write.
```

### Hard rules for the agent

Keep these in your `CLAUDE.md` or system instructions while running the prompts:

- **Never auto-merge.** The first PR's auto-generated DR companions must be human-reviewed.
- **Never run `Test-DRHealth.ps1 -FailOnUnhealthy`** during integration — first runs report degraded probes for race-condition reasons that are not real problems.
- **Never widen role assignments** beyond Reader (scan scope) and Contributor (DR sub). If an MCP tool offers Owner, refuse.
- **Confirm every `gh api ... --method PUT` and every `az role assignment create`** before running.
- **Preserve `[skip ci]`** on any commit-back the agent makes — DRaaC's own commits use it to avoid loops, and an agent that strips it will trigger redundant runs.
- **Stop on any 403/401** — re-running with the same credentials won't fix permissions.

### What you save vs what you risk

Realistic time savings on a fresh adoption: ~3–4 h of keyboarding becomes ~45 min of approving prompts. The risk is that the agent silently widens a role assignment or quietly merges the first PR. The hard rules above are there because both have been observed.

Sources:
- [Azure MCP Server (microsoft/mcp)](https://github.com/microsoft/mcp/blob/main/servers/Azure.Mcp.Server/README.md)
- [Azure DevOps MCP Server (microsoft/azure-devops-mcp)](https://github.com/microsoft/azure-devops-mcp)
- [GitHub MCP Server (github/github-mcp-server)](https://github.com/github/github-mcp-server)
- [Microsoft Learn MCP install (Claude Code plugin)](https://learn.microsoft.com/training/support/mcp-get-started)
- [Azure DevOps Remote MCP Server (preview)](https://learn.microsoft.com/en-us/azure/devops/mcp-server/remote-mcp-server)
- [Bicep MCP Server](https://learn.microsoft.com/azure/azure-resource-manager/bicep/bicep-mcp-server)

---

## Phase 1 — Pre-flight audit (read-only)

### 1.1 File collision check

DRaaC writes into these top-level paths:

```
.github/workflows/   pr-compliance.yml, dr-deploy.yml, portal-drift-sync.yml, baseline-snapshot.yml
.azure/pipelines/    pr-compliance.yml                                       (ADO mirror)
bicep/modules/       dr-*.bicep                                              (R4 module library)
bicep/regions/       primary/<workload>.bicep, dr/dr-<workload>.bicep
scripts/             scan/, export/, review/, drift/, dr/, sync/, secrets/, lib/, report/
data/                reserved-names.json, readonly-properties.json,
                     dr-module-registry.json, unsupported-types.json
tests/               Invoke-Validation.ps1, bicep-build-all.ps1, round-1/ … round-5/, fixtures/
docs/                ARCHITECTURE.md, DOCUMENTATION.md, IMPLEMENTATION-LOG.md, INTEGRATION.md
CONFIGURATION-DRIFT.md, setup.ps1, setup-github.ps1
```

Run this from the target repo to find collisions:

```powershell
$paths = @(
  '.github/workflows/pr-compliance.yml','.github/workflows/dr-deploy.yml',
  '.github/workflows/portal-drift-sync.yml','.github/workflows/baseline-snapshot.yml',
  '.azure/pipelines/pr-compliance.yml',
  'bicep/modules','bicep/regions','scripts','data','tests',
  'docs/ARCHITECTURE.md','docs/DOCUMENTATION.md','docs/IMPLEMENTATION-LOG.md',
  'CONFIGURATION-DRIFT.md','setup.ps1','setup-github.ps1'
)
$paths | Where-Object { Test-Path $_ } | ForEach-Object { "COLLISION: $_" }
```

Resolve in Phase 2 — see [4.2 Collision strategies](#42-collision-strategies).

### 1.2 Branch-protection check

```powershell
gh api "repos/$env:GITHUB_REPO/branches/main/protection" --jq '.required_status_checks.contexts'
```

If contexts come back, `setup-github.ps1` will overwrite them in Step 6. Capture the list first so you can re-add anything DRaaC's six contexts don't cover. The DRaaC contexts are:

```
1 · Scan Azure Subscriptions
2 · Export & Document Environment
3 · Review Code vs Deployed State
4 · Configuration Drift Detection
5 · Generate DR Configuration
6 · Final Report & PR Annotation
```

(Stages 7/8/9 trigger on push/cron — they cannot gate a PR. See [setup-github.ps1:193-200](../setup-github.ps1#L193-L200).)

### 1.3 Federated-credential check

If your tenant already has an App Registration for this repo, `setup-github.ps1` reuses it ([setup-github.ps1:83-91](../setup-github.ps1#L83-L91)). Otherwise it creates `draac-pipeline-<org>-<repo>`. Two federated subjects get added — verify neither already exists with a different mapping:

```powershell
$app = az ad app list --display-name "draac-pipeline-${env:GITHUB_REPO -replace '/','-'}" --query "[0].id" -o tsv
if ($app) { az ad app federated-credential list --id $app --query "[].{name:name,subject:subject}" -o table }
```

The two subjects DRaaC needs:

- `repo:<org>/<repo>:pull_request` — used by `pr-compliance.yml` PR runs
- `repo:<org>/<repo>:ref:refs/heads/main` — used by `dr-deploy.yml`, `portal-drift-sync.yml`, `baseline-snapshot.yml`

### 1.4 DR-region quota

Pick `DR_TARGET_REGION` and confirm the subscription has VM cores, public IPs, Front Door, and KV quota in that region. The pre-deploy validators (`Test-SkuAvailability.ps1`, `Test-ApiVersionCompatibility.ps1`) catch SKU + API mismatches at PR time, but they don't catch quota — that surfaces at deploy time in Stage 7.

### 1.5 Existing-CI coexistence

DRaaC only adds workflow files; it doesn't touch yours. But if your existing CI also writes to `_reports/`, `dr-config/`, or commits back to PR branches (Stage 4c does this for `CONFIGURATION-DRIFT.md`), there's a race. Check:

```powershell
gh api "repos/$env:GITHUB_REPO/actions/workflows" --jq '.workflows[] | {name,path,state}'
```

Anything that auto-commits to PR branches (e.g. linters with auto-fix) needs to coordinate with DRaaC's commit-back, or one will rewrite the other's commit and the workflow will loop. Easiest fix: gate your auto-fix on `[skip ci]` not being in the latest commit message — DRaaC's commit-backs always carry it.

---

## Phase 2 — Drop-in (additive)

Branch:

```powershell
git checkout -b feat/draac-integration
```

Copy DRaaC's tree into the target repo. Skipping `node_modules/`, `_reports/`, and `dr-config/` is fine — they're build outputs.

```powershell
# from a checkout of github.com/<your-fork>/drac
$src = (Resolve-Path .).Path
$dst = '<path-to-target-repo>'
robocopy $src $dst /E /XD .git node_modules _reports dr-config /XF *.user
```

### 4.2 Collision strategies

| Collision | Strategy |
|---|---|
| `bicep/modules/dr-*.bicep` | DRaaC's are namespaced (`dr-sql.bicep`, etc.). If your repo has different `dr-*.bicep` files, rename yours. |
| `bicep/regions/primary/<workload>.bicep` | Keep yours — that's literally the convention DRaaC adopts. See Phase 4. |
| `data/*.json` | Diff carefully. `reserved-names.json` and `readonly-properties.json` are **behaviour-driving** — if you have local additions, merge them in, don't let DRaaC's copy clobber. |
| `scripts/lib/*.psm1` | If you have a `ConvertForDR.psm1` or `CommitBack.psm1`, you've already started this. Get in touch. |
| `.github/workflows/*.yml` collisions | Rename yours; DRaaC's workflow file names are load-bearing for branch protection (Step 6 wires the job names). |
| `CONFIGURATION-DRIFT.md` | If yours exists with content, rename to `CONFIGURATION-DRIFT.legacy.md` — DRaaC will recreate. |

Commit, push, open a PR. **Do not merge yet** — Phase 3 needs the PR open so it can run.

---

## Phase 3 — Bootstrap

```powershell
$env:GITHUB_REPO              = "your-org/your-repo"
$env:AZURE_SUBSCRIPTION_IDS   = "sub-id-1,sub-id-2"   # or "ALL" + MANAGEMENT_GROUP_ID
$env:DR_TARGET_REGION         = "northeurope"
$env:DR_VNET_ADDRESS_PREFIX   = "10.1.0.0/16"
$env:DR_SUBNET_ADDRESS_PREFIX = "10.1.0.0/24"
./setup-github.ps1
```

What it does ([setup-github.ps1](../setup-github.ps1)):

| Step | Action | Idempotent? |
|---|---|---|
| 1 | Resolve tenant + primary subscription | yes (read-only) |
| 2 | Create or reuse App Registration `draac-pipeline-<org>-<repo>` | yes |
| 3 | Create OIDC federated credentials for PR + main subjects | yes |
| 4 | Assign Reader on each scan-scope subscription + Contributor on the DR sub | yes |
| 5 | Set repo secrets (`AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID(S)`, `DR_*`) | yes |
| 6 | Apply branch protection on `main` with the six DRaaC contexts | overwrites |
| 6b | Enable merge queue (squash, all-green grouping) | best-effort |

If Step 6 overwrites a context list you care about, re-add yours via:

```powershell
gh api "repos/$env:GITHUB_REPO/branches/main/protection" --method PUT --input <merged.json>
```

**Verify before continuing:**

```powershell
gh secret list --repo $env:GITHUB_REPO       # should show the 7 DRaaC secrets
gh api "repos/$env:GITHUB_REPO/branches/main/protection" --jq '.required_status_checks.contexts'
```

If you also want Stage 9 slow-drift, provision a Storage Account, give the federated identity `Storage Blob Data Contributor` on it, and set:

```powershell
gh secret set DRAAC_BASELINE_STORAGE_ACCOUNT --body "<account-name>" --repo $env:GITHUB_REPO
```

Stage 9 no-ops gracefully when this secret is unset — leave it off if you want to defer baseline persistence.

---

## Phase 4 — Migrate existing primary Bicep into the convention

DRaaC's coverage gate (Stage 3.5) walks `bicep/regions/primary/`. Every file in that directory **must** have a matching `bicep/regions/dr/dr-<workload>.bicep` companion or the gate fails. See [bicep/regions/README.md](../bicep/regions/README.md) for the full convention.

### Decision tree per workload

```
Existing primary Bicep file?
├── Yes → move into bicep/regions/primary/<workload>.bicep
│        (keep filename short — it derives RG name `rg-<workload>` and `rg-<workload>-dr`)
│
└── No (greenfield workload) → author bicep/regions/primary/<workload>.bicep fresh
```

### Public-facing workloads

If the workload exposes any of `Microsoft.Web/sites`, `Microsoft.ContainerService/managedClusters`, or `Microsoft.Network/applicationGateways`, the DR companion **must** reference `bicep/modules/dr-traffic.bicep` ([Round 4 §R4.3](DOCUMENTATION.md#r43--azure-front-door-traffic-routing-bicepmodulesdr-trafficbicep)). The auto-generator can't synthesise this wiring — the gate fails the PR with a copy-paste-ready remediation snippet. Plan to hand-author the companion for these workloads.

### What to migrate first

Pick a small, low-risk workload (a Storage Account, a Key Vault) for the very first PR. Save the public-facing workloads for after Phase 7 verification.

---

## Phase 5 — First PR

Open the integration PR (from Phase 2) and watch the six jobs:

```powershell
gh pr checks --repo $env:GITHUB_REPO   # while the PR is open
```

Expected first-run behaviours:

| Stage | First-run outcome |
|---|---|
| 1 Scan | Full inventory of every subscription DRaaC has Reader on. Slow on large estates (~100s of resources/min). |
| 2 Export | ARM-template export per RG. Some RGs may fail to export (e.g. Data Factory) — that's logged, not fatal. |
| 3 Review | Compares PR-touched IaC vs scan results. First run touches almost everything, so expect the comment to be long. |
| 3.5 DR coverage gate | Auto-generates `dr/dr-<workload>.bicep` for every primary file you migrated in Phase 4 (except public-facing — those fail). The gate commits the auto-generated files back to the PR branch as `chore(draac): auto-generate DR companions [skip ci]`. |
| 4 Drift | First-run `CONFIGURATION-DRIFT.md` will likely be long. Read it once; most "deployed but not in code" warnings are pre-existing. |
| 5 DR generation | Produces `dr-config/` artifact. |
| 6 Report | PR comment with all six sections. |

**Critical:** review the auto-generated DR companions in the PR diff before merging. The decompile is best-effort; some types come back dirty and need hand-editing.

---

## Phase 6 — Seed the baseline

Stage 9 needs at least one snapshot in the blob container before slow drift is meaningful. After Phase 5 merges:

1. The `baseline-snapshot.yml` workflow runs automatically on push to `main`.
2. Verify a blob landed: `az storage blob list --account-name $env:DRAAC_BASELINE_STORAGE_ACCOUNT --container-name draac-baseline -o table`.
3. The next PR's `slow-drift.json` will compare against that seed.

Until step 1 happens, `Compare-AgainstBaseline.ps1` emits an empty report with `baseline.available = false` ([docs/DOCUMENTATION.md:589](DOCUMENTATION.md#L589)). That's expected — not an error.

---

## Phase 7 — Verify all 9 stages

| Stage | How to verify |
|---|---|
| 1–6 (forward loop) | First PR landing green confirms 1–6. |
| 3.5 (coverage gate) | Open a throwaway PR adding a `bicep/regions/primary/<workload>.bicep` with no companion. Gate should auto-generate `dr/dr-<workload>.bicep` and commit it back. |
| 7 (DR deploy) | Merge the first PR. `dr-deploy.yml` runs against `main`. Check the Actions log for "draac-<sha7>-rg-<workload>-dr" deployment names. |
| 8 (portal sync) | Make a small Portal change to a non-production resource (e.g. add a tag). Wait for the daily 02 UTC run, or trigger manually: `gh workflow run portal-drift-sync.yml`. Expect either a `[portal-sync]` PR or a `portal-sync-manual` issue. |
| 9 (baseline) | Open a PR after the first push-to-main snapshot. PR comment's section 6️⃣ should show "Slow drift (since baseline)" with a non-zero baseline reference timestamp. |

Health probes (`Test-DRHealth.ps1`) run automatically after Stage 7 ([scripts/dr/deploy-dr-region.ps1](../scripts/dr/deploy-dr-region.ps1)). Probe failures are warnings, not deploy-fatal — that's by design. To make them fatal in your environment, invoke `Test-DRHealth.ps1 -FailOnUnhealthy` from a follow-on workflow step.

---

## Tenant / subscription constraints

| Constraint | Where it bites | Mitigation |
|---|---|---|
| Cross-RG role assignment for KV sync | Round 4 §R4.4: `dr-keyvault-sync-drrole.bicep` is a separate sub-module because Bicep BCP139 forbids cross-scope inline role assignments. | Already handled — just be aware deploy targets two RGs. |
| `dr-sql.bicep` / `dr-redis.bicep` deploy to **primary** RG | Failover groups + Redis linked servers live on the primary, not the DR side. | Stage 7's `deploy-dr-region.ps1` doesn't auto-route this yet. Operator wires the deploy with `--resource-group rg-<workload>` (no `-dr` suffix) for these two families. |
| `AZURE_SUBSCRIPTION_IDS=ALL` | Step 4 of `setup-github.ps1` skips role assignment in this mode ([setup-github.ps1:150-157](../setup-github.ps1#L150-L157)) — you must assign Reader at MG/tenant level manually. | Use a specific subscription list during integration; switch to `ALL` only after the first run lands green. |
| Front Door Premium availability | R4.3 traffic module assumes Front Door Premium is available in the tenant. | Check `az afd profile create --sku Premium_AzureFrontDoor --dry-run` against an empty RG before adding public-facing workloads. |

---

## Rollback / safe-uninstall

DRaaC is purely additive — there is no destructive uninstall, and it does not modify resources outside its own scope. To remove:

```powershell
# 1. Remove the workflows so nothing new runs
git rm .github/workflows/pr-compliance.yml `
       .github/workflows/dr-deploy.yml `
       .github/workflows/portal-drift-sync.yml `
       .github/workflows/baseline-snapshot.yml

# 2. (Optional) remove DRaaC scripts/data/bicep
git rm -r scripts/scan scripts/export scripts/review scripts/drift `
          scripts/dr scripts/sync scripts/secrets scripts/lib scripts/report `
          data/reserved-names.json data/readonly-properties.json `
          data/dr-module-registry.json data/unsupported-types.json `
          bicep/modules/dr-*.bicep tests/round-* tests/Invoke-Validation.ps1

# 3. Remove branch protection contexts that no longer have a workflow producing them
gh api "repos/$env:GITHUB_REPO/branches/main/protection" --method PUT --input <new-protection.json>

# 4. (Optional) revoke Azure access
az ad app delete --id $(az ad app list --display-name "draac-pipeline-${env:GITHUB_REPO -replace '/','-'}" --query "[0].id" -o tsv)

# 5. (Optional) drop the secrets
foreach ($s in @('AZURE_CLIENT_ID','AZURE_TENANT_ID','AZURE_SUBSCRIPTION_ID','AZURE_SUBSCRIPTION_IDS',
                 'DR_TARGET_REGION','DR_VNET_ADDRESS_PREFIX','DR_SUBNET_ADDRESS_PREFIX',
                 'DR_NAMING_PREFIX','DRAAC_BASELINE_STORAGE_ACCOUNT')) {
  gh secret delete $s --repo $env:GITHUB_REPO 2>$null
}
```

What stays behind:

- The `dr/dr-<workload>.bicep` files Stage 3.5 generated. Delete or keep — they're regular Bicep.
- The Stage 7 deployments in Azure (RGs `rg-<workload>-dr`). Delete via `az group delete --name rg-<workload>-dr --yes` if you don't want them.
- The Stage 9 baseline blob container (`draac-baseline`). Delete via `az storage container delete`.
- Any Front Door profiles created by R4.3 traffic modules — these affect live traffic. Confirm DNS no longer points at them before deleting.

---

## Where to look when something goes wrong

| Symptom | Where to look |
|---|---|
| First PR run hits 403 | Service principal Reader assignment ([DOCUMENTATION.md → Pipeline fails at scan stage with 403](DOCUMENTATION.md#pipeline-fails-at-scan-stage-with-403)) |
| Coverage gate keeps re-committing the same file | Auto-fix loop with another workflow — see [Phase 1.5](#15-existing-ci-coexistence) |
| Portal sync PRs never appear | Federated credential for `refs/heads/main` missing — re-run `setup-github.ps1` |
| Slow drift section says "baseline.available = false" forever | `DRAAC_BASELINE_STORAGE_ACCOUNT` unset, or the federated identity lacks `Storage Blob Data Contributor` on the container |
| `dr-keyvault-sync.bicep` deploy fails with BCP139 | The cross-RG role assignment sub-module wasn't included — check `dr-keyvault-sync-drrole.bicep` is in `bicep/modules/` |
| DR companion has wrong references after Convert-ForDR | Ref pattern not covered by Round 1 B2 — see [DOCUMENTATION.md → DR template references the original (un-prefixed) resource name](DOCUMENTATION.md#dr-template-references-the-original-un-prefixed-resource-name) |

---

_Last updated 2026-05-07. Append-only; if a phase stops being accurate, fix it in place and bump this date._
