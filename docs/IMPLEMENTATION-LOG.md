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
| Round 3 — Open Loop B (A3) | Done | `Find-PortalChanges`, `Sync-PortalChange`, `Send-ToManualQueue`, Stage 8 workflow | 7/7 tests pass; PSScriptAnalyzer clean for new files (legacy warnings deferred to R5) |
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

## Round 3 — Open Loop B (A3 portal-drift sync)

**Landed 2026-05-06.** Goal: detect Azure Portal changes and reverse-engineer them into the repo automatically.

**Approach:** three parallel agents, scaled up from Round 2's two. Disjoint file scopes (R3.2 owned `Find-PortalChanges.ps1`, R3.3 owned `Sync-PortalChange.ps1`, R3.4 owned `Send-ToManualQueue.ps1`). Both R3.3 and R3.4 received the same `Get-ResourceIdHash` formula and `Send-ToManualQueue` parameter contract so their branch/file/issue dedup keys stay aligned. Main thread bootstrapped nothing this round (R2's `bicep/regions/` already in place), wrote the workflow YAML, validated, fixed three integration bugs that the agents could not catch (their sandbox blocked PowerShell execution, same as Round 2).

**Files added:**

| File | Notes |
|---|---|
| `.github/workflows/portal-drift-sync.yml` | Stage 8 workflow. Schedule `02:00 UTC daily` + `workflow_dispatch`. Two jobs: detect + sync. Concurrency `group: draac-portal-drift-sync, cancel-in-progress: false`. The brief says "three jobs"; the third (manual-queue-fallback) is folded into the sync job because `Sync-PortalChange.ps1` invokes `Send-ToManualQueue.ps1` inline per dirty decompile — splitting that across jobs would require artifact passing for "leftover" changes and adds zero value over the inline form. |
| `scripts/sync/Find-PortalChanges.ps1` | KQL detection. `-DryRun -FixtureFile <path>` test seam runs the same filter/coalesce pipeline against hand-rolled JSON. Coalesce-then-skip ordering: latest snapshot drives the keep decision. |
| `scripts/sync/Sync-PortalChange.ps1` | Per-change reverse-engineering. Type-slug naming (`Microsoft.Network/virtualNetworks` → `microsoft-network-virtualnetworks`), 12-char SHA-256 over `lower(resourceId)`, `gh pr list --search` dedup. `-DryRun` short-circuits all `az`/`gh`/`git` calls. Two env-var test hooks: `DRAAC_SYNC_FORCE_DIRTY_RESOURCE_IDS`, `DRAAC_SYNC_FORCE_EXISTING_PRS`. |
| `scripts/sync/Send-ToManualQueue.ps1` | Manual-queue fallback. Hash-keyed dedup against existing open `portal-sync-manual` issues. `--assignee` only when `changedBy` looks like a GitHub login (1–39 chars, no `@`); mention-only otherwise. Snapshot path: `_reports/sync/manual-queue/<hash>.json`. |
| `tests/round-3/Test-FindPortalChanges.ps1` | 7-row mixed fixture proves coalescing + skip-by-name-or-rg + skip-by-readonly + idempotency + malformed-row tolerance + dry-run-rejects-without-fixture. |
| `tests/round-3/Test-SyncPortalChange.ps1` | Two-change run (clean + simulated-dirty), idempotency, helper unit tests. Uses env-var hooks to inject the dirty case without needing a real bad ARM. |
| `tests/round-3/Test-SendToManualQueue.ps1` | Hash determinism, ARM snapshot path, dry-run outcomes, dedup short-circuit on simulated existing issue. |
| `tests/fixtures/portal-changes/mixed.json` + `malformed.json` | Detection fixtures. |
| `docs/ARCHITECTURE.md` | Added Stage 8 ASCII block + Round 3 file inventory. |
| `docs/DOCUMENTATION.md` | Added "Stage 8: Portal Drift Sync" operator section. |

**Three integration bugs caught and fixed during validation** (agents had no shell access; main thread surfaced these on first harness run):

