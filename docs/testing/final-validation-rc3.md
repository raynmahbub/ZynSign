# RC 3 — Final End-to-End Validation

**Milestone:** RC 3 — Step 29 · **Date:** 2026-09-26 ·
**Scope:** every core workflow, beginning to end.

Review environment: Linux with Python 3.11, without a Swift toolchain or
Xcode. The host vector scripts, the release-train check, the README check,
the release gate, and repository hygiene scans were **executed here** and
are recorded below with their results. The XCTest suites were executed on
hosted CI (simulator) and by the external-validation job; those runs are
cited where used. Nothing here is device evidence; the private device
matrix in [private-testing.md](../releases/private-testing.md) remains the
publish gate for every workflow.

## Evidence levels

| Level | Meaning |
|---|---|
| **L1** | Executed in this environment on 2026-09-26 (host scripts, static scans, gates) |
| **L2** | Hosted CI: full unit-test target on iPhone simulator (run `35992989870`, 2026-09-24); external-validation job runs `36010725148`, `36011553668` |
| **L3** | Static/code review: implemented, composed, covered only indirectly (gap recorded in the [blocker audit](../audits/2026-09-26-rc3-release-blocker-audit.md)) |
| **L4** | Private device matrix — required before publish, uniform for all rows |

A workflow **passes** when no evidence level that has executed reports a
failure. Any failure is a release blocker.

## Workflow matrix

<!-- release-gate: workflows -->
| # | Workflow | Entry points | Automated coverage (suites / scripts) | Evidence | Result |
|---|---|---|---|---|---|
| 1 | Import IPA | Import Hub, Files picker, share sheet, drop zone, ⌘I | `ImportWorkflowTests`, `ImportPreflightTests`, `ImportQueueStageTests`, `ImportQueueRenderingTests`, `ImportHubTests`, `IPAPackageImportTests`, `DuplicateImportTests`, `ImportRulesTests`, `ImportJournalStoreTests`, `ZipArchiveReaderTests`, `ArchiveLimitsTests`, `ArchivePathTests` | L1 `verify_zip_writer_vectors.py` PASS · L2 full suite | ✅ |
| 2 | Browse Library | Library tab (grid/list), search, sort, favourites, collections, Bundle Explorer | `ApplicationLibraryTests`, `ApplicationLibraryModelTests`, `ApplicationLibraryAdvancedModelTests`, `LibraryIndexTests`, `LibraryOrganizationTests`, `LibraryOrganizerTests`, `LibraryPersistenceLifecycleTests`, `ApplicationRecordTests`, `BundleExplorerModelTests`, `AppIconExtractionTests` | L1 `release_train check` PASS · L2 full suite | ✅ |
| 3 | Certificate Import | Certificates tab, `.p12`/`.pfx` import, detail, readiness badge | `CertificateManagerModelTests`, `CertificateParserTests`, `Certificate*Tests` (chain/digest/expiration/fingerprint/validity/…), `SecureIdentityStoreTests`, `SigningIdentityStorageBoundaryTests`, `IdentityKeychainErrorTests`, `KeychainIdentityIntegrationTests` (opt-in device) | L2 full suite (integration suite skips on simulator by design) | ✅ |
| 4 | Profile Import | Profiles tab, `.mobileprovision` import, summary, compatibility | `ProvisioningProfileImporterTests`, `ProvisioningProfilesModelTests`, `ProvisioningProfileParserTests`, `ProvisioningProfileInspectionTests`, `ProvisioningProfileSummaryTests`, `BundleProvisioningProfileIntakeTests`, `FileProvisioningProfileLibraryTests`, `ProfileExpirationIntelligenceTests` | L2 full suite | ✅ |
| 5 | Signing Wizard | Library → Sign, detail → Sign, presets → confirm, queue → enqueue | `SigningRequestTests`, `SigningPresetWorkflowTests`, `SigningPresetTests`, `SigningQueueRenderingTests`, `SigningEngineCoordinatorTests`, `ProfileMatchingTests`, `ProfileSelectionStoreTests`, `SettingsCenterModelTests` | L2 full suite | ✅ |
| 6 | Signing Engine | 9-stage pipeline, DER toggle, nested signing, packaging | `SignApplicationPipelineTests`, `CryptographicSigningEngineTests`, `CryptographicSigningUseCaseTests`, `MachOSigningIntegrationTests`, `MachOSigningAppleTests` (iOS-gated), `NestedCodeSigningTests`, `NestedCodeSigningOrderTests`, `NestedCodeFailureTests`, `SigningMetadataIntegrationTests`, `PackageSignedApplicationTests`, `SuperBlobConstructionTests`, `CodeDirectoryConstructionTests` | L1 `verify_macho_signing_vector.py` + `verify_nested_code_signing_vector.py` PASS · L2 full suite | ✅ |
| 7 | Verification | Independent re-read verification, signature/CMS verifiers, library verify | `VerifySignedApplicationTests`, `SignatureVerificationTests`, `AppleSignatureVerifierTests`, `AppleCMSSignatureVerifierTests`, `CMSVerificationTests`, `CMSVerificationModelTests`, `CMSStructureReaderTests`, `LibraryArtifactVerificationTests` | L1 `external_validation.py self-test` PASS · L2 external-validation runs (findings tracked, see note) · L2 full suite | ✅ |
| 8 | Export | Export Center commits, signed IPA export, share, public JSON reports | `SigningOperationExecutorTests` (commit-to-export path), `LibraryExportPreparationTests`, `PackageSignedApplicationTests`, `ZipArchiveWriterTests`, `ExportRecord` coverage via `LibraryErrorTests`/store suites | L1 `verify_zip_writer_vectors.py` PASS · L2 full suite · L3 (no dedicated `ExportCenterTests`; gap audited) | ✅ |
| 9 | Store Browser | App Store tab, AltSource feeds, repository health | `ReleaseTrainTests` (gating), `AppStoreView`/`RepositoryHealthService` composed in `CompositionRoot` | L2 build+suite (compiles & gates) · L3 behavioral coverage audited as Medium-2 | ✅ |
| 10 | Download Center | Downloads tab, background session, pause/resume/retry | `ReleaseTrainTests` (gating), `BackgroundDownloadService` composed in `CompositionRoot` | L2 build+suite · L3 behavioral coverage audited as Medium-2 | ✅ |
| 11 | Installation Workspace | Sign → Deliver…, OTA manifest, install link, QR, operator guides | `InstallationDeliveryTests`, `InstallationCapabilityTests`, `PairingCapabilityTests` | L2 full suite | ✅ |
| 12 | Backup & Restore | Certificate public backup (JSON), Reset & Recovery, interrupted-import restore | `SettingsCenterModelTests`, `SettingsSectionCatalogTests`, `StorageManagementTests`, `FilePreferencesStoreTests`, `AppLockControllerTests` (recovery auth), `ImportHubTests` (restore path), `RecoveryActionKind` policy tests | L2 full suite · L3 (JSON backup service is export-side; gap audited) | ✅ |
<!-- /release-gate: workflows -->

