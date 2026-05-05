# DRaaC — Implementation Log

> **Purpose.** Resumable change log for the multi-round DRaaC implementation driven by `IMPLEMENTATION-BRIEF.md`. Each entry records what landed, when, and what's left so a fresh session (or a fresh engineer) can pick up exactly where the previous one stopped.
>
> **Read order on resume.** (1) This log, top-to-bottom. (2) `IMPLEMENTATION-BRIEF.md` for the round you're starting. (3) Recent commits via `git log --oneline -20`.

---

## Status snapshot

| Round | Status | Landed | Validation |
|---|---|---|---|
| Pre-work — Validation harness | Done | `tests/` runner + 5 fixtures | `pwsh tests/Invoke-Validation.ps1 -Round 1` |
| Round 1 — Correctness fixes (B1, B2, B3, B4) | Done | `scripts/lib/ConvertForDR.psm1`, `data/`, rewired Stage 5 | All assertions pass; PSScriptAnalyzer clean |
| Round 2 — Close Loop A (A1, A2) | Done | DR coverage gate, `bicep/regions/{primary,dr}/`, Stage 7 deploy workflow, shared `CommitBack.psm1` | 4/4 tests pass; PSScriptAnalyzer clean (12 files); both anchor Bicep files compile |
| Round 3 — Open Loop B (A3) | Not started | — | — |
| Round 4 — Make DR real (A4, A5, E4) | Not started | — | — |
| Round 5 — Polish (C1, C2, D1–D3, E1–E3, E5) | Not started | — | — |
| Side track: Demo (`draac-demo/`) | Done | 10 files per `Demo handoff.md` | Bicep compiles, PSScriptAnalyzer clean (parent settings), generator round-trips |

---

## How to resume mid-implementation

1. `git log --oneline main -20` — see what's already committed.
2. Read the latest entry under "Round-by-round detail" below.
3. If `Status` is "In progress", check the **Remaining for this round** subsection — that's the next concrete step.
4. Re-read the corresponding round in `IMPLEMENTATION-BRIEF.md` before writing code.
5. Run the harness from a fresh checkout to confirm the baseline is green:
   ```powershell
   pwsh tests/Invoke-Validation.ps1 -Round 1
   ```
6. Run PSScriptAnalyzer with the project settings:
   ```powershell
   Invoke-ScriptAnalyzer -Path scripts/ -Recurse -Settings PSScriptAnalyzerSettings.psd1
   ```

---

## Round-by-round detail

### Pre-work — Validation harness

**Landed 2026-05-04.**

| File | Purpose |
|---|---|
| `tests/Invoke-Validation.ps1` | Single-entry test runner. Walks `tests/round-N/` and runs every `Test-*.ps1`. Supports `-Round 1,2,...` filtering and `-UpdateSnapshots` (latter unused this round; reserved for future snapshot tests). |
| `tests/bicep-build-all.ps1` | Bicep compilation gate. No-op until Round 4 introduces `bicep/modules/`; emits a clear "skipping" message when those dirs are absent. |
| `tests/fixtures/exports/simple-rg/template.json` | Baseline happy-path ARM template (storage + NSG). |
| `tests/fixtures/exports/gateway-subnet-rg/template.json` | VNet with `GatewaySubnet`, `AzureFirewallSubnet`, `AzureBastionSubnet`, `RouteServerSubnet`, plus a normal subnet — proves B1 reserved-name handling. |
| `tests/fixtures/exports/peered-vnet-rg/template.json` | Two VNets + a peering + a route table + cross-resource `dependsOn` and `resourceId(...)` references — proves B2 reference rewriting. |
| `tests/fixtures/exports/multi-prefix-vnet-rg/template.json` | VNet with three address prefixes and two subnets — proves B3 multi-prefix flag. |
| `tests/fixtures/exports/readonly-props-rg/template.json` | Storage / Web / Managed Identity with read-only properties — proves B4 stripping. |
| `tests/fixtures/README.md` | Documents that fixtures are synthesised, what each proves, and how to refresh from a real subscription. |
| `PSScriptAnalyzerSettings.psd1` | Project-wide analyzer config; documents the two brief-mandated rule overrides (`PSAvoidUsingWriteHost`, `PSUseBOMForUnicodeEncodedFile`). |