1. **`Get-PropertyValue` single-element array unwrap (Find-PortalChanges).** When a fixture row's `changedProperties` was `["provisioningState"]`, `return $Object.$Name` triggered PowerShell's pipeline auto-unwrap and the helper returned the bare string `"provisioningState"`. Downstream `ConvertTo-PropertyPathList` saw a string, fell through its `IEnumerable && !string` check, and emitted `@()`. Result: every single-element changedProperties got reset to empty, so the readonly-only skip rule never matched. Fixed by adding a `, $val` (comma) wrap inside `Get-PropertyValue` for array-typed values to defeat the unwrap. The string branch in `ConvertTo-PropertyPathList` was also hardened to handle a bare-string fallback.

2. **`ConvertTo-Json -InputObject @($array) -AsArray` double-wrap.** The script wrote `[[...]]` instead of `[...]` because `-InputObject` plus `-AsArray` adds two layers of array wrapping. Switched to the pipeline form (`$arr | ConvertTo-Json -AsArray`) which produces a single top-level array even for 0 items.

3. **Test-FindPortalChanges timestamp comparison.** PowerShell 7.5+ `ConvertFrom-Json` auto-converts ISO 8601 strings to `[DateTime]`. The test compared a `[string]` literal against the parsed `[DateTime]`, and `-eq` stringified the DateTime in the current culture (`05/04/2026 12:34:56`). Hardened the test to normalise both sides to ISO before comparing.

**Validation results:**

```
pwsh tests/Invoke-Validation.ps1 -Round '1','2','3'
Round Test                            ExitCode Status
1     Test-ConvertForDR.ps1                  0 PASS
1     Test-GenerateDrConfig-Smoke.ps1        0 PASS
2     Test-CheckDrCoverage.ps1               0 PASS
2     Test-DeployDrRegion.ps1                0 PASS
3     Test-FindPortalChanges.ps1             0 PASS
3     Test-SendToManualQueue.ps1             0 PASS
3     Test-SyncPortalChange.ps1              0 PASS
Total: 7  Pass: 7  Fail: 0
```

```
Invoke-ScriptAnalyzer -Settings PSScriptAnalyzerSettings.psd1
  Round 3 files: 0 issues
  Pre-existing legacy scripts: 15 warnings (in detect-drift.ps1, match-code-to-deployed.ps1,
    update-drift-readme.ps1, post-pr-comment*.ps1, scan-subscriptions.ps1, write-job-summary.ps1).
    Brief's "new code adds zero warnings" rule is met. Round 5 §D1 (compile-then-match) and
    §D2 (tuple matching) explicitly rewrite match-code-to-deployed.ps1; the others will be
    cleaned up alongside as part of R5 polish.
```

**Acceptance per brief — what is and isn't covered:**

| Brief acceptance (R3.5) | Covered? | Notes |
|---|---|---|
| Make a small portal change, trigger workflow manually, confirm a PR is opened | **Deferred** | Cannot execute without an Azure subscription and a configured GitHub repo (OIDC federation, secrets). Code path is exercised end-to-end via `-DryRun` with both clean and forced-dirty changes. |
| For C3: pick a resource type known to decompile dirty (e.g. KV with access policies); confirm an issue is filed instead of a broken PR | **Deferred / structurally proven** | The dirty branch is exercised in `Test-SyncPortalChange.ps1` via `DRAAC_SYNC_FORCE_DIRTY_RESOURCE_IDS`. The actual real-world dirty case (KV access policies) needs a live subscription. |

**Notable design decisions (worth knowing for Round 4+):**

- **Two jobs, not three.** The brief says "three jobs: detect → decompile-and-pr → manual-queue-fallback". In practice, `Sync-PortalChange.ps1` handles both the clean (PR) and dirty (manual-queue) dispositions inline per change, so the third job has nothing to do that the second job didn't already finish. Splitting them would require artifact passing of "leftover" changes and adds no value. Documented in the workflow YAML comment.

- **Hash alignment between R3.3 and R3.4.** Both scripts compute the same `SHA-256(lower(resourceId))[0..5]` 12-char hash. R3.3 uses it for branch names (`portal-sync/<yyyyMMddUTC>-<hash>`); R3.4 uses it for the manual-queue snapshot filename and the `gh issue list --search <hash>` dedup. A reviewer can correlate a PR branch and a manual-queue file by the same hash. Both agents implemented `Get-ResourceIdHash` independently and the integrator confirmed the algorithm matches — verified by the agents themselves cross-reading each other's files during their runs.

