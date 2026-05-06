// =============================================================================
// bicep/modules/dr-traffic.bicep
// Resource family : Microsoft.Cdn/profiles (Azure Front Door Premium)
// Replication     : Front Door priority-based failover. Two origins (primary
//                   priority 1, DR priority 2) share an origin group; AFD
//                   routes to DR automatically when primary health probes
//                   fail. Brief §R4.3.
//
// API ref: https://learn.microsoft.com/en-us/azure/templates/microsoft.cdn/profiles                                  (looked up 2026-05-06)
// API ref: https://learn.microsoft.com/en-us/azure/templates/microsoft.cdn/2025-06-01/profiles/afdendpoints          (looked up 2026-05-06)
// API ref: https://learn.microsoft.com/en-us/azure/templates/microsoft.cdn/2025-06-01/profiles/origingroups          (looked up 2026-05-06)
// API ref: https://learn.microsoft.com/en-us/azure/templates/microsoft.cdn/2025-06-01/profiles/origingroups/origins  (looked up 2026-05-06)
// API ref: https://learn.microsoft.com/en-us/azure/templates/microsoft.cdn/2025-06-01/profiles/afdendpoints/routes   (looked up 2026-05-06)
// API ref: https://learn.microsoft.com/en-us/azure/templates/microsoft.cdn/2025-06-01/profiles/customdomains         (looked up 2026-05-06)
// API ref: https://learn.microsoft.com/en-us/azure/templates/microsoft.cdn/2025-06-01/profiles/securitypolicies      (looked up 2026-05-06)
// API ref: https://learn.microsoft.com/en-us/azure/templates/microsoft.network/2025-11-01/frontdoorwebapplicationfirewallpolicies (looked up 2026-05-06)
//
// What this module provisions (always global):
//   1. Azure Front Door **Premium** profile
//   2. AFD endpoint (assigned a `<workload>-<hash>.z01.azurefd.net` hostname)
//   3. Origin group with HTTP(S) health probes
//   4. Two origins:
//        - primary  — priority 1, weight 1000, hostName = primaryHostname
//        - dr       — priority 2, weight 1000, hostName = drHostname
//   5. Route binding the endpoint to the origin group (HTTPS-only, /*)
//   6. WAF policy (Premium tier) with Microsoft-managed DRS + bot rules
//   7. Security policy associating the WAF with the endpoint (and custom
//      domain when supplied)
//   8. Optional custom domain — only created when customDomainName is non-empty
//
// Failover semantics:
//   AFD evaluates origin health on probeIntervalInSeconds. As long as the
//   primary's health probe succeeds, all traffic flows to it (priority 1).
//   When the primary is unhealthy, AFD routes to the next-lowest-priority
//   healthy origin (priority 2 = DR). Restoration is automatic once primary
//   recovers and trafficRestorationTimeToHealedOrNewEndpointsInMinutes elapses.
//
// Notes:
//   - Front Door is a global resource — `location: 'global'` is required for
//     the profile, the endpoint, and the WAF policy. The `drLocation` /
//     `primaryLocation` arguments seen on sibling DR modules are intentionally
//     omitted: traffic routing is region-agnostic.
//   - Bicep does NOT allow a `metadata` property on resource declarations.
//     The replication contract lives in the FILE-level `metadata dr` block
//     below (compiles into the ARM template's top-level `metadata.dr`) and is
//     mirrored on the `drMetadata` output so downstream tooling (Test-DRHealth,
//     check-dr-coverage) can read it from the compiled ARM.
// =============================================================================

metadata dr = {
  mode: 'frontDoorPriority'
  family: 'Microsoft.Cdn/profiles'
  description: 'Azure Front Door Premium with priority-based origin failover (primary p1 / DR p2) and managed WAF.'
}

// ── Inputs ────────────────────────────────────────────────────────────────────

@description('Workload name. Used to derive AFD profile / endpoint / WAF / origin-group resource names.')
@minLength(2)
@maxLength(40)
param workloadName string

@description('FQDN of the primary origin (e.g. app-primary.azurewebsites.net).')
param primaryHostname string

@description('FQDN of the DR origin (e.g. app-dr.azurewebsites.net).')
param drHostname string

@description('HTTP path used by AFD health probes against each origin. Workload-specific (e.g. /healthz). Default `/`.')
param healthProbePath string = '/'

@description('Optional custom domain name (e.g. www.contoso.com). Empty string disables the custom-domain branch.')
param customDomainName string = ''

@description('WAF policy mode. Detection logs only; Prevention blocks. Default Prevention per brief §R4.3.')
@allowed([
  'Detection'
  'Prevention'
])
param wafMode string = 'Prevention'

@description('Caller-supplied tags. Merged with the project tags (draac=true, draac-role=traffic, draac-workload=<workloadName>).')
param tags object = {}

