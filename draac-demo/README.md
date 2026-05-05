# DRaaC Demo

> A minimal, working demonstration of Disaster Recovery as Code on Azure.
> One Storage Account, two regions, two GitHub Actions workflows.

## What this shows

On every PR to `main`, a workflow generates a DR companion of `bicep/main.bicep`
at `bicep/main.dr.bicep` for the `northeurope` region. On merge to `main`, both
regions are deployed in parallel.

This is intentionally minimal. For the production-grade implementation with
multi-resource support, drift detection, and portal-change reverse engineering,
see the parent DRaaC project.

## Prerequisites

- Azure subscription with Owner or User Access Administrator
- `az` CLI logged in (`az login`)
- `gh` CLI logged in (`gh auth login`)
- PowerShell 7.2+

## Setup (run once)

```pwsh
git clone <this-repo>
cd draac-demo
pwsh scripts/setup.ps1 -RepoFull "your-org/your-repo"
```

The setup script creates an Azure AD app registration, configures GitHub
OIDC federation, assigns Contributor on your current subscription, and sets
three repository secrets. It is idempotent. Re-running is safe.

## Try it

1. Create a branch: `git checkout -b try-it`
2. Edit `bicep/main.bicep`. Change a tag value, for example.
3. Open a PR to `main`.
4. Watch the `DRaaC Demo: PR Validate` workflow regenerate `main.dr.bicep`
   and post a comment on the PR.
5. Merge the PR.
6. Watch the `DRaaC Demo: Deploy Both Regions` workflow create both Storage
   Accounts.

## Cleanup

```pwsh
az group delete --name rg-draac-demo    --yes --no-wait
az group delete --name rg-draac-demo-dr --yes --no-wait
```

## What's deliberately left out

This demo strips DRaaC to its essence: code generates DR, both deploy together.
A real implementation needs to handle reserved subnet names, `dependsOn`
rewriting, the 200-resource ARM export ceiling, data plane replication, traffic
routing, secrets sync, and portal-change reverse engineering. See the parent
project's documentation for those.