**Deferred (not in this session):** real-subscription fixture capture, snapshot tests, the 200-resource fixture for Round 5 / C1.

---

### Round 1 — Correctness fixes (B1, B2, B3, B4)

**Landed 2026-05-04.**

Goal: make `Convert-ForDR` produce templates that actually deploy. Extract the recursive transform out of `scripts/dr/generate-dr-config.ps1` into `scripts/lib/ConvertForDR.psm1`, fix the four known correctness bugs, and prove it with the validation harness.

| File | Purpose |
|---|---|
| `data/reserved-names.json` | Subnet allowlist (`GatewaySubnet`, `AzureFirewallSubnet`, …) + fixed resource names. Loaded by the module on each transform. |
| `data/readonly-properties.json` | Global (`provisioningState`, `etag`, `creationTime`, …) + per-type (`Microsoft.Storage/storageAccounts`, `Microsoft.Web/sites`, `Microsoft.ManagedIdentity/userAssignedIdentities`) read-only properties. |
| `scripts/lib/ConvertForDR.psm1` | New pure-function module. Exports `Convert-ForDR`, `Get-NameRewriteMap`, `Update-ResourceReferences`, `Remove-ReadOnlyProperties`, `Test-ReservedName`. Implements B1 type-aware prefixing, B2 two-pass reference rewriting (longest-key-first iteration to avoid prefix collisions), B3 VNet-scoped address handling with deferred-handling flags, B4 read-only stripping. Idempotent (re-running on already-transformed input is a no-op — proven by the test). |
| `scripts/dr/generate-dr-config.ps1` | Rewired to import the module and call `Convert-ForDR`. Now also emits `flags.json` aggregating all deferred-handling flags across the run, and surfaces them in `dr-metadata.json` per-RG and `DR-README.md`. |
| `tests/round-1/Test-ConvertForDR.ps1` | Module-level assertions over each fixture (47 assertions; covers B1, B2, B3, B4, idempotency). |
| `tests/round-1/Test-GenerateDrConfig-Smoke.ps1` | End-to-end smoke test: builds a synthetic ExportDir from fixtures, runs the rewired wrapper, asserts expected output files + content. |
| `docs/ARCHITECTURE.md` | Updated Stage 5 section to describe the module + data files; added "Files added in Round 1" subsection; updated the Extending section. |
| `docs/DOCUMENTATION.md` | Updated Stage 5 documentation to describe B1–B4 transformations explicitly; added two new troubleshooting entries (broken B2 references, missing `data/reserved-names.json`). |

**Validation results (this session):**

```
pwsh tests/Invoke-Validation.ps1 -Round 1
Round Test                            ExitCode Status Duration
1     Test-ConvertForDR.ps1                  0 PASS   ~0.4s
1     Test-GenerateDrConfig-Smoke.ps1        0 PASS   ~4.0s
Total: 2  Pass: 2  Fail: 0
```

```
Invoke-ScriptAnalyzer -Path scripts/ -Recurse -Settings PSScriptAnalyzerSettings.psd1
→ No warnings/errors.
```

**Acceptance per brief — what is and isn't covered:**

| Brief acceptance | Covered? | Notes |
|---|---|---|
| Module produces templates that pass `az deployment group validate` | **Deferred** | Not run in this session — no sandbox subscription available. The unit + smoke tests prove structural correctness; live validation falls to the operator on first run. |
| PSScriptAnalyzer reports zero new warnings | ✅ | Two rules excluded project-wide via `PSScriptAnalyzerSettings.psd1` because the brief explicitly mandates `Write-Host` and UTF-8-no-BOM. Five per-function suppressions added with justifications where the brief's API contract or PowerShell closure semantics force a deviation. |
| All Round 1 fixtures produce valid DR templates | ✅ (offline) | Gateway, peered VNet, multi-prefix VNet, read-only-props, simple-rg all transformed and asserted. |