// ── Derived names ─────────────────────────────────────────────────────────────

// Front Door is global; AFD endpoint names must be globally unique. The
// uniqueString hash keeps redeployments deterministic per subscription.
var nameHash = take(uniqueString(subscription().id, resourceGroup().id, workloadName), 8)

var profileName       = 'afd-${workloadName}-${nameHash}'
var endpointName      = 'afde-${workloadName}-${nameHash}'
var originGroupName   = 'og-${workloadName}'
var primaryOriginName = 'origin-primary'
var drOriginName      = 'origin-dr'
var routeName         = 'rt-${workloadName}'
var wafPolicyName     = replace('waf${workloadName}${nameHash}', '-', '')
var securityPolicyName = 'sp-${workloadName}'
var customDomainResourceName = 'cd-${replace(customDomainName, '.', '-')}'

// The brief mandates these three project tags on every DRaaC-managed resource.
// `union` favours the right-hand operand on key collision, so caller tags
// cannot accidentally clobber the canonical draac-* keys.
var draacTags = {
  draac: 'true'
  'draac-role': 'traffic'
  'draac-workload': workloadName
}
var mergedTags = union(tags, draacTags)

var hasCustomDomain = !empty(customDomainName)

// ── WAF policy (Microsoft.Network/FrontDoorWebApplicationFirewallPolicies) ───
// Latest stable api-version: 2025-11-01.
// Premium-tier policy with the Microsoft-managed Default Rule Set + Bot Manager.

resource wafPolicy 'Microsoft.Network/FrontDoorWebApplicationFirewallPolicies@2025-11-01' = {
  name: wafPolicyName
  location: 'global'
  sku: {
    name: 'Premium_AzureFrontDoor'
  }
  properties: {
    policySettings: {
      enabledState: 'Enabled'
      mode: wafMode
      requestBodyCheck: 'Enabled'
    }
    managedRules: {
      managedRuleSets: [
        {
          ruleSetType: 'Microsoft_DefaultRuleSet'
          ruleSetVersion: '2.1'
          ruleSetAction: 'Block'
        }
        {
          ruleSetType: 'Microsoft_BotManagerRuleSet'
          ruleSetVersion: '1.1'
          ruleSetAction: 'Block'
        }
      ]
    }
  }
  tags: mergedTags
}

// ── Front Door profile (Microsoft.Cdn/profiles) ──────────────────────────────
// Latest stable api-version: 2025-06-01. SKU name MUST be Premium_AzureFrontDoor
// (Standard would not support managed identity, private link, or the bot
// manager rule set referenced above).

resource profile 'Microsoft.Cdn/profiles@2025-06-01' = {
  name: profileName
  location: 'global'
  sku: {
    name: 'Premium_AzureFrontDoor'
  }
  properties: {
    originResponseTimeoutSeconds: 60
  }
  tags: mergedTags
}

// ── AFD endpoint (Microsoft.Cdn/profiles/afdEndpoints) ───────────────────────
// The hostName is auto-generated as `<endpointName>-<endpointHash>.z01.azurefd.net`.
// We expose `hostName` via the `frontDoorEndpoint` output below.

resource endpoint 'Microsoft.Cdn/profiles/afdEndpoints@2025-06-01' = {
  parent: profile
  name: endpointName
  location: 'global'
  properties: {
    enabledState: 'Enabled'
  }
  tags: mergedTags
}

// ── Origin group (Microsoft.Cdn/profiles/originGroups) ───────────────────────
// healthProbeSettings is mandatory per brief §R4.3. probeProtocol Https +
// HEAD is the recommended cheap probe; probeIntervalInSeconds 30 gives a
// failover window of ~30s × successfulSamplesRequired (= ~90s by default)
// before AFD declares the primary unhealthy.

resource originGroup 'Microsoft.Cdn/profiles/originGroups@2025-06-01' = {
  parent: profile
  name: originGroupName
  properties: {
    loadBalancingSettings: {
      additionalLatencyInMilliseconds: 50
      sampleSize: 4
      successfulSamplesRequired: 3
    }
    healthProbeSettings: {
      probePath: healthProbePath
      probeRequestType: 'HEAD'
      probeProtocol: 'Https'
      probeIntervalInSeconds: 30
    }
    sessionAffinityState: 'Disabled'
    trafficRestorationTimeToHealedOrNewEndpointsInMinutes: 10
  }
}

// ── Origin: primary (priority 1) ─────────────────────────────────────────────
// priority 1 + weight 1000 → all traffic routes here while it's healthy.

resource primaryOrigin 'Microsoft.Cdn/profiles/originGroups/origins@2025-06-01' = {
  parent: originGroup
  name: primaryOriginName
  properties: {
    hostName: primaryHostname
    httpPort: 80
    httpsPort: 443
    originHostHeader: primaryHostname
    priority: 1
    weight: 1000
    enabledState: 'Enabled'
    enforceCertificateNameCheck: true
  }
}