- **Coalesce-then-skip, not skip-then-coalesce.** R3.2 coalesces multiple changes against the same resource BEFORE applying skip rules, so the keep/skip decision is driven by the resource's *latest* snapshot. The brief is silent on the order; this matches the operator's mental model ("did the resource still need a sync, considering its most recent change?").

- **`workflow_dispatch` input for `lookback-hours`.** Useful when investigating an incident from yesterday or backfilling after the workflow was paused. Default is the brief's 24 h.

- **Pre-existing legacy script warnings are in scope for Round 5, not Round 3.** Brief §R5.3 (D3) deletes the `.sh` files and §D1/§D2 rewrites `match-code-to-deployed.ps1`. The 15 warnings will be cleaned up there, not now.

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

## Round 4 — Make DR real (R4.1, R4.2, R4.3, R4.4)

**Landed 2026-05-06.** Goal: replace the empty DR resource shells from R1–R3 with real replication, traffic routing, and secrets sync. Largest round so far.

**Approach.** Main thread first landed a small bootstrap (registry-driven dispatch shell on `Convert-ForDR`, public-facing-workload detection on `check-dr-coverage`, plus two new R4 tests). Then four general-purpose agents in parallel against fully-disjoint scopes:

- **Agent A** — `bicep/modules/dr-{sql,cosmos,storage,keyvault,postgres,mysql,redis}.bicep` + `tests/round-4/Test-DrModules-Compile.ps1` + populated `data/dr-module-registry.json`.
- **Agent B** — `scripts/dr/Test-DRHealth.ps1` (per-family probes + dispatcher) + `tests/round-4/Test-DRHealth.ps1` + `tests/fixtures/dr-health/all-healthy.json`.
- **Agent C** — `bicep/modules/dr-traffic.bicep` (Azure Front Door Premium) + `tests/round-4/Test-DrTrafficModule.ps1`.
- **Agent D** — `bicep/modules/dr-keyvault-sync.bicep` + `bicep/modules/dr-keyvault-sync-drrole.bicep` (added during integration to fix BCP139, see below) + `scripts/secrets/Sync-KeyVaultSecrets.ps1` + `tests/round-4/Test-SyncKeyVaultSecrets.ps1` + the architectural decision text for `docs/ARCHITECTURE.md`.

The integrator collated docs (ARCHITECTURE / DOCUMENTATION / IMPLEMENTATION-LOG / NEXT-SESSION-BRIEF) into this single commit.

**Files added / modified:**

