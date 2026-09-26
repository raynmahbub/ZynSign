# Entitlements Studio — Alpha 3, Step 17

## Entry points and contract

Library → App Details → **Entitlements Studio** (also linked from Sign Application).
The `entitlementsStudio` release feature starts at Alpha 3; ordinary Debug builds
expose it without changing the release version. To preview: launch with
`-ZynSignReleaseStage alpha3`.

This is a **read-only, declared-data inspector**, not an entitlement editor, a
signature verifier, an authenticated provisioning-policy verdict, or a prediction
of installation/platform acceptance. The existing signing pipeline still owns its
validation. The Studio does not add, remove, rewrite, or grant any app claim.

The current signing pipeline derives **output** claims from the chosen profile.
Studio cards instead describe the app's **embedded XML requests**. Both screens
state this distinction; a profile's allowlist is never presented as app requests.
A missing or unsupported profile entitlement dictionary no longer silently becomes
an empty signing set. Explicitly decoded empty dictionaries remain distinguishable
from missing data.

## Layers

- `EntitlementsStudioInspection` reads one declared main executable through
  `ArchiveReader`, with a 64 MiB expanded read ceiling, and the injected `MachOParsing`
  boundary. No extraction, symlink following, or executable loading occurs. Duplicate
  executable entries and unsafe executable names are refused. The application use
  case rechecks library availability and closes the reader on all outcomes.
- The composition root supplies a separate content-reader budget; the Bundle
  Explorer's 4 MiB metadata policy is unchanged. Executable bytes are discarded after
  typed claims have been obtained. Universal binaries produce a selectable target
  for **every architecture**; no first-slice consensus is invented.
- `EntitlementCapability` is an extensible friendly-name/category registry. Unknown
  keys remain visible under Other / Unknown. Background Modes are explicitly described
  as Info.plist declarations, not invented as entitlements.
- `EntitlementsStudioAnalyzer` is deterministic, typed and independent of SwiftUI.
  It reuses identifier matching and the conservative provisioning value comparator.
  Its structured findings feed the dashboard, cards, inspector, report and Smart
  Diagnostics. `DiagnosticCategory` is reused; findings/values are not journalled.
- `EntitlementsStudioModel` is the App Details session shared with Signing. Source
  claims are cached per artifact; profile declarations/signing claims are parsed
  once per selection. The latest analysis is a single bounded cache entry keyed by
  claims, profile, certificate identity/team, target and effective DER configuration.
  All effective changes invalidate it without a refresh. Generation checks reject
  stale background results; removal cancels pending profile work. File reads,
  parsing, comparisons and report serialization run away from UI work.
- SwiftUI `List`/`ForEach` provide lazy cards; search uses cached normalized name,
  key, category and status strings. Array membership uses a set to avoid quadratic
  allowlist comparisons. List previews are bounded; full typed text is formatted
  only in inspectors or explicit exports.

## Checks and limits

| Observation | Studio treatment |
|---|---|
| Exact supported value match | Compatible **for that comparison**, not authorization |
| App key missing from an available profile allowlist | Blocked; choose a profile declaring it |
| Definite type/value conflict | Blocked |
| Certificate OU versus declared profile team | Declared consistency/conflict only; not certificate membership or trust |
| Bundle/application identifier | Shared explicit-prefix and exact/trailing-wildcard rules; app prefix need not equal team ID |
| `get-task-allow` | Dedicated boolean/absence rules; false is not assumed equivalent to absence |
| Capability-specific wildcard, subset or reordered array | Warning where semantics are not established |
| Unknown key with equal values | Unknown interpretation; equality is explained rather than promoted to capability support |
| Unsupported value form / missing source or profile | Unknown, not an empty compatible set |
| Malformed XML blob / DER-only claims | Explicit limitation; no empty-set fallback |
| DER output preference | Encoding context updates, without changing app claims |

Overall status includes context findings as well as card findings. Card counts are
mutually exclusive and sum to the displayed total. Unauthenticated profile data and
unimplemented scope checks keep the overall result at **Attention**, even if every
card matches. Definitive conflicts take precedence as **Blocked**. Signing from the
UI is disabled for a detected conflict in **any** inspected architecture, including
an architecture not currently selected. Unknown/Warning findings do not pretend to
be pipeline refusals; the pipeline still decides whether an operation is supported.

This step does not inspect extension entitlements, decode DER-only claims, authenticate
profile CMS, verify certificate membership/trust/validity, check devices, contact
associated-domain servers, or infer runtime consent. It does not apply saved prefix
or plug-in preferences from the legacy Signing Options screen (those preferences
are not inputs to today's `SignApplicationRequest`). Only effective signing inputs
are compared. Mach-O structural parsing is reused, not expanded into Step 18 here.

## Reports and privacy

Export produces a versioned JSON snapshot with app name/bundle ID, selected
architecture, complete entitlement list (irrespective of search), statuses,
explanations, context checks and ISO-8601 timestamp. Export uses Files, not an
unmanaged temporary report directory. It has no edit/import-back path in the app.

The report projection accepts no identity-store handle, certificate, profile body,
private key, credential or filesystem URL. Binary contents and unknown-key values
are omitted; structured values and sensitive-looking strings are redacted. Known
entitlement identifiers may remain: the UI warns users to share thoughtfully.
Inspection on screen preserves all parsed values (binary values are described by
length). Reports do not grant authorization or certify a signature.

## Validation

Added XCTest suites cover mappings, unknown preservation, counts, missing versus
empty input, type mismatches, team/bundle/application prefix checks, debugging
semantics, wildcard/subset uncertainty, search/filter intersection, 10,000 keys,
report scope/privacy, embedded/unsigned/malformed/DER-only claims, unsafe/duplicate
entries, reader closure, profile replacement/removal races, cached source reuse,
retry, live certificate/DER changes, and conflicting universal architectures.
Release-train tests cover the Alpha 3 gate. The obsolete rollout assertions were
aligned with the feature stages already present in `ReleaseTrain`.

Run on a Mac with Xcode:

```sh
xcodebuild test -project ZynSign.xcodeproj -scheme ZynSign \
  -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' \
  -only-testing:ZynSignTests/EntitlementsStudioTests \
  -only-testing:ZynSignTests/EntitlementsStudioInspectionTests \
  -only-testing:ZynSignTests/EntitlementsStudioModelTests \
  -only-testing:ZynSignTests/ReleaseTrainTests
```

Manual device/simulator acceptance (not established by source-level checks):

- At every Dynamic Type size, cards and technical values wrap; comparison switches
  to stacked App/Profile columns at accessibility sizes.
- VoiceOver reads explicit status labels, metric names/counts, column headings and
  navigation actions. Status is communicated by text and symbols, not color alone.
- Dark Mode uses semantic styles; Increase Contrast switches status text to primary.
- Import/remove/export/inspect actions have at least 44-point targets. Native pickers,
  toggles, navigation and disclosure controls retain platform accessibility.
- Rapidly replace profiles and certificates; no stale verdict is displayed. Change
  DER and confirm the configuration finding updates without altering app values.
- Filter/search large sets, inspect an unknown key, export with an active filter,
  cancel the save picker, and test a failed save. Export must contain the full target.
- Open a universal input with differing claims; inspect both and confirm a hidden
  architecture conflict still disables signing.
