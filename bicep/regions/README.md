# `bicep/regions/` — workload Bicep, primary + DR

Workloads in this repo follow a strict primary/DR-pair convention introduced in Round 2 (`IMPLEMENTATION-BRIEF.md` §R2.1):

```
bicep/regions/
├── primary/<workload>.bicep           ← primary-region definition (operator-authored)
└── dr/dr-<workload>.bicep             ← DR-region companion (auto-generated where possible)
```

For every primary file `bicep/regions/primary/<workload>.bicep` there must be a matching `bicep/regions/dr/dr-<workload>.bicep`. The PR-time DR coverage gate (`scripts/review/check-dr-coverage.ps1`) enforces this — if the DR companion is missing, the gate runs `bicep build` on the primary, then `Convert-ForDR` on the compiled ARM, then `bicep decompile` to produce the DR file, and commits it back to the PR branch.

## Resource group convention

The `scripts/dr/deploy-dr-region.ps1` script (Round 2 §R2.2) derives target resource groups from filenames:

| File | Target resource group | Region |
|---|---|---|
| `primary/<workload>.bicep` | `rg-<workload>` | primary (`westeurope` by default) |
| `dr/dr-<workload>.bicep` | `rg-<workload>-dr` | DR (`$DR_TARGET_REGION` secret, e.g. `northeurope`) |

The deploy script creates these RGs idempotently before deploying; no pre-existing infrastructure required.

## Anchor workload

`primary/anchor.bicep` and `dr/dr-anchor.bicep` are a minimal Storage Account pair that exists to:

1. Establish the convention so the coverage gate has at least one PR-checkable workload.
2. Serve as the smoke-test target for Round 2's deploy workflow on first install.

To add a new workload, drop `primary/<workload>.bicep` in a PR. The coverage gate will auto-generate `dr/dr-<workload>.bicep`. Review the diff, merge, and the deploy workflow handles both regions.