| File | Notes |
|---|---|
| `scripts/lib/ConvertForDR.psm1` | **Bootstrap.** Added `$script:DrModuleRegistry`, exported `Register-DrModule` / `Unregister-DrModule` / `Clear-DrModuleRegistry` / `Get-DrModuleRegistry` / `Initialize-DefaultDrModuleRegistry` / `Get-DispatchedResource`. `Convert-ForDR` now runs dispatch *before* the name-rewrite transform so the dispatch record's `originalName` is the genuine input-template name and `drName` is computed via the rewrite map (including parent-segment rewriting for nested types). Result shape gains a `Dispatched` field. Idempotent and backwards-compatible: empty registry → `Dispatched: @()` → R1–R3 behaviour unchanged. |
| `scripts/review/check-dr-coverage.ps1` | **Bootstrap.** Added `Test-IsPublicFacingPrimary` (text inspection of the Bicep source for any of `Microsoft.Web/sites`, `Microsoft.ContainerService/managedClusters`, `Microsoft.Network/applicationGateways`) and `Test-DrCompanionReferencesTraffic` (greps the DR Bicep for `dr-traffic.bicep`). Coverage gate now fails any public-facing primary whose DR companion does NOT reference `dr-traffic.bicep`, both on the existing-companion path and the just-auto-generated path (with a remediation hint in the failure reason). |
| `data/dr-module-registry.json` | **Bootstrap shell + populated by Agent A.** Maps the 7 Round-4 resource families to their module file names. |
| `bicep/modules/dr-sql.bicep` | SQL DB DR via failover group + automatic policy. API `2023-08-01`. Uses `existing` ref to the primary server — must deploy to **primary** RG. |
| `bicep/modules/dr-cosmos.bicep` | Multi-region Cosmos with automatic failover. API `2024-11-15`. |
| `bicep/modules/dr-storage.bicep` | Storage with RA-GZRS (Standard) / cross-region restore intent (Premium). API `2024-01-01`. **Premium DR is currently a no-op deploy** — cross-region restore lives at the Backup-Vault layer, not the storage account. Module records intent in `metadata.dr.crossRegionRestoreEnabled` and tags it; provisioning the Backup Vault is an R5 deferral. |
| `bicep/modules/dr-keyvault.bicep` | Key Vault with soft-delete + purge protection. API `2024-11-01`. |
| `bicep/modules/dr-postgres.bicep` | Postgres read replica, `createMode: Replica`. API `2024-08-01`. |
| `bicep/modules/dr-mysql.bicep` | MySQL read replica, `createMode: Replica`. API `2024-12-30`. |
| `bicep/modules/dr-redis.bicep` | Redis geo-replication via `linkedServers`. API `2024-11-01`. **Premium-only enforced via `@allowed`** — `Basic`/`Standard` callers fail at template-validation time. Uses `existing` ref to the primary cache — must deploy to **primary** RG. |
| `bicep/modules/dr-traffic.bicep` | Azure Front Door Premium + WAF + optional custom domain. API `2025-06-01` / `2025-11-01`. `metadata.dr` is a **file-level** Bicep statement (resource-level `metadata` is not allowed by Bicep) — same convention used in Agent A's modules. |
| `bicep/modules/dr-keyvault-sync.bicep` | Function App (Y1 consumption, Linux, PowerShell 7.4) + Event Grid system topic on the primary KV + role assignments + storage + App Insights + UAMI. APIs `2025-03-01` (Web), `2025-08-01` (Storage), `2025-02-15` (EventGrid), `2024-11-30` (ManagedIdentity), `2022-04-01` (Authorization), `2020-02-02` (Insights). |
| `bicep/modules/dr-keyvault-sync-drrole.bicep` | Cross-RG role-assignment sub-module — added during integration to fix BCP139. Invoked from `dr-keyvault-sync.bicep` via `module ... scope: resourceGroup(<sub>, <rg>)` parsed from the DR vault id. |
| `scripts/dr/Test-DRHealth.ps1` | Per-family DR health probes (SQL / Cosmos / Storage / KV / Postgres / MySQL / Redis). `-DryRun -FixtureFile` test seam runs the entire dispatch pipeline against a hand-rolled fixture. Outputs `_reports/dr-health/dr-health.json` + `DR_HEALTH_OK` / `DR_HEALTH_SUMMARY` GitHub Actions outputs. `-FailOnUnhealthy` flips a true unhealthy into a non-zero exit (default exit 0; the gate is in the GitHub Actions output, not the exit code, matching the rest of the project). |
| `scripts/secrets/Sync-KeyVaultSecrets.ps1` | The Function App's `run.ps1`, also runnable standalone. Two parameter sets (`EventGrid` / `Manual`) so both the Functions host and the test harness can drive it. `-DryRun` skips all `Az.KeyVault` calls. `DRAAC_SECRETS_FORCE_INSYNC=1` env var forces the in-sync short-circuit branch. |
| `tests/round-4/Test-ConvertForDR-Dispatch.ps1` | Bootstrap test for the dispatch shell. Empty registry → 0 dispatched, populated registry → 2 dispatched (Storage Account + SQL DB), idempotency on already-prefixed input, `Initialize-DefaultDrModuleRegistry` loads the on-disk mapping (assertions verify Storage / SQL / KV entries are present). |
| `tests/round-4/Test-CheckDrCoverage-FrontDoor.ps1` | Bootstrap test for the public-facing gate. Public-facing primary + companion references `dr-traffic.bicep` → ok; same primary + companion missing the reference → coverage failed; non-public-facing primary → gate is a no-op. |
| `tests/round-4/Test-DrModules-Compile.ps1` | Per-module `bicep build` + structural assertion (expected resource type appears, `metadata.dr` block carries non-empty `mode` for SQL and Storage). Skip-if-no-CLI guard. |
| `tests/round-4/Test-DRHealth.ps1` | 6 scenarios: all-healthy / idempotent / SQL degraded / Postgres unhealthy / missing fixture (exit 2) / unknown via missing probeResult. Spawns `pwsh -File` so the script's `exit N` doesn't terminate the test runner. |
| `tests/round-4/Test-DrTrafficModule.ps1` | Compile + structural (Premium SKU, two origins, WAF/security policy linkage). Custom-domain conditional: scenario A asserts the resource has a `condition` field (proves `if (hasCustomDomain)` was compiled) and the wrapper ARM does NOT contain the literal hostname; scenario B asserts the customDomain resource is present and references the parameter. |
| `tests/round-4/Test-SyncKeyVaultSecrets.ps1` | Happy path / wrong event type / forced in-sync / Bicep compile. |
| `tests/fixtures/dr-health/all-healthy.json` | Shared base fixture; tests mutate per-scenario into `$Workdir/<scenario>.json`. |
| `docs/ARCHITECTURE.md` | New "Round 4 — Make DR real (R4.1–R4.4)" section between Stage 8 and Stage 6, with R4.1 dispatch contract + the R4.4 KV-strategy architectural decision. |
| `docs/DOCUMENTATION.md` | New "Stage 7-DR" operator-facing section covering the four sub-rounds plus operator notes (cross-RG deploys, R4.5 sandbox-acceptance deferrals). |

