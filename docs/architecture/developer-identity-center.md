# Developer Identity Center

Alpha 3 unifies signing identity management into one workspace. The
Identity Center is the single place ZynSign answers questions about
certificates, provisioning profiles, teams, and the relationships between
them — and the single source the signing screen reads when it proposes an
identity. It is a view over facts the app already holds, plus pure
engines that reason about them. It is not a trust authority, not a
platform verdict, and not a second place where identity state lives.

## What the center is

The center's subject is the **Developer Identity**: a certificate, the
key behind it (which stays in the Keychain), the provisioning profiles
that name it or share its team, and the team both declare. Before this
step that knowledge was spread across the certificate manager, the
profile library, and the signing screen. The center assembles it, once,
into one value.

```
Identity Center snapshot (one read of each store, one instant)
 ├─ Certificates    ← IdentityStore (Keychain-backed, keys stay inside)
 ├─ Profiles        ← ProvisioningProfileLibrary
 ├─ Teams           ← DeveloperTeamGrouper (pure)
 ├─ Health          ← IdentityHealthEngine (pure)
 ├─ Conflicts       ← IdentityConflictDetector (pure)
 ├─ Forecast        ← ExpirationForecastBuilder (pure)
 ├─ Timeline        ← IdentityTimelineBuilder (pure)
 └─ Recommendation  ← IdentityRecommender (pure)
```

Every engine is a pure domain type (`ZynSign/Domain/`) that reads facts,
never stores. `IdentityCenterService` (`ZynSign/Application/`) reads each
store once per snapshot, reduces what it finds into
`IdentityCertificateFacts`, `IdentityProfileFacts`, and
`IdentityHistoryFact`, and hands those to the engines. The screens
(`ZynSign/Presentation/IdentityCenter/`) render the one snapshot the
model holds, so the dashboard, the team workspace, the inspectors, the
forecast, the timeline, and the graph can never disagree.

## Facts, not verdicts

A fact is an observation. `isUsableForSigning` repeats what the secure
store last observed about a key; an expiration classification judges the
certificate's own interval at one instant; a profile's coverage is
computed from its own declared patterns. No engine in the center decides
trust, evaluates a chain, predicts platform acceptance, or promises a
signing run will succeed. The signing pipeline re-checks everything it
needs when it runs.

## Team Workspace

`DeveloperTeamGrouper` groups certificates and profiles by the Team ID
their subject or payload declares, comparing IDs case-insensitively and
preserving the first spelling seen for display. Identities whose Team ID
is not recognisable group under one **Ungrouped** bucket — nothing a user
imported is hidden, and nothing is invented into a team it did not
declare. Teams sort alphabetically with the ungrouped bucket last, so the
order is stable across refreshes. Each team shows its members
(expand/collapse, expanded by default), its summary, and how many library
applications its profiles can sign.

## Identity Health

`IdentityHealthEngine` answers, per certificate and per profile, the
checks the product names:

| Check | Blocked when | Warning when | Not applicable when |
|---|---|---|---|
| Certificate Valid | outside the validity window | — | (profile subject: no embedded fingerprints recorded) |
| Key Available | key observed unavailable | key availability unknown | — |
| Profile Valid | every linked profile expired | no linked profile, or some expired | — |
| Team Match | no linked profile declares the certificate's team | some linked profiles disagree, or no local certificate shares a profile's team | either subject declares no Team ID |
| Expiration | expired / not yet valid | within the 30-day threshold | — |
| Bundle Compatible | — | zero compatible library apps | library not composed, or no count known |

The overall status folds the conclusive checks: 🟢 Healthy, 🟡 Warning,
🔴 Blocked. Each check composes one sentence of fixed language, and every
report carries a **spoken summary** VoiceOver reads in full. Reports are
computed once per snapshot and cached with it; rendering never recomputes.

## Smart Conflict Detection

`IdentityConflictDetector` reports, from the same facts:

1. **Duplicate certificates** — several local certificates share a team
   and a subject name (usually the same credential imported twice).
2. **Multiple matching certificates** — a team holds several usable
   certificates of one purpose and no default is set: *"Multiple
   compatible certificates were found for this Team. Choose a default
   identity."*
3. **Team mismatch** — a profile's declared team disagrees with the team
   of a certificate it embeds (blocked).
4. **Missing profile** — a team holds a usable certificate and no
   profile of any kind.
5. **Expired profile** — each expired profile (blocked).
6. **Orphaned profile** — a profile's embedded certificates are all
   absent from the device.