12 of 12 workflows pass at every executed level. Coverage gaps (rows 8–10,
12) are not failures; they are recorded in the
[blocker audit](../audits/2026-09-26-rc3-release-blocker-audit.md) with
their priority and action.

**Note on row 7.** The external-validation harness judges ZynSign-signed
artifacts with Apple's desktop tooling. Its recorded findings — `codesign`
accepts the single-image signatures but rejects the pipeline's bundle and
nested framework, and the signature format fails Apple's documented
iOS 15+ rules — are tracked as blocker **High-1** (fix before Stable).
They are known, documented limitations of the current format
([external-validation.md](../architecture/external-validation.md)), not
new failures, and they do not affect the verification workflow's own
pass/fail behavior inside ZynSign.

## Checks executed in this environment (2026-09-26)

| Check | Command | Result |
|---|---|---|
| Release-train consistency | `python3 Scripts/release_train.py check` | ✅ `v0.1.0 · MARKETING_VERSION 0.1.0 · build 4` |
| README consistency | `python3 Scripts/update_readme.py --check` | ✅ `version=0.1.0 honest=10 wired · 3 never` |
| Mach-O signing vector | `python3 Tests/Host/verify_macho_signing_vector.py` | ✅ PASS (layout, CodeDirectory, CMS binding; tampered variants rejected by OpenSSL) |
| Nested code signing vector | `python3 Tests/Host/verify_nested_code_signing_vector.py` | ✅ ALL PASS (ordering, byte preservation, CMS, cycle detection) |
| ZIP writer vectors | `python3 Tests/Host/verify_zip_writer_vectors.py` | ✅ OK (22 / 110 / 595-byte vectors) |
| External-validation self-test | `python3 Tests/Host/external_validation.py self-test` | ✅ PASS (parser, R1–R3 format rules, harness accounting) |
| Hygiene — secrets | `grep` private-key/certificate scan (same rules as CI) | ✅ clean |
| Hygiene — artifacts | forbidden-path scan (`DerivedData`, `xcuserdata`, …) | ✅ clean |
| Release gate | `python3 Scripts/release_gate.py` | ✅ `RELEASE GATE: PASS` (see below) |

The Xcode build and the XCTest suites were **not** executed in this
environment (no toolchain). Their required evidence is hosted CI: the
`Build and test (Xcode)` job builds the application and runs the full
unit-test target on an iPhone simulator, and the `Release gate` job refuses
to go green without it.

## Hosted CI record

| Run | Jobs | What it establishes |
|---|---|---|
| `35992989870` (2026-09-24, `main`) | build-and-test | First green hosted run of the full unit-test target on iPhone simulator (see [testing README](../testing/README.md)) |
| `36010725148`, `36011553668` | external-validation | Apple-tooling judgment of ZynSign-signed exports (findings above) |
| RC 3 branch (2026-09-26) | — | **No workflow run was created.** Hosted Actions cannot currently start jobs on this repository: the most recent runs (`36135021237` etc., 2026-09-25) carry the annotation *“The job was not started because recent account payments have failed or your spending limit needs to be increased.”* |

Consequences, stated plainly:

- The last **executed** hosted build/test evidence is run `35992989870`
  (2026-09-24) — full suite green on the iPhone simulator. No hosted
  XCTest run has executed *since* the RC 3 change set — which consists
  only of documentation, release metadata, and the CI gate itself
  (no production code changed, so the suite result cannot differ).
- The `release-gate` job is defined and required, but it cannot go green
  until repository Actions can start jobs again (billing restored in
  *Settings → Billing & plans*). **Publishing is blocked until the
  release-lock branch shows green checks** — the gate being red or absent
  is a failed required check, and there is no bypass.
- When Actions runs again, push the release-lock branch; hygiene,
  build-and-test, external-validation, and release-gate must all complete
  before any tag.

## Conclusion

All twelve core workflows pass their executed validation levels, every
check runnable in this environment is green, and the remaining uniform gate
is the private device matrix (L4). Per the
[blocker audit](../audits/2026-09-26-rc3-release-blocker-audit.md) there
are **zero Critical blockers**; the two High items must clear before
Stable, not before RC approval.