**Three integration bugs caught and fixed during validation** (agents had no shell access; main thread surfaced these on first harness run):

1. **`Test-ConvertForDR-Dispatch.ps1` — initial-registry assertion stale.** I wrote the bootstrap test before Agent A populated the registry, so the assertion expected 0 entries; Agent A landed 7. Fixed the assertion to require ≥7 and verify the Storage / SQL / KV mappings explicitly so a future truncation of `data/dr-module-registry.json` would still trip the test.

2. **`Test-DrTrafficModule.ps1` — custom-domain conditional misread Bicep semantics.** Agent C's test asserted that `customDomainName=''` produces zero `Microsoft.Cdn/profiles/customDomains` resources in the compiled ARM. Bicep's `if (...)` actually compiles to an ARM `condition` field — the resource declaration is *always* in the template; the template engine skips it at deploy time when the condition evaluates to false. Replaced the assertion with two checks: (a) every customDomains resource has a `condition` field (proves the `if (hasCustomDomain)` was wired), and (b) the rendered wrapper ARM does NOT contain the literal `'app.example.com'` in scenario A (proves the param value was correctly empty).

3. **`dr-keyvault-sync.bicep` — BCP139 cross-RG role assignment.** Agent D declared the DR-side role assignment inline with `scope: drVaultExisting` where `drVaultExisting` was a cross-RG `existing` reference (`scope: resourceGroup(...)`). Bicep raises BCP139 because role-assignment resources can only be deployed to the RG that contains the target resource. Fix: split the DR role assignment into a new sub-module `dr-keyvault-sync-drrole.bicep` and invoke it via `module ... scope: resourceGroup(<sub>, <rg>)` parsed from the DR vault id. Also fixed BCP334 (false-positive storage-name min-length) by adding `@minLength(1)` on `workloadName` and a `#disable-next-line BCP334` directive — the storage name is provably ≥14 chars but Bicep's analyzer can't see through `take/replace/string-interpolation`. Fixed an unrelated single-quote escape error in the sub-module's `@description` (Bicep uses `\'` not `''`).

**Validation results:**

