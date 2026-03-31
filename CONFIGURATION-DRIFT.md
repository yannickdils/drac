# Configuration Drift Report

> This file tracks infrastructure configuration drift detected during PR validation.  
> It is automatically updated by the **Azure Compliance Pipeline** on every pull request to `main`.  
> **Do not edit manually** — changes will be overwritten on the next pipeline run.

---

## How to Read This Report

| Icon | Meaning |
|---|---|
| 🔴 CRITICAL | Resource defined in IaC is not deployed, or PR changes are not in Azure |
| 🟡 WARNING | Resource deployed in Azure has no IaC definition |
| 🟢 CLEAN | No drift detected — all resources are consistent |

### Drift Types

| Type | Description |
|---|---|
| `in-code-not-deployed` | IaC file defines a resource that doesn't exist in any Azure subscription |
| `deployed-not-in-code` | Azure has a resource with no corresponding IaC definition |
| `pr-change-not-deployed` | A file changed in this PR defines resources not found in Azure |
| `partial-deployment` | Some (but not all) resources from a changed file are deployed |

---

_No entries yet. Merge a PR with the compliance pipeline enabled to generate the first report._