Conflicts are observations with composed language and a remedy; the
center never applies a remedy on its own. Identifiers are derived from
content, so two scans that find the same facts find the same conflicts.

## Expiration Forecast

`ExpirationForecastBuilder` turns every expiration into a band —
**Expired** (block), **Critical** ≤7 days, **Important** ≤14 days,
**Warning** ≤30 days, **Watch** beyond — sorted most-urgent first, so the
top of the forecast is always the next identity to stop working. Bands
line up with the certificate manager's 30-day warning and the profile
library's expiring-soon badge; no screen contradicts another.

## Smart Recommendations

`IdentityRecommender` scores certificate–profile pairings for one
application:

| Observation | Score |
|---|---|
| Previous successful signing of this app with this certificate | +45 |
| Usable key (available, matched, ready) | +40 |
| Profile covers the app's bundle identifier | +25 |
| Team match between certificate and profile | +20 |
| Default identity | +10 |
| Only eligible profile / only certificate | +5 |
| Inside an expiration warning window | −5 |
| Unusable certificate | excluded |
| Profile that cannot cover the app, expired, or App Store | excluded |

The signing screen shows the best pairing as **Recommended Identity**
with its reasons. Applying it sets the pickers; **the user's Sign tap
remains the only confirmation that signs.** When nothing qualifies, the
engine proposes nothing and the screen shows its ordinary pickers.

## Identity Timeline

`IdentityTimelineBuilder` assembles recent events from the stores ZynSign
already holds — certificate and profile import dates, the on-device
signing journal, and the most urgent expiration observations — grouped
under Today / Yesterday / date, most recent first, capped at 60 events.
Events carry fixed, composed language: no paths, no credentials, no raw
errors. Expiration observations are labelled for what they are — the
current state re-derived on each build, not a past moment.

## Quick actions

Every certificate row and inspector offers: **Set Default · View Linked
Profiles · View Compatible Apps · Refresh Validation · Copy Team ID ·
Remove**. Profile rows offer Refresh Validation, View Compatible Apps,
Copy Team ID, and Remove. Removing a registration asks for confirmation
and — where the platform supports it — authentication (the
`removeIdentity` sensitive action), and never deletes a key: removal
forgets ZynSign's registration, exactly as the certificate manager's
does.

## Security requirements

Mandatory, and enforced by construction:

- **Private keys live only in the iOS Keychain.** The center reads
  identities through `IdentityStore`, which never exposes key bytes; the
  center never asks for a signing capability.
- **The snapshot carries metadata only** — names, teams, dates,
  fingerprints, and composed language. No DER bytes, no profile
  payloads, no passwords, no key references. Anything exported or shared
  from these screens carries the same public metadata.
- **Logs never contain certificate secrets** — the engines' fixed
  language is the only text they produce.
- **Authentication precedes sensitive actions** where the platform
  supports it (`SensitiveAction.removeIdentity`).

## Performance requirements

- **One read per store per snapshot** — the Keychain is read exactly
  once to compute everything the dashboard shows.
- **Cached health** — reports live inside the snapshot value; the model
  recomputes only on load, pull-to-refresh, mutation, or staleness
  (15 s) at next appearance.
- **Lazy rendering** — the dashboard and the graph render expanded
  content through lazy containers; collapsed teams render their header
  only.
- **Efficient grouping** — team grouping is a single pass over facts,
  with case-insensitive keys and stable ordering.

## Accessibility

Dynamic Type throughout; large row targets; Dark Mode via the design
tokens and `ZStatusBadge`; VoiceOver labels on every row, with spoken
health summaries (`IdentityHealthReport.spokenSummary`) and spoken
overall status on the dashboard; the relationship graph draws its lines
on a decorative Canvas behind real, individually-accessible node views,
and every team section is announced with its members.

## Release and tests

`ReleaseFeature.identityCenter` ships at `v0.1.0-alpha.3`, with
prerequisites `certificateStudio`, `smartSign`, and
`provisioningProfileManager`. Entry points: Settings → **Developer
Identity**, and toolbar links from the Certificates and Profiles tabs.
The signing screen's recommendation is gated by the same feature.

Coverage: `DeveloperTeamTests`, `IdentityHealthCenterTests`,
`IdentityConflictDetectionTests`, `ExpirationForecastTests`,
`IdentityTimelineTests`, `IdentityRecommendationTests`,
`IdentityCenterServiceTests`, and `IdentityCenterModelTests` — all over
synthetic certificate fixtures and in-memory store doubles; no key
material exists anywhere in the tests.
