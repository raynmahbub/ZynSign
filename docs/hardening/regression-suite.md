# Regression suite

A regression entry is a promise that a workflow still behaves the way it did
when it was built — not that it is correct in the abstract, but that it has not
silently changed.

## Two kinds of answer

The Lab keeps them apart, and the report shows which is which:

1. **Executed in-app.** An invariant ZynSign can assert about itself, in the
   running application. Nine of the eleven entries have one.
2. **Deferred to the test target.** Behaviour frozen by unit tests, which the
   Lab cannot run from inside the app. Two entries — Store and Downloads —
   defer, and say so.

A deferred row is reported as `Not run`, naming the tests that would settle it.
Claiming a test passed without running it would be the exact dishonesty this
suite exists to prevent.

## The catalogue

Every entry names the behaviour, the check the Lab runs (if any), and the test
types that freeze it. `Scripts/audit_regression_coverage.py` refuses a
catalogue that names a test type which does not exist — a name nobody keeps is
worse than no name.

| Workflow | In-app check | Frozen by (a selection) |
|---|---|---|
| Import | The files accepted and refused, unchanged | `ImportRulesTests`, `IPAPackageImportTests`, `SecurityScopedArtifactIntakeTests`, `ImportPreflightTests`, `ArchiveLimitsTests` |
| Library | Search folding across case, diacritics and width; sort orders | `ApplicationLibraryTests`, `LibraryIndexTests`, `ApplicationRecordDuplicatePolicyTests`, `LibraryPersistenceLifecycleTests` |
| Certificates | Every identity failure maps to the category its own vocabulary declares, with a user message of its own | `SecureIdentityStoreTests`, `SigningIdentityStorageBoundaryTests`, `IdentityKeychainErrorTests`, `KeychainIdentityIntegrationTests` |
| Profiles | Every profile failure maps to its category, with a message of its own | `ProvisioningProfileParserTests`, `ProfileExpirationIntelligenceTests`, `ProfileCompatibilityEngineTests`, `ProvisioningPolicyValidationTests` |
| Signing | The stage order: nested code before the application; the workflow order unchanged | `SignApplicationPipelineTests`, `NestedCodeSigningOrderTests`, `WorkflowStageTests`, `SigningEngineCoordinatorTests` |
| Verification | Only `valid` proceeds; a classification agrees with the findings behind it | `VerifySignedApplicationTests`, `ValidationResultTests`, `AppleSignatureVerifierTests`, `ExternalValidationExportTests` |
| Export | Naming never collides with what is present, and ZynSign recognises its own output | `PackageSignedApplicationTests`, `LibraryExportPreparationTests` |
| Store | — | `StoreResilienceTests` |
| Downloads | — | `DownloadsResilienceTests` |
| Installation | Even with perfect evidence, ZynSign reports that it cannot install, and names the absent mechanism first | `InstallationCapabilityTests`, `InstallationDeliveryTests` |
| Persistence | The preferences schema round-trips, and the shipped defaults survive it | `ZynSignPreferencesTests`, `FilePreferencesStoreTests`, `FileSigningQueueStoreTests`, `FileSigningPresetStoreTests` |

## Running it

```bash
# Everything, on a simulator or device (CI runs this on every push):
xcodebuild test -project ZynSign.xcodeproj -scheme ZynSign \
  -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest'

# The catalogue, checked against the test target:
python3 Scripts/audit_regression_coverage.py
```

## Reuse

The suite is the thing that makes the next candidate cheap. Run it:

- before promoting the train (nothing moves while it is red);
- after a hotfix, to prove nothing else moved;
- on a new iOS release, with the Compatibility Lab, before claiming support;
- before a beta, so a regression is found by a test rather than by a user.
