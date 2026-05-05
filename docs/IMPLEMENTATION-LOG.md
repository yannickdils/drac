# DRaaC — Implementation Log

> **Purpose.** Resumable change log for the multi-round DRaaC implementation driven by `IMPLEMENTATION-BRIEF.md`. Each entry records what landed, when, and what's left so a fresh session (or a fresh engineer) can pick up exactly where the previous one stopped.
>
> **Read order on resume.** (1) This log, top-to-bottom. (2) `IMPLEMENTATION-BRIEF.md` for the round you're starting. (3) Recent commits via `git log --oneline -20`.

---

## Status snapshot

| Round | Status | Landed | Validation |
|---|---|---|---|
| Pre-work — Validation harness | Done (this session) | `tests/` runner + 5 fixtures | `pwsh tests/Invoke-Validation.ps1 -Round 1` |
| Round 1 — Correctness fixes (B1, B2, B3, B4) | Done (this session) | `scripts/lib/ConvertForDR.psm1`, `data/`, rewired Stage 5 | All assertions pass; PSScriptAnalyzer clean |
| Round 2 — Close Loop A (A1, A2) | Not started | — | — |
| Round 3 — Open Loop B (A3) | Not started | — | — |
| Round 4 — Make DR real (A4, A5, E4) | Not started | — | — |
| Round 5 — Polish (C1, C2, D1–D3, E1–E3, E5) | Not started | — | — |

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

_Log started 2026-05-04. Append, never rewrite history. Every commit that lands a brief item should add an entry here in the same commit._
