# Binary & Signature Inspector — Alpha 3, Step 18

## Entry points and contract

Library → App Details → **Binary & Signature Inspector** for any library
record, and the same workspace for a **signed package** ZynSign wrote to its
signed directory after a completed signing run. The inspector is opened from
the IPA Explorer's detail screen, so bundle structure and executable
inspection share one reading path.

This is a **read-only structure and verification workspace**. It does not
modify an executable, generate or replace a signature, extract a package,
evaluate certificate trust, check revocation, or claim that iOS will install
or launch an application. It reads bytes through the existing bounded
`ArchiveReader` boundary, discards them after producing typed value reports,
and closes the reader on every outcome.

The central reporting rule: **a check is `Passed` only when it actually ran
and compared something, `Not Performed` (with a reason) when it could not,
and never a silent pass.** A check that could not be completed explains why.
Unsigned code is reported as *Unsigned*, which is a fact, not a failure.
Passing checks are always shown with a scope note stating that they do not
imply certificate trust or platform acceptance.

## Layers

- `IPABinaryInspection` (application) runs one **bundle pass** for a source —
  a library record or a signed package — and emits
  `BinaryInspectionEvent`s as they happen: discovery, then per target
  structure-ready, verification progress, and completion or a typed
  limitation. It owns the read budget (`BinaryInspectionLimits`: 256 MiB per
  executable, 128 nested targets, 1 MiB per nested Info.plist, 16 MiB per
  resource seal, 256 MiB per sealed file) and the reader lifecycle. Signed
  packages are accepted only from the permitted directory and are never
  opened outside it. Nothing is extracted and nothing is written except a
  report the user explicitly exports.
- `BinaryTargetDiscovery` (domain) names the main executable from the
  record's or the bundle's declared name, then finds conventional nested
  executables — `Frameworks/*.framework`, `PlugIns`/`Extensions/*.appex`,
  `Watch`/`AppClips/*.app`, root `*.dylib` — by entry-table name and kind.
  Declared names that fail the bundle-path safety rules are refused and fall
  back to platform naming. Beyond the bound, executables are counted as
  omitted, never silently dropped.
- Parsing reuses the ZS-022 boundary (see
  [macho-inspection.md](macho-inspection.md)): `MachOParsing`
  (`ReadOnlyMachOParser`) decodes thin and universal images with bounded
  readers, and `MachOLoadCommandDecoding`
  (`ReadOnlyMachOLoadCommandDecoder`) decodes load commands into typed
  payloads. Refusals are classified at the boundary, not guessed: a
  non-Mach-O byte range is `notMachO`, an existing signature the parser
  refused is `malformedSignature`, and a structural Mach-O refusal is
  `malformedMachO`. A rejected target is reported with its reason while the
  pass continues for the remaining targets.
- `BinarySignatureVerifier` (application) verifies one parsed image on
  device, per slice: it re-hashes every page of code with the CodeDirectory's
  own algorithm and page size, re-hashes bound special-slot content (the
  bundle's Info.plist, the resource seal, requirements and entitlements
  carried in the signature) and compares with the recorded digests, and hands
  the CMS payload to the `CodeSignatureCMSVerifying` port, which checks the
  message digest against the CodeDirectory and the signature against the
  embedded signer certificate's public key. It reads the bytes it is given
  and writes nothing. The production composition wires the platform CMS
  verifier; tests inject a stub so outcomes are deterministic.
- The domain types are plain value reports: `BinaryInspectionReport` (target,
  container, per-architecture structure, signature summary, integrity
  report), `BinaryHealthEvaluator` (headline plus typed findings),
  `BinarySignatureTimeline` (the lifecycle the signature went through, with
  the signer-declared signing time labelled as *not a trusted timestamp*),
  `BinaryComparator` (meaningful differences between two states),
  `BinarySearchIndex` (case- and diacritic-insensitive, every-word matching
  over load commands, libraries, architecture and signature fields), and
  `BinaryInspectionReportRenderer` (text/JSON export projection).
- `BinaryInspectorModel` (presentation, main actor) applies the event stream
  so each executable card shows structure immediately and fills in its
  verdict when verification finishes. Search is scoped to the visible page
  (dashboard, one architecture, or signature fields), the index is built
  once per report state, and on-demand sealed-file re-hashing and export
  are explicit user actions.

## Verification semantics

