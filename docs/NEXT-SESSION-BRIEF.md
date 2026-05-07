# DRaaC — Handoff to next session

> **Purpose.** Onboard a fresh Claude Code (or human) session to continue DRaaC work. Pair this with [docs/IMPLEMENTATION-LOG.md](IMPLEMENTATION-LOG.md) (per-round detail) and [`C:\Users\04562\Downloads\IMPLEMENTATION-BRIEF.md`](file:///C:/Users/04562/Downloads/IMPLEMENTATION-BRIEF.md) (the spec).

---

## ✅ Project Complete — All 5 Rounds Done (2026-05-07)

**All planned implementation work is finished.** 17/17 tests pass. PSScriptAnalyzer: 0 warnings. HEAD is at `49eca3c` (local `main`). `origin/main` is at `26283a6` — a `git push origin main` is pending.

If resuming, start here:

```powershell
git -C c:/Repos/drac status
git -C c:/Repos/drac log --oneline -5
pwsh -NoProfile -Command "& 'C:\Repos\drac\tests\Invoke-Validation.ps1' -Round '1','2','3','4','5'"
# Must be 17/17 PASS
```

---

## 1. State at handoff (2026-05-07, end of Round 5)

| Round | Status | Commit(s) |
|---|---|---|
| Pre-work — validation harness | Done | `9474601` |
| Round 1 — Correctness fixes (B1–B4) | Done | `9474601` |
| `draac-demo/` side track | Done | `8fb83eb` |
| Round 2 — Loop A close (A1 coverage gate, A2 deploy) | Done | `931cb62` |
| Round 3 — Loop B open (A3 portal drift sync) | Done | `d047676` |
| Round 4 — Make DR real (A4, A5, E4) | Done | `688873e` |
| Round 5 — Polish (R5.1–R5.7, C1–C2, E1–E3, E5) | **Done** | `df19df4`, `26283a6`, `49eca3c` |

**Validation gate as of last commit:**
```
pwsh tests/Invoke-Validation.ps1 -Round '1','2','3','4','5'  →  17/17 PASS
Invoke-ScriptAnalyzer -Path scripts/ -Recurse -Settings PSScriptAnalyzerSettings.psd1
  → 0 warnings/errors
```

**Pending:** `git push origin main` (local HEAD `49eca3c` is 3 commits ahead of `origin/main` at `26283a6`).

---

## 2. How to resume

Before writing any code, do exactly this:

```powershell
# 1. Confirm clean tree and recent history
git -C c:/Repos/drac status
git -C c:/Repos/drac log --oneline -10

# 2. Re-read the per-round detail
#    docs/IMPLEMENTATION-LOG.md   ← top-down; status snapshot is at the top
#    IMPLEMENTATION-BRIEF.md      ← the brief; jump to the round you're starting

# 3. Smoke-test the existing baseline before adding to it
pwsh -NoProfile -Command "& 'C:\Repos\drac\tests\Invoke-Validation.ps1' -Round '1','2','3','4'"
#    Must be 13/13 PASS. If not, do NOT start new work — investigate the regression first.
```

**Note the harness invocation.** The runner has a `[string[]] $Round` param. Pass each value separately quoted:

- ✅ `pwsh -NoProfile -Command "& 'C:\Repos\drac\tests\Invoke-Validation.ps1' -Round '1','2','3','4'"`
- ❌ `pwsh -NoProfile -File C:\Repos\drac\tests\Invoke-Validation.ps1 -Round 1,2,3,4` — `-File` mode passes `1,2,3,4` as a single string, the runner walks `tests/round-1,2,3,4/` (doesn't exist), reports "no tests".

PSScriptAnalyzer settings file at `PSScriptAnalyzerSettings.psd1` excludes two rules project-wide (`PSAvoidUsingWriteHost`, `PSUseBOMForUnicodeEncodedFile`) because the brief mandates both. **New code must pass with `-Settings PSScriptAnalyzerSettings.psd1`.** Per-function `[Diagnostics.CodeAnalysis.SuppressMessageAttribute(...)]` with a `Justification = '…'` is the project pattern.

---

## 3. No pending rounds

All 5 planned rounds from the implementation brief are complete. If the project resumes, scope future work as a **Round 6** (keeping the same naming convention) and open it as a new section here.

---

## 4. Patterns that pay off (carry from R1–R4)

These are not in the brief but matter for shipping clean code:

- **`-DryRun` test seam.** Any script that calls `az` / `gh` / `git` accepts a `[switch] -DryRun` that skips the side-effecting calls and writes synthetic outputs. Tests run end-to-end without Azure or GitHub. See `scripts/dr/deploy-dr-region.ps1`, `scripts/sync/Sync-PortalChange.ps1`, `scripts/dr/Test-DRHealth.ps1`, `scripts/secrets/Sync-KeyVaultSecrets.ps1`.
- **Strict-mode-safe property access.** Use `$obj.PSObject.Properties[$name]` (returns null if missing) NEVER `$obj.PSObject.Properties.Name -contains $name` (throws under `Set-StrictMode -Version Latest` when the property collection is empty). All R1+ code uses a `Test-HasProperty` helper.
- **Defeat single-element-array unwrap.** PowerShell's pipeline auto-unwraps single-element arrays. Inside helpers that read property values, use `return ,$val` (comma) on array-typed values. Inside JSON serializers, use the pipeline form `$arr | ConvertTo-Json -AsArray` not `ConvertTo-Json -InputObject @($arr) -AsArray` (the latter double-wraps to `[[...]]`).
- **Per-function `SuppressMessageAttribute` with `Justification`.** Project pattern for the few warnings the brief's verb-naming or closure semantics force you to suppress. Never use broad project-wide exclusions (the global settings file already excludes the two brief-mandated rules; everything else is per-function).
- **Test runner conventions.** Hand-rolled `Assert-True` / `Assert-Equal`, exit 0 on pass / 1 on fail, no Pester. Round-N tests live in `tests/round-N/`. Use `$env:TEMP/draac-<test>-<guid>` for isolation; clean up in `finally`.
- **Workflow YAML idiom.** Match `.github/workflows/pr-compliance.yml` for OIDC + `azure/cli@v2` style. Use `azcliversion: latest`. Never `inlineScript:` — use the `run:` field.
- **Idempotency + commit-back.** Use `scripts/lib/CommitBack.psm1`'s `Push-Branch` for any commit-back-to-PR pattern. Auto-appends `[skip ci]`.
- **Bicep `metadata.dr` is FILE-level, not resource-level.** Bicep does not allow a `metadata` property on resource declarations. Use `metadata dr = { ... }` at the top of the file; it lands as `template.metadata.dr` in the compiled ARM. Agent A and Agent C both arrived at this convention independently in Round 4.
- **Cross-RG role assignment via sub-module.** Role-assignment resources can only be deployed to the RG that contains the target. Inline cross-RG declarations raise BCP139. The pattern is to wrap the cross-RG resources in a sub-module deployed via `module ... scope: resourceGroup(<sub>, <rg>)`. See `bicep/modules/dr-keyvault-sync-drrole.bicep` for the canonical shape.
- **Bicep `if (...)` is a deploy-time conditional, not a compile-time prune.** The resource declaration is ALWAYS present in the compiled ARM; it gains a `condition` field. Tests that assert "the resource isn't there" by counting types will fail — assert on the `condition` field's presence instead, or assert on the wrapper module's parameter value. Caught by Agent C's custom-domain test in Round 4.
- **MS Learn API-version lookups.** When introducing a new resource type, look up the latest stable (non-preview) API version on Microsoft Learn (`microsoft_docs_search` / `microsoft_docs_fetch`, fallback to `WebFetch` if the MCP is denied) and cite the URL in a comment at the top of the Bicep file. Brief §7 mandates this.

---

## 5. Pitfalls hit this run, baked into above patterns

Document them so the next session doesn't relearn them:

1. **Single-element array unwrap.** Found it in R2.1 (DR coverage gate, `Get-ChangedPrimaryBicepPath`), R3.2 (`Get-PropertyValue`), R3.4's `New-PrChangesFile` test helper, and R4.1's `Get-DispatchedResource`. Always wrap with `, $val` inside helper returns, OR `@(...)` on the caller side, never both (R2.1's first fix introduced a double-wrap).
2. **`ConvertTo-Json -InputObject @($array) -AsArray`** double-wraps. Pipeline form is cleaner.
3. **PS 7.5 `ConvertFrom-Json` ISO date auto-conversion.** When asserting timestamps, normalise both sides to ISO before `-eq`. PS 7.4 and earlier may not auto-convert — make the test version-portable.
4. **Empty pipeline + `Set-Content`** silently skips writing the file. For empty-input cases, write a literal (`'[]'` for empty JSON arrays) rather than relying on pipeline-driven output.
5. **Function attribute placement.** `SuppressMessageAttribute` goes inside the function body before `[CmdletBinding()]`, NOT above the function definition. The above-definition form parses but is ignored.
6. **Mandatory `[string[]]` rejects empty arrays.** Add `[AllowEmptyCollection()]` if the parameter genuinely accepts empty.
7. **Sandbox-blocked agents.** General-purpose agents have been unable to run `Bash` / `PowerShell` tools in this environment. They write code; the integrator (main thread) runs validation. Brief them about this in their prompts and tell them to write defensively against the patterns rather than try to run tests.
8. **`Microsoft Learn MCP` may be permission-denied; use `WebFetch` as a fallback.** Agent C hit this in Round 4 — `microsoft_docs_search` / `microsoft_docs_fetch` were denied but the same `learn.microsoft.com/...` URLs worked via `WebFetch`. Tell agents to fall back automatically.
9. **Bicep BCP139 — cross-RG inline role assignments.** Role-assignment resources can only be declared inline at the SAME RG scope as the Bicep file. Cross-RG via `existing` reference fails. Wrap in a sub-module deployed via `module ... scope: resourceGroup(<sub>, <rg>)`. See R4.4's `dr-keyvault-sync-drrole.bicep`.
10. **Bicep BCP334 — false-positive min-length.** Bicep's analyzer can't prove minimum string length through `take()` / `replace()` / interpolation chains even when the math holds. Either suppress with `#disable-next-line BCP334` (with a comment explaining the proof) or restructure the name to be analyzable. Hit by Agent D's storage-name computation in R4.4.
11. **Bicep single-quote escape uses `\'`, not `''`.** PowerShell-style apostrophe doubling is a parse error in Bicep strings. Hit by Agent D's `'Function App''s'` `@description` in R4.4.
12. **Bicep `if (resource)` always emits the resource — only the `condition` field changes.** Tests must assert on the `condition` field or on the param values passed by the wrapper, not on resource counts in the compiled ARM. See `tests/round-4/Test-DrTrafficModule.ps1`'s scenario A for the canonical test shape.

---

## 6. Open deferrals across all rounds

Live Azure / GitHub validations not done in any session yet — operator action required against a real subscription / repo:

- **R1.7** — `az deployment group validate` on Round 1 fixtures against a sandbox sub.
- **R2.3** — Real PR opens, gate auto-generates DR companion, merge triggers `dr-deploy.yml`, two Storage Accounts deploy. Re-run is no-op.
- **R3.5** — Real portal change → portal-sync PR within 24 h. Resource type known to decompile dirty (KV with access policies) → `portal-sync-manual` issue instead of broken PR.
- **R4.5** — Deploy a workload with SQL DB + Storage + KV through the full pipeline; confirm SQL failover group active, Storage RA-GZRS, KV with synced secrets; manually trigger Front Door health-probe failure on primary; run `Test-DRHealth.ps1`. Operator action with sandbox sub.
- **PSRule for Azure** — Pre-work step from the brief; Round 4 modules now exist so it's actionable. Wire as part of Round 5 / E5.
- **Storage Premium DR Backup-Vault wiring.** `dr-storage.bicep` records intent in `metadata.dr.crossRegionRestoreEnabled` for Premium SKUs but does not provision the Backup Vault. Either ship a `dr-storage-backup.bicep` companion in Round 5 or document Premium DR as out-of-scope.
- **Cross-RG deploys for `dr-sql.bicep` / `dr-redis.bicep`.** These two modules use `existing` references to the primary server / cache and must deploy against the **primary** RG (the failover group / linked server lives there). Stage 7's `deploy-dr-region.ps1` defaults to `rg-<workload>-dr`; the operator's wiring in `bicep/regions/dr/` for SQL or Redis workloads must override that. Worth surfacing in `bicep/regions/README.md` if not already.
- **`setup-github.ps1`** — Update branch protection to require `pr-compliance.yml`'s review job and… *not* `dr-deploy.yml` (which runs post-merge, not on PR). The brief implies branch protection should require Stage 7; the implementation diverges. Worth re-confirming with the project owner.
- **Real-environment fixtures** — Brief asks for fixtures captured from a non-prod sub. Round 1 onwards uses synthetic templates, clearly marked in `tests/fixtures/README.md`. Refresh when a sandbox sub becomes available.

---

## 7. Project rules — non-negotiable, do not forget

(Same rules from the brief. Re-listed because they're easy to break by accident.)

- PowerShell 7.2+ only. `#Requires -Version 7.2` header on every script.
- Bicep only for IaC. No Terraform, no hand-authored ARM JSON.
- Azure CLI on the Azure side — but `Az.KeyVault` (modern Az PowerShell) is allowed in Function App runtime code (R4.4 set this precedent). The forbidden module is the deprecated `AzureRM`, NOT `Az.*`.
- Idempotent. Re-runs produce identical output.
- Fault-tolerant. Per-resource failures logged + skipped; never abort.
- Update `docs/ARCHITECTURE.md` and `docs/DOCUMENTATION.md` in the same commit that changes behaviour. Stale docs are blocking.
- Latest API versions. Resource Graph `2024-04-01`, ARM `2021-04-01`, ADO `7.1`. Cite Microsoft Learn for any new API used.

---

## 8. User preferences observed across runs

(So the next session matches the cadence the user expects.)

- **Parallel agents are welcome** when the work decomposes cleanly into disjoint file scopes. The user explicitly asked for this in Round 2 ("spin up the entire agent team"). Use `Agent` tool with `run_in_background: true`. Round 4 ran 4 in parallel successfully.
- **Commit to `main` directly.** No feature branches were used this run. The user said so in Round 1. Don't push to `origin` without asking — none of the commits have been pushed yet.
- **Concise responses.** Bullet points + tables, file links via `[name](path)`. Avoid long prose. The end-of-turn summary is one or two sentences max.
- **The persistent change log is `docs/IMPLEMENTATION-LOG.md`.** The user said "Keep track of what you did in a change log. So we can reference where you are and what has changed if our session gets disconnected." Always append to it in the same commit as the work it describes.
- **Bug discoveries are flagged loudly, not silently fixed.** When the demo handoff (`Demo handoff.md`) had three real bugs, the user wanted them surfaced. Do the same in commit messages and the log.

---

_Authored 2026-05-06 at end of Round 4. Update or replace with each session._