// ── Origin: DR (priority 2) ──────────────────────────────────────────────────
// priority 2 + weight 1000 → traffic only flows here when priority-1 origin
// fails health probes. AFD does not load-balance across priorities.

resource drOrigin 'Microsoft.Cdn/profiles/originGroups/origins@2025-06-01' = {
  parent: originGroup
  name: drOriginName
  properties: {
    hostName: drHostname
    httpPort: 80
    httpsPort: 443
    originHostHeader: drHostname
    priority: 2
    weight: 1000
    enabledState: 'Enabled'
    enforceCertificateNameCheck: true
  }
  // origin creation must serialise: AFD rejects parallel writes to a single
  // originGroup. dependsOn on the primary origin keeps the deployment ordered.
  dependsOn: [
    primaryOrigin
  ]
}

// ── Custom domain (optional, Microsoft.Cdn/profiles/customDomains) ───────────
// Only materialises when customDomainName is non-empty. Uses the AFD-managed
// certificate (`ManagedCertificate`) so callers don't have to plumb through a
// Key Vault secret reference; switch to CustomerCertificate via a follow-up
// module if customer-supplied certificates are needed.

resource customDomain 'Microsoft.Cdn/profiles/customDomains@2025-06-01' = if (hasCustomDomain) {
  parent: profile
  name: customDomainResourceName
  properties: {
    hostName: customDomainName
    tlsSettings: {
      certificateType: 'ManagedCertificate'
      minimumTlsVersion: 'TLS12'
    }
  }
}

// ── Route (Microsoft.Cdn/profiles/afdEndpoints/routes) ───────────────────────
// `customDomains` is conditional: when hasCustomDomain is true, attach the
// custom domain to the route so AFD serves it on the same origin group.
// HTTPS-only forwarding + automatic HTTP→HTTPS redirect.

resource route 'Microsoft.Cdn/profiles/afdEndpoints/routes@2025-06-01' = {
  parent: endpoint
  name: routeName
  properties: {
    originGroup: {
      id: originGroup.id
    }
    supportedProtocols: [
      'Http'
      'Https'
    ]
    patternsToMatch: [
      '/*'
    ]
    forwardingProtocol: 'HttpsOnly'
    httpsRedirect: 'Enabled'
    linkToDefaultDomain: 'Enabled'
    enabledState: 'Enabled'
    // `customDomain.?id` is Bicep's safe-dereference operator: yields the id
    // when the conditional resource exists, else null. Combined with the
    // outer ternary on `hasCustomDomain` this avoids BCP318 (potential-null)
    // warnings without sacrificing the empty-array branch.
    customDomains: hasCustomDomain ? [
      {
        id: customDomain.?id
      }
    ] : []
  }
  // Route must wait for both origins so the originGroup contains live origins
  // by the time AFD validates the route.
  dependsOn: [
    primaryOrigin
    drOrigin
  ]
}

// ── Security policy (binds WAF → endpoint + optional custom domain) ──────────
// `domains` accepts BOTH afdEndpoint ids and customDomain ids — the security
// policy attaches WAF protection to whichever set we list. We always include
// the AFD endpoint; when a custom domain is configured we add it too so WAF
// applies to the customer-facing hostname as well as the *.azurefd.net one.

resource securityPolicy 'Microsoft.Cdn/profiles/securityPolicies@2025-06-01' = {
  parent: profile
  name: securityPolicyName
  properties: {
    parameters: {
      type: 'WebApplicationFirewall'
      wafPolicy: {
        id: wafPolicy.id
      }
      associations: [
        {
          domains: hasCustomDomain ? [
            {
              id: endpoint.id
            }
            {
              id: customDomain.?id
            }
          ] : [
            {
              id: endpoint.id
            }
          ]
          patternsToMatch: [
            '/*'
          ]
        }
      ]
    }
  }
}

// ── Outputs ──────────────────────────────────────────────────────────────────
// Required by brief §R4.3.

@description('Auto-generated Front Door endpoint hostname (<endpointName>-<hash>.z01.azurefd.net).')
output frontDoorEndpoint string = endpoint.properties.hostName

@description('Resource id of the Azure Front Door Premium profile.')
output frontDoorProfileId string = profile.id

@description('Resource id of the WAF policy attached to the endpoint via the security policy.')
output wafPolicyId string = wafPolicy.id

@description('Replication-mode contract for downstream tooling (check-dr-coverage, Test-DRHealth). Mirrors metadata.dr above.')
output drMetadata object = {
  mode: 'frontDoorPriority'
  family: 'Microsoft.Cdn/profiles'
  primary: primaryHostname
  dr: drHostname
  wafMode: wafMode
  customDomain: customDomainName
}