Each architecture produces eight checks with a status of `passed`,
`warning`, `failed`, `notPerformed` (with reason), or `notApplicable`:

| Check | What passing establishes | What it never claims |
|---|---|---|
| CodeDirectory | The directory is readable, its version is supported, its page coverage agrees with its code limit, and its hash type is one ZynSign computes | That any digest still matches the code |
| Page hashes | Every page was re-hashed on device with the declared algorithm and page size and equals the recorded hash | That the OS accepts the code |
| Special slots | Each bound slot's content was re-hashed and equals the recorded digest; content that exists but is unbound is reported as unprotected | Whole-bundle integrity beyond the named content |
| CMS signature | The CMS message digest equals a CodeDirectory digest, and the signature verifies with the embedded signer's public key | Certificate trust, chain, validity or revocation |
| Requirements | The requirement set decodes | Any requirement's semantics or satisfaction |
| Entitlements | The entitlements decode as a property list | Provisioning authorization for any of them |
| Nested signatures | Every discovered nested executable was verified, with omissions stated | The state of code beyond the bound |
| Certificate trust | — (never performed) | It is shown as not evaluated and excluded from the verdict |

The verdict aggregates only the checks that affect it: *Unsigned* when no
slice is signed, *Failed* on any contradiction, *Warning* when a check
could not be completed or deserves attention, and *Valid* only when
everything that applies passed. A check that cannot be completed is never
counted as passing, and certificate trust can never make a verdict better or
worse. Resource integrity distinguishes *sealed and bound*, *seal changed*,
*seal missing*, *not sealed*, and *not checked* — the on-demand sealed-file
pass re-hashes only files the seal lists by SHA-256 and says so.

## Comparison and reports

Comparison is offered against the other library records and against signed
packages in the permitted directory. A main executable compares only with
the main executable of the other package; nested code compares by location
(the executable's bundle-relative path). The report lists meaningful
differences only — size, architectures, signature presence and form, signer,
CodeDirectory fields, entitlement keys, linked libraries, build version, and
the per-check verification outcomes — and states explicitly when two states
are the same. It never renders raw bytes, raw hash lists, or byte-level
diffs, and a check that could not run on one side is shown as such.

Export renders one readable report per selection — text or JSON — with the
application identity, per-executable summary, architectures, signature
fields, verification results and checks, timestamps, and the generator. The
report states what it excludes: **no private keys or credentials, no
certificate data, serial numbers or fingerprints, no entitlement values
(keys only), no raw page-hash or digest bytes, and no content outside the
bundle.** The file is written to the app's temporary export directory for
the share sheet; the inspector has no import-back path.

## Performance and safety

- Reads are bounded before they happen: declared size beyond a limit yields
  a typed `exceedsReadLimit` limitation without reading; the parser's own
  input ceiling matches the executable bound.
- Structure is streamed before verification, so the interface is populated
  while page hashing runs; verification progress is reported per page
  interval and cancellation is checked along the way.
- Search indexes are built once per report and match on pre-folded text;
  lists are lazy and previews stay bounded.
- The workspace is read-only: no extraction, no executable loading, no
  writes except an explicit user export, readers closed on every outcome,
  and temporary exports confined to the app container.

## Validation

Added XCTest suites drive the production parser, decoder, and verifier over
synthetic parser-valid Mach-O images whose page hashes are real SHA-256
digests (`BinaryInspectionFixtures`, with prepared CMS outcomes through
`StubCodeSignatureCMSVerifier`): the bundle pass and its event order,
tampered code and tampered seals, unsigned and non-Mach-O and
corrupted-signature inputs, read bounds and reader closure, nested
discovery and per-target inspection, sealed-file re-hashing on demand,
comparison candidates and location matching, and signed-package directory
refusal. Domain suites cover search matching, comparison categories, the
timeline, export content and exclusions, the verdict policy, per-architecture
aggregation, nested-signature evaluation, health findings, and target
discovery including unsafe-name refusal. The model is driven through its
event stream without a package.

Run on a Mac with Xcode:

```sh
xcodebuild test -project ZynSign.xcodeproj -scheme ZynSign \
  -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' \
  -only-testing:ZynSignTests/IPABinaryInspectionTests \
  -only-testing:ZynSignTests/BinaryInspectorDomainTests \
  -only-testing:ZynSignTests/BinaryInspectorModelTests
```
