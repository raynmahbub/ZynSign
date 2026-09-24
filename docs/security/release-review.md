# Release Security Review

The final security review of the import, inspection, signing, and
verification work. It records what was reviewed, the findings and their
severity, where each threat area carries regression coverage, and the risks
accepted at release time. Findings are ordered by severity; accepted risks
are explicit rather than silent.

Review environment: Linux with Python 3 and OpenSSL, without a Swift
toolchain or Xcode. Static review, hygiene scans, and the host vector
scripts were executed; the XCTest suites were not executed here. Anything
below that depends on an executed test run is marked as requiring one.

## Scope

Archive intake and validation, property-list parsing, provisioning-profile
parsing and CMS verification, certificate parsing, Mach-O parsing and
signature-region construction, CodeDirectory and SuperBlob construction,
single-image and nested signing, signing metadata (entitlements,
requirements, CodeResources), the filesystem and in-memory artifact stores,
library persistence, logging and diagnostics, and repository hygiene.

Out of scope because unimplemented: the packaging writer, archive
extraction, the complete application pipeline, and installation. Their
absence is a functional gap, not a reviewed boundary; the architecture
records the corresponding feasibility items as open.

## Findings Fixed

### 1. Nested verification ignored per-target metadata — High (functional integrity)

`SignNestedCodeUseCase` re-derived each target's metadata preparation and
passed the expected slot layout and blob bytes into its independent
verification — which then ignored all three parameters and required every
binary to carry exactly a CodeDirectory and a CMS blob. Any nested target
embedding requirements or entitlements blobs failed post-sign verification
after being signed and verified correctly by the single-image pipeline.

Fixed in `ZynSign/Application/SignNestedCode.swift`: the check now
compares the embedded slot layout against the expected per-target layout,
requires the embedded requirements and entitlements bytes to equal the
prepared bytes, and binds both blobs to their CodeDirectory special-slot
digests, mirroring the single-image verifier. Regression coverage is the
existing `testNestedTargetsCarryTheirOwnMetadataOnly`, which asserts a
succeeding run with a four-slot SuperBlob on the metadata-bearing target.

Severity rationale: a verifier that rejects valid artifacts is an
integrity failure in the release-blocking path. It fails closed rather
than open — no invalid artifact was accepted — which is why this is High
and not Critical.

### 2. Filesystem store confinement fell short of a separator — Medium (path safety)

`FileNestedSigningArtifactStore` confined canonical targets with a bare
string-prefix check, so a symlink resolving to a sibling such as
`App.app-evil/x` passed confinement for a bundle rooted at `App.app`.
Reads and writes through such a link would have operated outside the
bundle.

Fixed in `ZynSign/Domain/NestedSigningArtifactStore.swift`: the canonical
target must now equal the bundle root or lie strictly beneath it, with the
boundary on a path separator. New `NestedSigningArtifactStoreTests` cover
the sibling-prefix escape for reads and writes, a plain outside-the-bundle
escape, and a legitimate nested read. No other string-prefix confinement
check exists in production code; the remaining `hasPrefix` uses are
absolute-path refusals and documented identifier-scope rules.

Severity rationale: the store operates on caller-supplied working
directories in a capability that is not composed into the application and
has no extraction path feeding it attacker-controlled symlinks today.
Exploitable only through a hostile working copy, hence Medium.

## Areas Reviewed Without Finding

- **ZIP path traversal and unsafe extraction:** entry names are validated
  before anything is read; absolute, escaping, malformed, over-long, and
  undecodable names are refused; duplicate locations keep the
  first-recorded entry and are counted. No extraction path exists.
- **Symlink handling:** links are listed, never followed, in the bundle
  explorer, which reads no entry content. The resource-sealing generator
  applies its fail-closed-or-exclude policy to whatever the store
  reports; the directory store's link detection itself is an accepted
  risk below, pending the Xcode runner.
- **Malformed plist and profile data:** bounded readers with typed errors;
  unknown keys preserved, unsupported types refused; payload parsed only
  after container verification.
- **CMS validation:** bounded structure reader, signed-attribute
  re-encoding with message-digest binding before any signature check,
  exactly-one-signer rule, serial-selected signer, fingerprint comparison.
- **Mach-O bounds and integer safety:** bounded parser, checked arithmetic
  at layout boundaries, explicit rejection of unsupported forms, narrow
  append-only writer preserving unrelated bytes.
- **CodeDirectory and SuperBlob construction:** version subset allowlist,
  explicit slot ordering, deterministic serialization, resource limits.
- **Nested-code path attacks:** plan validation rejects escaping paths,
  duplicates, cycles, and inconsistent relationships before any read.
- **Stale verification and tampering:** verifiers re-read artifact bytes
  and re-derive metadata; tamper suites exist for CMS, Mach-O signing,
  nested signing, and metadata.
- **Partial signing and atomicity:** staged working-copy strategy commits
  only after every target signs and verifies; direct mutation reports its
  state explicitly.
- **Temporary-file handling:** identifier-addressed staging, discard on
  every outcome, stale-leftover clearing, atomic writes via temporary
  files with cleanup.
- **Cancellation:** typed cancellation windows with discard; no retained
  partial state.