**Notable design decisions (worth knowing for Round 2+):**

- `Convert-ForDR` returns a wrapper `[PSCustomObject]@{ Template; Flags; Map; Entries }` rather than a bare template, because B3 requires emitting deferred-handling flags. The brief's Convert-ForDR contract says "transformed object out", but the brief later requires `flags.json` — wrapper is the lesser evil. `generate-dr-config.ps1` consumes `Result.Template` and `Result.Flags`.
- Reference-rewrite map is keyed by name only (not `(type, name)`). Two top-level resources sharing a name across types would both get the same `dr-` prefix, so the substitution result is unambiguous in practice. If this assumption breaks, switch to a `(type, name)` keyed map and update `Update-ResourceReferences` to dispatch by enclosing context.
- B1's reserved-subnet awareness is extended to subnet address-prefix rewriting in B3: if the first subnet is reserved (e.g. `GatewaySubnet`), the impl rewrites the first **non-reserved** subnet instead. The brief's literal "first" is naive; this version matches operator intent without breaking the brief's contract.
- The module uses `$obj.PSObject.Properties[$name]` (indexer) rather than `$obj.PSObject.Properties.Name -contains $name` because the latter throws under `Set-StrictMode -Version Latest` when the property collection is empty (verified during this session). All callers must use the indexer pattern when interacting with PSCustomObjects that may have zero properties.

---

## Deferred / known gaps

These items are explicitly out of scope for the current session and must be picked up later:

- **Live `az deployment group validate`.** The brief's Round 1 acceptance includes deploying to a sandbox sub. This session asserts structural correctness only; live validation is the operator's responsibility on first run.
- **Real-environment fixtures.** Brief asks for fixtures captured from a non-prod sub. We synthesise minimal ARM templates and mark them as such in `tests/fixtures/README.md`.
- **PSRule for Azure.** Listed in pre-work but only meaningfully exercised once Bicep modules exist (Round 4). Skipped this session.
- **200-resource RG fixture.** Synthesise during Round 5 / C1.

---

## Round 1 commit

The Round 1 work landed as a single commit `feat(draac): Round 1 + validation harness — extract Convert-ForDR module, fix B1–B4`. See `git log --oneline` for the SHA.

---

## Round 2 — Close Loop A (A1 DR coverage gate, A2 DR deploy)

**Landed 2026-05-05.** Goal: make "DR by default" enforced at PR time and actually deployed post-merge.

**Approach:** parallel agents. The main thread bootstrapped the `bicep/regions/{primary,dr}/anchor.bicep` convention; two general-purpose agents then implemented R2.1 and R2.2 in parallel against disjoint file scopes; the main thread synthesized, wired the coverage gate into `pr-compliance.yml`, fixed three bugs the agents could not catch (they had no shell access for self-validation), and ran the full test + analyzer suite.

**Files added / modified:**

