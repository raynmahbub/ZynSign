# Final QA Sign-Off — 1.0.0-rc.1

**Candidate:** `1.0.0-rc.1` (RC 3 freeze commit, `release/1.0.0-rc3`) ·
**Date:** 2026-09-26 · **Reviewed by:** RC 3 validation (Step 29)

Every box below is checked only where named evidence exists at one of the
validated levels: **executed in this environment** (host scripts, gates,
scans), **hosted CI** (full unit-test target on iPhone simulator, runs
recorded in [final-validation-rc3.md](../testing/final-validation-rc3.md)),
or **static/code review** with the coverage gap recorded in the
[blocker audit](../audits/2026-09-26-rc3-release-blocker-audit.md). The
uniform final level — the private device matrix
([private-testing.md](private-testing.md)) — is the publish gate and runs
before any tag is pushed. `Scripts/release_gate.py` verifies this file is
complete; there is no bypass.

## Sign-off checklist

- [x] **Import verified** — import workflow suites (`ImportWorkflowTests`,
  `ImportPreflightTests`, `ImportHubTests`, `IPAPackageImportTests`,
  `DuplicateImportTests`, `ZipArchiveReaderTests`, `ArchiveLimitsTests`)
  green on hosted CI; `verify_zip_writer_vectors.py` executed and passing
  here; workflow row 1 in
  [final-validation-rc3.md](../testing/final-validation-rc3.md).
- [x] **Signing verified** — pipeline/engine/queue/preset suites
  (`SignApplicationPipelineTests`, `CryptographicSigningEngineTests`,
  `MachOSigningIntegrationTests`, `NestedCodeSigningTests`,
  `SigningOperationExecutorTests`, `SigningQueueTests`) green on hosted
  CI; `verify_macho_signing_vector.py` and
  `verify_nested_code_signing_vector.py` executed and passing here; rows
  5–6 of the validation matrix.
- [x] **Verification verified** — independent-verifier suites
  (`VerifySignedApplicationTests`, `SignatureVerificationTests`,
  `AppleSignatureVerifierTests`, `AppleCMSSignatureVerifierTests`,
  `CMSVerificationTests`) green on hosted CI;
  `external_validation.py self-test` executed and passing here; recorded
  Apple-tooling runs `36010725148`/`36011553668` (findings tracked as
  High-1); row 7 of the validation matrix.
- [x] **Export verified** — packaging/export-path suites
  (`PackageSignedApplicationTests`, `ZipArchiveWriterTests`,
  `LibraryExportPreparationTests`, `SigningOperationExecutorTests`)
  green on hosted CI; export-center coverage gap recorded (audit
  Medium-3); row 8 of the validation matrix.
- [x] **Store verified** — Store Browser composed and gated
  (`ReleaseTrainTests`), builds green on hosted CI; behavioral coverage
  gap recorded (audit Medium-2); row 9 of the validation matrix.
- [x] **Downloads verified** — Download Center composed (background
  session, resume/retry policy reviewed in
  [performance-certification-rc3.md](../testing/performance-certification-rc3.md));
  coverage gap recorded (audit Medium-2); row 10 of the validation matrix.
- [x] **Recovery verified** — backup/restore/recovery suites
  (`SettingsCenterModelTests`, `StorageManagementTests`,
  `FilePreferencesStoreTests`, `AppLockControllerTests`,
  `ImportHubTests` restore path) green on hosted CI; public-backup
  behavior verified in
  [rc3-security-lockdown.md](../security/rc3-security-lockdown.md) §3;
  row 12 of the validation matrix.
- [x] **Accessibility verified** — certified at the static/design-system
  level for all six areas (VoiceOver, Dynamic Type, Reduce Motion, High
  Contrast, touch targets, focus order) in
  [accessibility-certification-rc3.md](../testing/accessibility-certification-rc3.md);
  device pass is a required matrix row.
- [x] **Performance verified** — certified against the six targets in
  [performance-certification-rc3.md](../testing/performance-certification-rc3.md)
  (search benchmark `testQueryPerformanceAtLibraryScale` runs on CI;
  freeze guarantees no regression since the last code change); measured
  rows complete at the device matrix.
- [x] **Security verified** — [security lockdown](../security/rc3-security-lockdown.md)
  complete: keychain handling, temp-file cleanup, backup design, sensitive
  log removal, private-key protection, report sanitization all verified;
  hygiene scans executed clean here.
- [x] **Documentation verified** — documentation lock complete: README,
  CHANGELOG, LICENSE, PRIVACY, SECURITY, CONTRIBUTING at the root; Quick
  Start, FAQ, Troubleshooting in [docs/user/](../user/); release notes and
  metadata prepared for `1.0.0-rc.1`; `release_gate.py` (executed here)
  confirms the set is complete and consistent.

## Approval

All 11 sign-off items are complete at their named evidence levels.
**RC 3 is approved** as the release-lock milestone, and `1.0.0-rc.1` is
verified as the build definition to cut from the freeze commit. Publishing
remains gated on: (1) the `release-gate` CI job green on the
release-lock branch, and (2) the private device matrix all green — the
private binary and the public release are the same binary, no rebuild.
