# Test fixtures

These fixtures are **synthesised**, not captured from a real Azure environment. The brief (`IMPLEMENTATION-BRIEF.md` › "Validation infrastructure") asks for fixtures captured from a non-prod subscription; until that subscription is available, we use minimal hand-authored ARM templates that exercise each correctness fix narrowly.

## Layout

```
tests/fixtures/
  exports/
    simple-rg/template.json              ← baseline happy path (no peerings, no gateways)
    gateway-subnet-rg/template.json      ← B1: reserved subnet name preservation
    peered-vnet-rg/template.json         ← B2: cross-resource reference rewriting + dependsOn
    multi-prefix-vnet-rg/template.json   ← B3: multi-prefix VNet flag handling
    readonly-props-rg/template.json      ← B4: read-only property stripping
```

## What each fixture proves

| Fixture | Asserts |
|---|---|
| `simple-rg` | Top-level resource names get the `dr-` prefix; `location` rewritten; nothing else mangled. |
| `gateway-subnet-rg` | `GatewaySubnet`, `AzureFirewallSubnet`, etc. are preserved exactly — never prefixed. The enclosing VNet *is* prefixed. |
| `peered-vnet-rg` | `resourceId('Microsoft.Network/virtualNetworks', 'vnet-hub')` and similar references are rewritten to the DR name in pass 2. `dependsOn` arrays are rewritten. |
| `multi-prefix-vnet-rg` | When a VNet has multiple `addressPrefixes`, the first is replaced with `$DrVnetPrefix` and a `requiresMultiPrefixDR` flag is set in `_reports/dr/flags.json`. |
| `readonly-props-rg` | Global read-only props (`provisioningState`, `etag`, etc.) and per-type read-only props (`primaryEndpoints` on storage, `outboundIpAddresses` on Web/sites) are stripped. |

## Deferred fixtures

- **200-resource RG (`large-rg`)** — for Round 5 / C1. Will be synthesised when that round starts; not needed for Round 1 acceptance.

## Refreshing from a real environment

When a non-prod subscription becomes available:

```powershell
pwsh scripts/export/export-arm-templates.ps1 -SubscriptionId <sub> -OutputDir _reports/export
Copy-Item -Recurse _reports/export/* tests/fixtures/exports/
```

Then update the per-fixture assertions in `tests/round-1/Test-ConvertForDR.ps1` if real templates expose edge cases the synthetic ones miss.
