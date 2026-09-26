# Release Readiness Center (Alpha gate)

The Center is a **local evidence report**, not a certificate of Apple acceptance
or permission to start Beta. Entry points exist in Settings, Home, Library (list
and grid), App Details, Smart Sign, and exported-artifact details.

## Workflow

1. Choose the library app, signing identity, and saved provisioning profile.
2. Select the specific produced IPA to verify. Output is never silently selected
   by recency: two exports can have different signing configurations.
3. Run Full Validation. Cancel is available; incomplete work is not shown as ready.
4. Review the weighted categories, blockers, warnings, inconclusive checks and
   successful checks. Expand an issue for scope and suggested action.
5. Reopen historical reports or use Export Validation Report to share plain text.

Input checks describe the selected configuration. Output checks describe the
actual embedded data of the selected IPA; the two are not claimed to be identical.
Exports whose source app has been deleted cannot run this combined input/output
workflow; their existing standalone Export Center verifier remains available.

## Evidence and scoring

| Category | Weight | Evidence |
| --- | ---: | --- |
| Structure | 20 | Existing bounded IPA layout, metadata, executable and nested-code diagnostics |
| Identity | 15 | Current identity metadata, key availability, certificate validity; saved default health |
| Profile | 15 | Existing authenticated profile validation and identifier/team/policy comparisons |
| Entitlements | 15 | Signing diagnostics plus Entitlements Studio comparisons for main-executable architectures |
| Signature | 20 | Fresh Binary Inspector pass on the produced IPA: CodeDirectory, page hashes, special slots, CMS mathematics and discovered nested executables |
| Package | 15 | Fresh exported-IPA verification and before/after SHA-256 measurements compared with the stored export fingerprint |

A category takes the worst observation. Verified = full weight; warning = half
weight rounded down; blocked, unsupported and unchecked = zero. All deductions
are visible. Any failed check makes the report Blocked, regardless of score.
Warnings alone never block actions. Missing/inconclusive evidence yields Attention,
never Ready. An empty report receives zero, not 100.

Critical input structure failures skip expensive entitlement/output passes. The
existing diagnostic analyzer may still evaluate identity/profile metadata so users
can see independent input problems. Failed output structure skips binary work.
The signing operation's prior success and saved verification verdict are never
used as fresh verification evidence.

## Deliberate limits — still outstanding before release approval

- Local CMS mathematics is not certificate-chain trust, revocation, platform
  authorization, device compatibility, installation or launch testing.
- The existing external-validation record reports resource-seal rejection and
  outstanding DER/iOS format work. Every report explicitly retains that boundary.
- Entitlements Studio compares supported main-executable declarations. Nested
  entitlement authorization and DER-only decoding are not established.
- Existing resource verification is bounded and does not implement Apple's entire
  resource-rule policy. Output findings expose incomplete coverage.
- Unsupported results never become green passes. With the present implementation
  limits, a genuine all-green production gate is deliberately not available.

## Storage, privacy and performance

`ReleaseReadinessService` composes existing validators, independently of SwiftUI.
`ReleaseReadinessReport` is versioned with stable rule IDs; future rules can add
observations without changing scoring or persistence. Reports retain only fixed
explanations, opaque app/export references, states and timestamps. App summary is
intentionally an opaque library record reference: names, bundle IDs, certificate
identifiers, profile contents, device identifiers, keys and credential data are not
exported. Dynamic binary paths and signer details remain in existing inspectors.

`ReleaseReadinessHistory` atomically replaces `ZynSignLibrary/ReleaseReadiness.json`.
It retains 10 reports per app, at most 50 overall, with an 8 MiB read/write bound.
Corrupt or unknown-version history is not silently reset. A history-write failure
leaves the current report available and displays a warning. History remains a
historical audit observation, including after app deletion, until bounded eviction.

No full release verdict is cached. Full validation forces a fresh input scan and
always reopens the output. The service's optional `force: false` path reuses only
the existing diagnostics' bounded, reference-keyed 60-second input archive cache;
identity, profile policy and expiration still re-evaluate. This is conservative
incremental reuse, **not** a complete dependency-cached pipeline or instant output
rescan. Byte hashing remains proportional to package size. The Center is isolated
from the main actor, binary processing streams one bounded target at a time, and
views retain redacted reports rather than executable bytes.

## Validation

`ReleaseReadinessTests` covers weights, worst-state precedence, warning/blocker
separation, unsupported/missing evidence, input-vs-signature separation, report
round-tripping, per-app/global history caps and corrupt-store handling.

Host vector tests and release-train checks can run on Linux. They do not compile
Swift or establish iOS acceptance. Xcode build/tests remain required on macOS.

Manual simulator/device acceptance still required:

- Navigate from all six entry surfaces; switch inputs and ensure old results clear.
- Scan missing/invalid inputs, expired identity/profile, unsigned output, changed
  output (including same-size replacement), nested code, and oversized targets.
- Cancel and navigate away during large-app validation; check responsiveness.
- Relaunch, reopen history, simulate storage failure and share a report; inspect it
  for credentials and dynamic signer/profile data.
- Test largest Dynamic Type, VoiceOver (including completion announcement), dark
  mode, Increase Contrast, and keyboard/switch navigation. Controls use system
  semantic styling, text/symbol status, multiline layout and 44-point action rows;
  accessibility is implemented but is not yet device-certified.