| File | Notes |
|---|---|
| `bicep/regions/primary/anchor.bicep` + `bicep/regions/dr/dr-anchor.bicep` | Anchor Storage Account workload (mirrors the demo's pattern). Establishes the convention so the coverage gate has at least one PR-checkable workload from day one. Both compile clean. |
| `bicep/regions/README.md` | Documents the convention and the `rg-<workload>` / `rg-<workload>-dr` RG-naming rule. |
| `scripts/lib/CommitBack.psm1` | New shared module. Exports `Push-Branch -RepoRoot -Branch -RunId -Files -Message [-MaxRetries]` (returns `[bool]`). Auto-appends `[skip ci]` to the commit message so the PR workflow doesn't retrigger itself. |
| `scripts/drift/commit-drift-readme.ps1` | Reduced from 93 to 46 lines — now a thin wrapper over `Push-Branch`. CLI parameter contract preserved. |
| `scripts/review/check-dr-coverage.ps1` | DR coverage gate. Reads `pr-changes.json`, asserts/auto-generates DR companions for changed primary Bicep files. Calls `Convert-ForDR` from Round 1's module on the compiled ARM. |
| `scripts/dr/deploy-dr-region.ps1` | Stage 7 deploy script. Has a `[switch] -DryRun` test seam so the harness can exercise the script offline. Throttling retry helper `Invoke-AzWithRetry -Operation -ScriptBlock [-BackoffSeconds]`; default backoff `@(5, 15, 45, 135)`. Per-RG fault tolerance writes `_reports/deploy/failures.json`; final summary at `_reports/deploy/deploy-summary.json`. `Test-DRHealth` invocation marked with a placeholder comment per R4.2 deferral. |
| `.github/workflows/dr-deploy.yml` | Stage 7 GitHub Actions workflow. Trigger: `push` to `main` with `paths: [bicep/regions/dr/**]` + `workflow_dispatch`. Concurrency `group: draac-dr-deploy, cancel-in-progress: false`. |
| `.github/workflows/pr-compliance.yml` | `review` job: bumped `contents` permission to `write` (for commit-back); added Bicep CLI install step; added DR coverage gate step (`id: dr-coverage`); added `coverage-results` artifact upload. |
| `tests/round-2/Test-CheckDrCoverage.ps1` | Coverage gate test: happy path (companion exists), idempotency, missing companion (auto-gen branch when `bicep` is on PATH; failed branch otherwise), empty change set, non-Bicep change ignored. |
| `tests/round-2/Test-DeployDrRegion.ps1` | Deploy test (`-DryRun`): two-file walk, deterministic deployment names stable across re-runs, four `Invoke-AzWithRetry` cases (happy, throttle-recover, hard-fail, persistent-throttle). |
| `docs/ARCHITECTURE.md` | Added Stage 7 ASCII block; added Round-2 file inventory; updated Stage 3 to describe the DR coverage gate. |
| `docs/DOCUMENTATION.md` | Added "Stage 3.5: DR Coverage Gate" and "Stage 7: DR Deploy" sections. |

**Three bugs caught and fixed during integration** (agents could not run their own validation, so these surfaced when the main thread ran the harness):

1. **`Get-ChangedPrimaryBicepPath` double-wrap.** The function used `return ,@($paths.ToArray() | Sort-Object -Unique)` and the caller wrapped again with `@(...)`, producing a 1-element array containing the real array — iterating gave a sub-array that couldn't bind to `[string] $PrimaryPath`. Dropped the function-side comma trick; relied on the caller wrap.

2. **Single-element JSON array unwrap.** When `pr-changes.json` contained one entry, `ConvertFrom-Json` unwrapped to a bare `PSCustomObject`. The script's `IEnumerable` check then missed it and reported "0 primary Bicep files changed." Fixed `Get-ChangedPrimaryBicepPath` to detect three cases: multi-item array, single PSCustomObject with a `path` field (1-element unwrap), wrapped `{ changes: [...] }` object.

3. **Empty pipeline + `Set-Content`.** The test helper `New-PrChangesFile` piped `$entries.ToArray() | ConvertTo-Json -AsArray | Set-Content` to write `pr-changes.json`. With zero entries, the pipeline emits nothing and Set-Content silently skips the file — the script then warned "PR changes file not found." Forced a literal `[]` write for the empty case.

**Validation results:**

```
pwsh tests/Invoke-Validation.ps1 -Round '1','2'
Round Test                            ExitCode Status
1     Test-ConvertForDR.ps1                  0 PASS
1     Test-GenerateDrConfig-Smoke.ps1        0 PASS
2     Test-CheckDrCoverage.ps1               0 PASS
2     Test-DeployDrRegion.ps1                0 PASS
Total: 4  Pass: 4  Fail: 0
```

```
Invoke-ScriptAnalyzer -Settings PSScriptAnalyzerSettings.psd1   →  0 issues across 12 files
pwsh tests/bicep-build-all.ps1 -Path bicep/regions               →  2 succeeded, 0 failed
```

**Acceptance per brief — what is and isn't covered:**

| Brief acceptance (R2.3) | Covered? | Notes |
|---|---|---|
| Open a PR adding a new primary Bicep; gate auto-generates DR companion | ✅ structurally | Auto-gen path proven end-to-end in `Test-CheckDrCoverage.ps1` (creates an `orphan.bicep`, runs the gate, asserts `dr-orphan.bicep` materialises on disk). |
| PR re-validates green after auto-generation | ✅ structurally | Idempotency assertion: re-running the gate on the same repo state produces an identical report. |
| Deploy workflow runs on merge, what-if + deployment succeed | **Deferred** | Cannot execute without an Azure subscription. The `-DryRun` test exercises the entire script flow and asserts deterministic outputs. |
| Re-run deploy is a no-op | ✅ structurally | Deterministic deployment name `draac-<sha7>-rg-<workload>-dr` proven stable across re-runs in the test; Azure-side dedup is documented behaviour. |
| `setup-github.ps1` updates branch protection to require Stage 7 | **Deferred** | The Stage 7 workflow runs on push to `main`, not on PR — so it does NOT need branch protection (it can't gate a PR). The brief's wording predates that design choice. Worth confirming with the operator on first install. |

**Notable design decisions (worth knowing for Round 3+):**

- **`-DryRun` test seam on `deploy-dr-region.ps1`.** The script has a `[switch] -DryRun` flag that skips `az group create / what-if / deploy` and writes synthetic outputs. Tests never touch Azure; the production workflow never sets the flag. Cleanest way to isolate Azure-calling code from a unit-test boundary without mocking infrastructure.
- **`CommitBack.psm1` extraction was scope creep, but worth it.** The R2.1 agent observed it would have to copy 60-odd lines of git-auth + retry logic from `commit-drift-readme.ps1`. Extracting one shared module saves the duplication and means future commit-back patterns (Round 3's portal-sync PR creation, for example) inherit the same auth + retry semantics. CLI contract of `commit-drift-readme.ps1` is unchanged so this is invisible to the existing `pr-compliance.yml`.
- **Stage 7 lives in its own workflow, not as a job in `pr-compliance.yml`.** Brief implies a single pipeline; the implementation diverges because deploy must run *after* merge against the post-merge SHA. Branch protection / merge-queue enforcement should still gate `pr-compliance.yml` (which is what blocks merge); `dr-deploy.yml` runs unconditionally on merge to `main`.

---

## Side track — `draac-demo/` subfolder

**Landed 2026-05-04.** Driven by `Demo handoff.md` (a separate spec from `IMPLEMENTATION-BRIEF.md`). Demo is a 10-file, end-to-end DRaaC demonstration meant to be clone-able and runnable on a fresh Azure subscription in <10 minutes. Currently nested inside this repo as `draac-demo/`; can be extracted to its own repo later without code changes (only the `PSScriptAnalyzerSettings.psd1` link to the parent would need to be replicated).

**Files added** (exactly the 10 required by the handoff — no `IMPLEMENTATION-LOG.md` inside the demo per the handoff's strict file inventory rule):

```
draac-demo/
├── .github/workflows/pr-validate.yml
├── .github/workflows/deploy.yml
├── bicep/main.bicep                # Storage Account in westeurope
├── bicep/main.dr.bicep             # Storage Account in northeurope (auto-generatable)
├── scripts/setup.ps1               # One-time AAD app + OIDC + secrets
├── scripts/generate-dr.ps1         # Three-regex transform from main.bicep -> main.dr.bicep
├── scripts/post-pr-comment.ps1     # PR-thread comment via gh api
├── .gitignore
├── LICENSE                          # Copy of parent MIT
└── README.md
```

**Bug fixes applied to the handoff spec** (per the user's instruction "fix any potential bugs you already see and encounter"):

1. `pr-validate.yml` — exit-code capture bug. Original spec:
   ```powershell
   $changed = git diff --cached --quiet; $LASTEXITCODE
   ```
   This assigns git's stdout (empty under `--quiet`) to `$changed` and then evaluates `$LASTEXITCODE` as a discarded expression — meaning the workflow would never detect a changed DR file and thus never commit it back. Reordered to:
   ```powershell
   git diff --cached --quiet
   $changed = $LASTEXITCODE
   ```

2. `pr-validate.yml` — validation step replaced. Original spec used `az deployment sub validate --location ... --template-file <RG-scoped Bicep> || true`. Because the demo's Bicep targets the resource-group scope (it defaults to `targetScope = 'resourceGroup'`), submitting it as a *subscription*-scope deployment validation always fails with a scope-mismatch error, which the `|| true` then silently swallowed. Replaced with `az bicep build --file ... --stdout > /dev/null`, which actually validates the Bicep syntax and types and fails the workflow loudly on real errors (per spec section 2.10 "Failure modes are visible, not hidden").

3. `setup.ps1` — removed the unused `$repoOwner` declaration. The original spec assigned `$repoOwner = $RepoFull.Split('/')[0]` and never referenced the variable. PSScriptAnalyzer would have flagged this; removing it is a no-op cleanup.

**Validation results:**

```
az bicep build --file bicep/main.bicep      → OK
az bicep build --file bicep/main.dr.bicep   → OK
generate-dr.ps1 round-trip                  → main.dr.bicep byte-identical to committed file
Invoke-ScriptAnalyzer -Settings parent      → 0 issues
```

**Handoff-acceptance — what is and isn't covered:**

| Handoff acceptance | Covered? | Notes |
|---|---|---|
| Bicep compiles | ✅ | Both files compile with `az bicep build` locally. |
| PSScriptAnalyzer clean | ✅ (with parent settings) | The handoff says "zero warnings" but its own use of `Write-Host` for status lines (per section 2.10) trips the default rule set. Reusing the parent `PSScriptAnalyzerSettings.psd1` resolves this; running with default settings produces 22 `PSAvoidUsingWriteHost` warnings — same situation as the parent project. If the demo is later extracted to its own repo, copy `PSScriptAnalyzerSettings.psd1` along with it. |
| `generate-dr.ps1` produces deterministic output | ✅ | Verified locally: running the generator over the committed `main.bicep` produces a `main.dr.bicep` byte-identical to the committed copy. First-run idempotency holds — the first PR will see the "in sync" status, not the "auto-generated" status. |
| End-to-end on a sandbox subscription | **Deferred** | Requires a real Azure subscription + GitHub repo to wire OIDC. Operator runs `setup.ps1`, opens a PR, merges. |
| Re-running `setup.ps1` is a no-op | **Deferred (offline)** | Script logic explicitly checks for existing app, federated credentials, and role assignment before creating; will be a no-op on second run, but unverified without a real run. |

**Notable decisions:**

- **Demo lives inside this repo for now.** The handoff implies a standalone repo (section 9 "fresh user clones the repo"). Per the user's choice, it lives as a subdirectory. Moving it later to its own repo requires copying `LICENSE` (already self-contained), the parent `PSScriptAnalyzerSettings.psd1`, and re-pointing any tooling. The parent's `.gitignore` already covers `.azure/` etc., so the demo's `.gitignore` is partially redundant inside the parent — kept exactly as the handoff specifies for clean extraction later.
- **Three bug fixes documented above are the only deviations from the handoff text.** No additional features, parameters, or files added.

---

_Log started 2026-05-04. Append, never rewrite history. Every commit that lands a brief item should add an entry here in the same commit._