```
pwsh tests/Invoke-Validation.ps1 -Round '1','2','3','4'
Round Test                               ExitCode Status Duration
----- ----                               -------- ------ --------
1     Test-ConvertForDR.ps1                     0 PASS
1     Test-GenerateDrConfig-Smoke.ps1           0 PASS
2     Test-CheckDrCoverage.ps1                  0 PASS
2     Test-DeployDrRegion.ps1                   0 PASS
3     Test-FindPortalChanges.ps1                0 PASS
3     Test-SendToManualQueue.ps1                0 PASS
3     Test-SyncPortalChange.ps1                 0 PASS
4     Test-CheckDrCoverage-FrontDoor.ps1        0 PASS
4     Test-ConvertForDR-Dispatch.ps1            0 PASS
4     Test-DRHealth.ps1                         0 PASS
4     Test-DrModules-Compile.ps1                0 PASS
4     Test-DrTrafficModule.ps1                  0 PASS
4     Test-SyncKeyVaultSecrets.ps1              0 PASS
Total: 13  Pass: 13  Fail: 0
```

```
Invoke-ScriptAnalyzer -Settings PSScriptAnalyzerSettings.psd1
  Round 4 files: 0 issues (after 4 per-function suppressions added with justifications)
  Pre-existing legacy scripts: 15 warnings (deferred to Round 5 §D1/D2/D3)
```

```
az bicep build on each of the 9 new Bicep modules: all clean.
```

**Acceptance per brief — what is and isn't covered:**

| Brief acceptance (R4.5) | Covered? | Notes |
|---|---|---|
| Deploy a workload with SQL DB + Storage + KV through the full pipeline | **Deferred** | Cannot execute without an Azure subscription. Module library is structurally proven via `bicep build` on each file. |
| Confirm DR side has SQL failover group active, Storage RA-GZRS, KV with synced secrets | **Deferred** | Same — needs sandbox sub. The `-DryRun` paths in `Test-DRHealth.ps1` and `Sync-KeyVaultSecrets.ps1` exercise the full code path against fixtures. |
| Manually trigger Front Door health probe failure on primary; confirm DR endpoint takes traffic | **Deferred** | Live failover test — operator action. |
| Run `Test-DRHealth.ps1`; confirm all green | **Deferred / structurally proven** | The `-DryRun -FixtureFile` test seam exercises the dispatcher + every per-family probe against a synthesized "all-healthy" fixture. The probe-result shape per family is documented in the test fixture for operator reference. |
| `Invoke-PSRule -Module PSRule.Rules.Azure -InputPath bicep/modules/` clean | **Deferred** | PSRule.Rules.Azure not installed in this session. Pre-work step from the brief; meaningful now that R4 modules exist. Operator action for Round 5 acceptance. |

**Notable design decisions (worth knowing for Round 5+):**

- **Dispatch runs before the name-rewrite transform.** Earlier (mid-integration) attempt placed dispatch after `Invoke-Transformation`, which meant `originalName` reflected post-rewrite state — wrong by contract. Moving it after `Get-NameRewriteMap` but before `Invoke-Transformation` means `originalName` is the genuine input name and `drName` is computed via the rewrite map. The same logic is reused for nested types: parent-segment rewrite gives `dr-sqlsrv01/db01` for input `sqlsrv01/db01` when `sqlsrv01` is in the map.
- **Cross-RG role assignment via sub-module.** `dr-keyvault-sync-drrole.bicep` is the reusable pattern for any cross-RG role-assignment work. R5 / future rounds can copy this shape rather than re-discover BCP139.
- **`metadata.dr` is at the file level, not the resource level.** Bicep does NOT allow a `metadata` property on resource declarations — only `metadata` at the file scope (compiles to `template.metadata`) or `metadata` decorators on `param` declarations. All R4 modules follow this convention; the test reads `template.metadata.dr.mode` to assert the contract.
- **Two jobs, not three, for portal-drift sync (carried from R3) — and similarly, the brief's "three jobs for KV sync" implication folds into one Function App.** The split-runtime architecture (Event Grid → Function → Az.KeyVault) is unicausal and benefits from no inter-job artifact passing.
- **`-FailOnUnhealthy` is opt-in, not default.** `Test-DRHealth.ps1` exits 0 by default even when unhealthy — the gate is in the GitHub Actions output (`DR_HEALTH_OK=false`) so the PR comment can reflect the state without failing the workflow. Matches the rest of the project's "GA outputs drive policy, not exit codes" pattern. Operators wiring this into a hard gate use `-FailOnUnhealthy`.

---

_Log started 2026-05-04. Append, never rewrite history. Every commit that lands a brief item should add an entry here in the same commit._