- **Sensitive logging:** no `print`/`NSLog`/`os_log`/`dump` call exists in
  production code; diagnostics carry states, codes, counts, and
  fingerprints — never key material, bytes, credentials, or identifiers.
  `preconditionFailure` appears only in SwiftUI preview fixtures.
- **External commands and private APIs:** no `codesign`/`xcrun`/shell-zip
  invocation, no process spawning, no private API, no jailbreak or trust
  bypass exists in production code. Mentions in prose are design records
  of non-use.
- **Repository hygiene:** no secrets, private keys, credentials, profiles,
  build products, machine-specific files, or reference metadata found;
  certificate text exists only as a synthetic rejection vector in one
  test fixture.

## Security Regression Corpus

Each area below names the suites that cover it. All suites are XCTest
cases requiring the Xcode runner except the host scripts, which were
executed in the review environment and passed.

| Area | Suites |
| --- | --- |
| Malformed archives | `ArchiveEntryTests`, `ArchiveLimitsTests`, `ArchivePathTests`, `IPAArchiveInspectionTests`, `IPAStructureValidationTests`, `ZipArchiveReaderTests` |
| Path traversal | `ArchivePathTests`, `BundlePathTests`, `CodeResourcesTests` (store policy), `IPAStructureValidationTests`, `NestedSigningArtifactStoreTests` (new) |
| Malformed plists | `ApplicationMetadataReaderTests`, `ProvisioningProfileParserTests`, `EntitlementsTests`, `CodeResourcesTests` |
| Provisioning and CMS | `CMSStructureReaderTests`, `CMSVerificationTests`, `CMSVerificationModelTests`, `AppleCMSSignatureVerifierTests`, `ProvisioningProfile*Tests`, `ValidateProvisioning*Tests`, `CertificateRelationshipTests` |
| Mach-O bounds | `ReadOnlyMachOParserTests`, `MachOInspectionTests`, `MachOCodeSignatureRegionTests` |
| CodeDirectory and SuperBlob | `CodeDirectoryConstructionTests`, `SuperBlobConstructionTests` |
| Nested code | `NestedCodeDiscoveryTests`, `NestedCodeGraphValidationTests`, `NestedCodeSigningOrderTests`, `NestedCodeSigningTests`, `NestedCodeFailureTests`, `NestedCodeDiscoveryInspectionTests` |
| Tamper detection | `CMSVerificationTests`, `MachOSigningIntegrationTests`, `MachOSigningAppleTests` (iOS-gated), `NestedCodeSigningTests`, `SigningMetadataIntegrationTests`, `ValidateProvisioningProfileUseCaseTests` |
| Packaging boundaries | No writer exists; reader-side coverage only (archive suites above) |
| Resource limits | `ArchiveLimitsTests`, `FileLibraryArtifactStoreTests`, intake tests, `MachOCodeSignatureRegionTests` |
| Key and identity boundaries | `SecureIdentityStoreTests`, `SigningIdentityStorageBoundaryTests`, `CryptographicBoundaryTests`, `CryptographicSigningEngineTests`, `SecurityBoundaryTests`, `KeychainIdentityIntegrationTests` (opt-in, device) |
| Host vectors (executed) | `Tests/Host/verify_macho_signing_vector.py`, `Tests/Host/verify_nested_code_signing_vector.py` |

## Accepted Risks

Accepted risks are Medium or Low. No Critical or High issue remains open.

- **Unexecuted suites (Medium):** the XCTest suites were authored against
  independently computed vectors but have not been executed in any
  environment with the toolchain. A first green run on hosted CI is
  required before any Alpha claim. Mitigation: host vectors executed and
  passing; balanced-delimiter and type-consistency review of the two
  fixes; no fix changes behavior for the previously passing paths.
- **Experimental signing stack without device evidence (Medium):**
  single-image and nested signing, the Keychain adapter, and CMS
  verification through platform primitives await the physical-device
  experiments E1, E3, E4, and E7. Mitigation: none of it is composed
  into the application or reachable from the interface.
- **No packaging writer review (Low):** there is no writer to review; the
  risk is schedule and scope, not an examined defect. Mitigation:
  packaging stays explicitly unimplemented until its feasibility item
  closes.
- **Defense-in-depth gaps in verifiers (Low):** the nested verifier does
  not re-check trailing padding zeros or the slot-3 digest input (the
  single-image verifier it delegates to checks both). Mitigation: the
  single-image post-sign verification runs first on every target and
  refuses before the nested check is reached.
- **Directory resource-store symlink handling unverified on the runner
  (Low):** `DirectoryResourceContentStore` detects symbolic links through
  `FileManager.attributesOfItem`, whose link-following behavior for the
  final path component must be confirmed on the Xcode runner, and it does
  not canonicalize intermediate components the way the nested-signing
  store now does. The existing `testDirectoryStoreSymlinkPolicy` decides
  the first question: if it fails, detection must move to a non-following
  query such as `isSymbolicLinkKey` before any release claim. Mitigation:
  the store is read-only, is not composed into the application, and has
  no extraction path feeding it hostile trees; the worst-case failure
  mode today is sealing a link target's bytes, not escape with a write
  primitive.
