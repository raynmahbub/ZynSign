# Changelog

All notable changes to ZynSign will be documented here.

## [Unreleased]

### Added

- Complete application-signing pipeline: a nine-stage application-layer
  workflow (integrity, profile, discovery, extraction, nested signing,
  resource sealing, main-executable signing, packaging, independent
  verification) that signs an unsigned container end to end, delivers
  nothing when any stage refuses, and reports the refusing stage with a
  typed reason. Success-path tests sign synthetic containers assembled
  at run time; refusal tests prove each stage fails closed. The pipeline
  is constructed at the composition root but not installed in the
  application environment: no signing interface is composed until device
  validation completes. Existing signatures are rejected (the machinery
  appends and refuses replacement), nested targets sign without their
  own resource seals, and symbolic links are recorded as seal
  omissions; see `docs/architecture/application-signing-pipeline.md`.
- Deterministic packaging (`ArchiveWriter` port, `ArchiveWritePlan`,
  `ZipArchiveWriter`, `PackageSignedApplication`): a validated entry
  set, ascending UTF-8 recorded-name order with implied parents, fixed
  timestamps and modes, preserved executable bits and links, and a
  stored-only ZIP32 layout held by independent golden vectors. Every
  rebuilt container is reopened through the ordinary archive boundary
  and must pass structural validation, bundle discovery, and an exact
  plan comparison, or it is removed and reported.
- Safe archive extraction (`DirectoryArchiveExtractor`): validate-all-
  first ordering, canonical-path confinement, directories before files
  before links, an explicit symlink policy (refused by default,
  recreated within the destination for the signing working copy), and
  permission bits from recorded Unix modes. `ArchiveEntry` carries the
  recorded mode when the container records one.
- Independent signed-application verification
  (`VerifySignedApplication`): structure, metadata, executable
  presence, exact profile and seal bytes, re-computed seal digests,
  main-executable signature presence with embedded entitlements and the
  slot-3 binding, and nested-executable signature presence, checked
  against expectations captured from the signing run.
- Host vector script `Tests/Host/verify_zip_writer_vectors.py`,
  wired into the continuous-integration workflow: it reads the
  committed golden vectors and checks structure, fixed fields, modes,
  CRC-32, ordering, offsets, and `zipfile` acceptance with the Python
  standard library only. It was executed in this environment and
  passed; it checks the vectors, not the Swift implementation.
- Installation-capability assessment (`InstallationEvidence`,
  `InstallationLimitation`, `InstallationAssessment`): a pure function
  reporting installation as unavailable with exact limitations,
  including the platform fact that no supported delivery mechanism
  exists. The model carries no installable case.
- Composition-root factories for the archive writer, packager,
  verifier, and signing pipeline, following the established convention
  that unvalidated capabilities are built but not installed in any
  interface.

### Fixed

- Two latent compile errors in the signing stack: the throwing
  `CodeDirectoryHashConfiguration` initializer was called with no
  `try` covering the expression in per-item nested signing
  (`ZynSign/Application/SignNestedCode.swift`), and the throwing
  `FileResourceSeal` initializer was called with no `try` covering
  the expression in the resource-seal generator
  (`ZynSign/Domain/ResourceSealing.swift`). The nested-signing site
  now constructs the configuration in a `do`/`catch` and reports
  failure in the function's own vocabulary; the generator propagates
  the (unreachable, length pre-checked) error with `try`.
- `ArchiveEntry` equality now includes the recorded Unix mode, so two
  entries that differ only in recorded permissions no longer compare
  equal.

### Honesty notes

- No test suite was executed in this environment, which has no Xcode
  runner: the new suites (writer golden vectors, extractor, packager,
  pipeline end-to-end, verification, installation capability) are
  written to run under Xcode's test runner and the
  continuous-integration workflow, and no passing result is claimed
  until they do.
- A signed container from the pipeline is exactly what the run produced
  and internally coherent — nothing more. Cryptographic validity to any
  trust evaluator, platform authorization, and installability remain
  unvalidated and unclaimed throughout.

- Final-integration stabilization (ZS-030): a repository-wide review pass over
  the import, inspection, signing, and verification work, with two genuine
  integration defects fixed, regression coverage for both, release
  documentation, installation and compatibility documentation, a security
  review record, and a continuous-integration workflow definition. No release
  was produced: packaging, the complete application pipeline, and on-device
  installation remain unimplemented, and the test suites were not executed
  in the review environment, so no versioned release section is created here.
- Continuous-integration workflow (`.github/workflows/ci.yml`): on hosted
  runners with Xcode it builds the application target, runs the unit-test
  target, and runs a repository-hygiene check (no private keys, no secrets,
  no generated artifacts). The workflow definition is new and has not yet
  run to green on hosted infrastructure; see
  `docs/development/continuous-integration.md`.
- Release documentation: `docs/releases/version-strategy.md` records the
  development → alpha → beta → release-candidate → stable progression and
  the exit criteria for each stage; `docs/releases/README.md` indexes it.
- Installation and compatibility documentation:
  `docs/architecture/installation-compatibility.md` separates artifact
  validity, signature validity, provisioning validity, target-device
  compatibility, installation capability, and platform acceptance, and
  records that no supported arbitrary-IPA installation mechanism is
  available to the application on iOS/iPadOS.
- Security review record: `docs/security/release-review.md` records the
  final review of the archive, property-list, provisioning, Mach-O, signing,
  and packaging boundaries, the security regression corpus and where each
  area is covered, the two findings fixed in this increment with their
  severity, and the accepted Medium/Low risks.
- Signing-metadata layer (ZS-029): entitlements, requirements, and CodeResources
  for the code-signing pipeline. Entitlements are a typed claim set over the
  existing property-list value tree — unknown keys stay representable, dates are
  excluded rather than coerced, and decoded, structurally valid,
  provisioning-compatible, embedded, and platform-authorized stay five separate
  states — with one deterministic canonical XML serialization and the
  `0xFADE7171` blob framing; XML and binary payloads are accepted on read.
- Requirements model (`CodeSignatureRequirements`, `RequirementsSet`): carries
  requirement-set framing and expression bytes verbatim with explicit
  dispositions (absent, present-and-parsed, present-but-unsupported, malformed,
  generated, verified), interprets and generates no expression language,
  validates framing (magic, length, offset, overlap, duplicate kind, entry
  bounds) with typed errors, and refuses malformed values at the embedding
  boundary before any cryptographic operation.
- Resource sealing and CodeResources (`ResourceContentStore`,
  `CodeResourcesGenerator`, `CodeResourcesDocument`): a read-only store port
  with in-memory and directory implementations, deterministic ascending-path
  sealing of exact stored bytes as `hash2`, symlink fail-closed-or-exclude
  policy with links never followed, caller-only exclusions recorded as omissions
  that are never serialized, caller-supplied nested-code `cdhash` seals, and a
  typed document over the `files2`/`rules2` subset whose v1 `files`/`rules`
  dictionaries are an explicit unsupported-subset refusal.
- Special-slot integration (`SigningMetadataPreparation`,
  `SigningMetadataSlotDigests`): derives the CodeDirectory special slots 2, 3,
  and 5 from the exact entitlement blob, requirements blob, and CodeResources
  bytes, under the ordering constraint that metadata is prepared and slots are
  finalized before the CodeDirectory is constructed, hashed, and signed.
- Signing-pipeline metadata support: single-image signing accepts per-request
  metadata, embeds the requirements and entitlements blobs in the SuperBlob,
  and verifies the signed artifact against the exact prepared bytes; nested
  signing accepts per-target metadata that is never inherited, reports metadata
  failures as `signingMetadataFailure` at the metadata stage, and leaves the
  staged artifact untouched on failure. Signing without metadata is
  byte-identical to the previous behavior.
- Read-only embedded-metadata inspection
  (`EmbeddedSigningMetadataInspector`): classifies the entitlements,
  requirements, and CodeResources seal state of an existing signature without
  mutating or verifying anything.
- Tests for the metadata layer, including entitlement, requirements,
  CodeResources, and signing-integration suites with independently computed
  byte and digest vectors, tamper detection, and nested per-target metadata
  coverage. Architecture documentation for the increment is recorded in
  `docs/architecture/signing-metadata.md`.
- Nested code signing layer (ZS-028): turns the cryptographic single-image signing
  capability established by ZS-026 into a dependency-aware nested signing operation
  driven by the signing plan from ZS-027. Nested Mach-O binaries (frameworks, dynamic
  libraries, application extensions) are signed in deterministic dependency order
  (deepest nested code -> its dependents -> higher-level nested code) while strictly
  deferring the parent application executable for the later complete application pipeline.
- Plan validation (`NestedSigningPlanValidator`): verifies that every signing item
  has a valid bundle-relative path that does not escape the application bundle, no
  duplicate signing target exists, no item appears twice in the signing order, all
  required dependencies are represented and acyclic, parent/child relationships are
  internally consistent, each target is established thin arm64 Mach-O code, unsupported
  code kinds and universal binaries are rejected, and the main application executable
  is not treated as a nested item.
- An explicit domain and request model (`NestedSigningModel`): `NestedSigningRequest`,
  `NestedSigningPlan`, `NestedSigningItem`, `NestedSigningResult`, `NestedSigningItemResult`,
  `NestedSigningSummary`, and `NestedSigningFailure` with structured reasons and safe
  user messages, with private keys and raw credentials strictly excluded.
- An artifact storage boundary (`NestedSigningArtifactStore`): in-memory implementation
  (`MemoryNestedSigningArtifactStore`) for deterministic testing, and filesystem-backed
  implementation (`FileNestedSigningArtifactStore`) enforcing path confinement, symlink
  escape prevention, bounds checking, and atomic replacement via temporary files.
- Failure atomicity and mutation strategies (`NestedSigningMutationStrategy`):
  `stagedWorkingCopy` stages all modifications in working memory and commits only
  when all nested targets are successfully signed and verified (ensuring no targets
  are modified on failure), and `directMutation` writes sequentially, explicitly
  distinguishing `noTargetsModified`, `someTargetsModified`, `allTargetsModified`,
  and `verificationFailedAfterMutation`.
- Existing signature policy: unsigned binaries are signed via narrow append mutation;
  binaries with existing signatures are rejected by default (`.rejectExistingSignature`);
  explicit replacement is unsupported (`.unsupportedExistingSignature`); malformed
  existing signatures are rejected cleanly without attempting mutation or preserving
  stale signature data.
- Post-sign independent verification: every successfully signed binary is reparsed
  and independently checked structurally (Mach-O slices, `LC_CODE_SIGNATURE` bounds,
  SuperBlob, CodeDirectory fields, recomputed page hashes) and cryptographically
  (CodeDirectory digest, CMS signed attributes, signature verification against the
  certificate's public key) before accepting the artifact.
- Extension point for ZS-029 (`NestedCodeSigningConfiguration`): hooks for flags and
  special slots without fabricating nested entitlements, requirement blobs, or
  `CodeResources`.
- Focused test suite (`NestedCodeSigningTests`) covering signing-plan validation,
  ordering determinism, nested Mach-O signing, signature replacement policy,
  cryptographic verification, failure handling and atomicity, and binary preservation;
  plus host validation script (`Tests/Host/verify_nested_code_signing_vector.py`)
  performing independent topological ordering, cycle detection, byte preservation,
  and OpenSSL CMS verification.


- Generic cryptographic signing and verification foundation (ZS-021): the
  reusable primitives the signing stage builds on — hashing, cryptographic
  signing, signature verification, signing-key capability use, certificate and
  identity metadata references, algorithm compatibility, signing requests,
  signing results, and structured crypto failures. Nothing in this increment
  is Apple code signing: no Mach-O, CodeDirectory, SuperBlob, page hashing,
  CMS construction, nested signing, `CodeResources`, IPA repackaging,
  installation, profile generation, `.p12` import, or signing UI, and a
  successful operation means only that the generic cryptographic operation
  completed — never code-signing validity, trust, or installability.
- A digest value with its algorithm stated (`Digest`) and a digest boundary
  (`MessageDigest`, implemented by `CryptoKitMessageDigest` over CryptoKit's
  SHA-1/256/384/512 primitives): the bytes are the digest, hex is a rendering
  only, wrong-length bytes are not a digest of the algorithm, and the domain
  never performs hashing itself.
- A focused signing request (`SigningRequest`): identity reference, operation
  (`SigningAlgorithm` with its key family, digest algorithm, and
  message-versus-digest semantics explicit), and data stated explicitly as a
  message or a pre-computed digest — no key material, no password, no
  locator, no path, and no knowledge of Mach-O, bundles, profiles, or
  interfaces. An incoherent request (message where a digest is required, a
  digest of an algorithm the operation does not work on) is a structured
  failure, never a substitution.
- A pure signing engine (`CapabilitySigningEngine` behind the
  `CryptographicSigningEngine` port) that signs only through the ZS-016
  `SigningCapability`: it checks the request's coherence, the key family, the
  capability's availability, and the operation's support in that order, asks
  for exactly one signature, and returns a structured `SigningResult` —
  signature bytes, the algorithms used, the identity reference, the key
  family, the certificate fingerprint when the caller supplies it, and the
  signed digest when the request carried one. The private key never crosses
  the boundary, and no algorithm is substituted or downgraded.
- A verification boundary (`CryptographicSignatureVerifier`) whose outcome is
  a value, not an exception: `valid`, `invalid`, `unsupported(reason)`, and
  `failed(reason)` are four distinct facts, and a signature that does not
  verify is a normal outcome. The iOS implementation checks with
  `SecKeyVerifySignature` under the requested operation, reads the public key
  from the presented certificate, keeps hashing inside the platform
  primitive, and reports a cross-family certificate as
  `.unsupported(.incompatibleKey)`; the fallback on other targets reports
  verification as unavailable rather than skipping it.
- A structured crypto failure vocabulary (`CryptoFailure` with its own
  reasons and categories on `ZynSignError`, plus the use-case's sanitization):
  fixed safe user messages, redacted diagnostics, and identity-boundary
  reasons keeping their own vocabulary when they cross a capability.
- A small application-layer use case (`CryptographicSigningUseCase`) that
  validates the request, resolves the capability through the existing
  `IdentityStore` boundary, invokes the engine, and attaches the certificate
  reference best-effort. It is not installed in the application environment:
  the identity store is not composed into the app until its device
  validation completes, and no interface consumes a signature result yet.
- Deterministic suites for the digest (known vectors, empty and binary input,
  determinism, value semantics), the request, the engine (incompatible key
  and algorithm combinations, unsupported operations, capability state,
  failure sanitization, malformed output), the use case (boundary
  interactions, best-effort reference attachment, port substitution), the
  verification outcome model, the error domain (categories, message
  uniqueness, redacted detail), and the security boundary (no key material by
  construction, redacted diagnostics) — plus an iOS-gated suite that checks
  the committed synthetic RSA and ECDSA fixture signatures, a tampered
  signature, changed bytes, the wrong certificate, and incompatible and
  unusable inputs through the platform key primitives. Like the rest of the
  target, they were written but not executed in the environment where they
  were written; no device, simulator, or Keychain result is claimed.

- Provisioning-profile pipeline integration (ZS-020): one application-layer use
  case that takes a provisioning profile and an application, signing-identity, and
  configuration context and returns one staged result, sequencing the existing
  stages instead of re-implementing them — ZS-018 container verification, ZS-017
  payload parsing and structural validation, ZS-018 certificate relationship, and
  ZS-019 policy validation, in that fixed order. No validation rule, policy, or
  failure vocabulary was copied into the integration layer, and each stage stays
  independently testable.
- A staged integrated result: an outcome per stage (`passed`, `failed`,
  `indeterminate`, or `notAttempted`), each stage's own evidence kept reachable,
  aggregated findings carrying the code the stage that produced them uses, and one
  overall status of `valid`, `invalid`, `indeterminate`, or `unsupported` under
  stated rules — `valid` requires every required stage to pass and the policy
  evaluation to be `compatible`, `invalid` requires a definite rejection,
  `unsupported` is reserved for coherent input outside supported capability, and
  everything else stays `indeterminate`. There is no `isValid`, `isTrusted`,
  `isSigned`, or `isInstallable` flag, and no result claims that iOS would accept or
  install anything: trust stays `notPerformed` and authorization stays
  `notEvaluated`.
- Untrusted input cannot be laundered by the pipeline: the payload is parsed only
  from a container whose signature verified, a container that decoded but did not
  verify is reported as evidence with its parsing stage `notAttempted`, a missing
  verification mechanism stays `indeterminate` rather than becoming a defect in the
  user's profile, an unsupported algorithm or armored container is reported as
  `unsupported` rather than `invalid`, and a signer/profile certificate mismatch
  stays the open question ZS-019 records instead of being promoted into a verdict.
- Explicit handling of profiles that are not there: a request states whether bytes
  were supplied, whether no `embedded.mobileprovision` entry was recorded, or why an
  entry could not be read; absent and unreadable inputs stop at acquisition with a
  distinct code and an `indeterminate` status rather than becoming a generic
  "invalid application" error, because a distributed application legitimately carries
  no embedded profile.
- A read-only embedded-profile intake over the existing artifact boundaries: it
  asks the library's own archive-reader provider for one record's container, reads
  the entry table, resolves the primary application bundle through
  `ApplicationBundleDiscovery` (reporting ambiguity rather than choosing), and reads
  at most the one profile entry within the tighter of the archive's inspection-read
  bound and the profile input cap — no extraction, no second reader, no second
  store, no writes, no conclusion. The bundle explorer still reads no entry content,
  and nothing here persists a status or caches a result.
- Host-side suites for the integrated pipeline and the intake, over the committed
  synthetic CMS containers with the real stages and only the signature mechanism and
  identity store doubled: a fully successful run, the security order, cryptographic
  failure, tampering refused before any signature check, mechanism unavailability,
  unsupported input, certificate correspondence and unrelated-identity cases,
  identity-store failure, policy propagation for bundle identifier, entitlements,
  expiry, and several simultaneous failures, the four input states, determinism,
  one unit of work per question, non-mutation, redaction, and single-bounded-read and
  refusal behaviours of the intake. They assert that no signing capability is
  requested and that no identifier, value, or byte reaches a diagnostic. Like the
  rest of the target, they were written but not executed in the environment where
  they were written.

- Provisioning-profile policy validation (ZS-019): a read-only domain stage that
  evaluates whether an authenticated profile may be used with an application, a
  bundle identifier, a signing identity, and a requested signing configuration.
  It reports nine three-state categories — authenticity, validity, profile class,
  bundle identifier, team identifier, certificate, entitlements, platform, and
  device — aggregated into `compatible`, `incompatible`, or `indeterminate`, with
  every meaningful finding kept and no `isValid` flag. A profile that is not
  authenticated gates the other categories to indeterminate; a rejected container
  is the one case that makes the result incompatible.
- One identifier rule shared by the bundle-identifier check and the
  `application-identifier` claim check: exact scope, trailing-wildcard scope as a
  prefix test at a component boundary, explicit mismatch, and indeterminate when
  no explicit application-identifier prefix makes a split safe. Nothing is
  normalised into a match and no wildcard behaviour is invented.
- Typed, deterministic entitlement comparison per key against the profile's
  allowlist: property-list types preserved, no integer/real coercion, no
  array-order or set assumption, unsupported and incomparable values reported as
  such instead of approved, dedicated rules for `application-identifier`,
  `com.apple.developer.team-identifier`, and `get-task-allow` — including that
  absence is not `false` — and no stripping, rewriting, or synthesizing of a
  claim.
- Certificate evidence layered on ZS-018 rather than re-derived: container-signer
  agreement, identity-certificate agreement, and key availability, association,
  and readiness reported separately, so "identity unavailable", "certificate
  mismatch", and "profile mismatch" stay three distinct outcomes and an
  unavailable key never becomes a malformed profile.
- Validity and platform rules over existing models with an injected clock, and a
  device rule that compares only when a trustworthy identifier was supplied,
  reports an inconsistent all-devices declaration instead of resolving it, and
  never fabricates or assumes a device identifier.
- `ValidateProvisioningConfigurationUseCase` and a presentation-safe summary: the
  use case resolves identity metadata read-only, never requests a signing
  capability, never throws for a policy outcome, persists nothing, and adds no
  policy interface or action. Trust stays `notPerformed` and authorization stays
  `notEvaluated`; a `compatible` result states only that the configuration
  satisfies the policy rules implemented by ZynSign.
- Host-side suites for the policy stage over synthetic profile, identity,
  application, and configuration values: the identifier rule, the typed
  entitlement comparator, the category rules with authenticity gating, validity
  boundaries, aggregation, non-mutation, and redaction, and the use case
  including identity-resolution states and the summary. They assert that no
  signing capability is requested and that trust and authorization stay
  unevaluated. Like the rest of the target, they have not been executed in the
  environment where they were written.
- Provisioning-profile CMS verification: a bounded RFC 5652 SignedData reader,
  signer-certificate extraction by serial number, signed-attribute re-encoding
  with message-digest binding checked before any signature check, and signature
  verification through documented iOS key primitives behind a
  `CMSSignatureVerifier` port. Apple's CMS decoder family is documented for macOS
  and Mac Catalyst only, so no CMS API is called and no third-party ASN.1 or
  crypto dependency is added.
- Structured CMS verification evidence that keeps five states apart — parseable,
  structurally valid, cryptographically authentic, certificate trusted, platform
  authorized — recording trust as `notPerformed` and authorization as
  `notEvaluated`, with no single validity flag. A separate `CMSFailure`
  vocabulary keeps container outcomes distinct from profile-metadata and
  identity outcomes, and a container that decoded but did not verify is returned
  as evidence rather than thrown.
- Certificate relationship analysis by SHA-256 fingerprint of exact DER bytes:
  the signer certificate against the profile's own certificate references and
  against locally listed signing identities, with ambiguity, incomparability,
  unparsable bag entries, and duplicates reported instead of resolved. Matching
  never uses a subject name, a label, or bag order.
- Profile verification use case that parses a payload only after its signature
  verified, consults an identity store read-only and never requests a signing
  capability, and records an unreadable store as a failed lookup rather than a
  verification failure. No certificate-chain trust evaluation, signing policy,
  compatibility decision, CMS construction, profile persistence, or
  profile-management interface.
- Synthetic CMS fixtures: SignedData containers over test-only OpenSSL-generated
  keys and certificates with placeholder profile payloads, cross-checked with
  `openssl cms -verify`, plus deterministic tampered, truncated, trailing,
  armored, reordered, detached, unparsable-bag, unsupported-algorithm,
  no-signer, and multi-signer variants. Platform-independent suites cover the
  structure reader, the verification boundary, the CMS vocabulary, the
  relationship rules, and the use case; an iOS-gated suite covers signature
  mathematics over the same fixtures.
- Secure identity capability foundation: explicit message/digest algorithms,
  separate key-association and readiness states, structured safe identity errors,
  stable registration records, and a signature-only resolver boundary.
- Experimental Keychain registry and protected-key resolver, with public-key
  association checks and per-operation resolution. Not composed into the app;
  physical-device validation remains required before production use. No PKCS#12
  import, private-key export, signing workflow, or identity-management UI.
- Deterministic identity-store/security-boundary tests and opt-in disposable-key
  iOS integration tests, with protection choices and validation gates documented.

- Initial repository foundation.
- iOS/iPadOS application foundation: an Xcode project with an application
  target and a unit-test target, a SwiftUI application shell whose future
  workflow areas are explicitly marked as not implemented, a composition root
  with a centralized dependency seam, and a minimal pure domain layer
  (application identity, workflow stages, validation classifications, and a
  structured error model). No signing, inspection, or installation
  functionality exists.
- IPA archive layer: bounded ZIP container reading behind an `ArchiveReader`
  boundary, with the concrete reader selected by the composition root and no
  third-party archive dependency.
- Application-bundle discovery over an archive entry table. Discovery is
  deterministic, independent of container entry order, and reports ambiguity
  rather than choosing between candidate bundles.
- Structural validation of an imported package's layout: payload directory,
  application bundle, bundle information file, unsafe and conflicting entry
  paths, unsupported entry forms, nesting depth, and resource-policy limits.
- Archive security protections: entry names are validated before anything is
  read; absolute, escaping, malformed, over-long, and undecodable names are
  refused; every read is bounds-checked against the container's own size; and
  entry count, entry size, total expanded size, nesting depth, expansion ratio,
  and single-read size are bounded by an explicit policy.
- Package inspection use case, which reads a container's entry table and records
  a typed structural outcome without extracting any entry and without creating
  temporary files.
- Tests covering entry validation, the resource policy, bundle discovery,
  structural validation, the inspection use case, and the ZIP reader against
  programmatically generated containers.
- Application metadata layer: a strongly typed domain model for the metadata a
  bundle declares in its bundle information file (bundle identifier, display
  name with a deterministic fallback, version and build strings, executable
  name, minimum OS version, device families, and icon name), a pure domain
  reader that extracts and validates it with structured, deterministic
  failures, and an application-layer use case that reads the one information
  file entry for an established bundle and records the outcome on the
  artifact.
- Metadata extraction: bundle identifier is required; name, version, build,
  executable, and supplementary values are optional and preserved exactly as
  declared. Malformed property lists, non-dictionary roots, wrong value types,
  missing required fields, and unsupported property list formats fail with
  typed findings rather than by guessing. Unknown keys are ignored, and the
  declared executable is resolved only when present as a regular file.
- Tests covering the metadata model, the metadata reader (valid, missing,
  mistyped, malformed, hostile, and unsupported inputs), the metadata
  inspection use case, and the extended artifact lifecycle.
- Package import workflow: user-driven selection of an `.ipa` file through
  the system document picker, restricted to the accepted package type, with
  typed outcomes for cancellation, unreachable or inaccessible files,
  staging failures, and unexpected infrastructure failures. The file-type
  policy is a cheap gate and is never trusted as evidence about content.
- Application-owned temporary staging: each selected document is copied
  once, in bounded chunks and never held whole in memory, into a unique
  location named only by the artifact's identifier; security-scoped access
  is acquired for the copy and released on every outcome. Failed, cancelled,
  and rejected imports discard the staged copy; leftovers from a previous
  process are cleared before the first import of a new process.
- Import use case that composes the existing structural and metadata
  inspection use cases over the staged archive, with an explicit staged-
  archive lifetime: rejected imports' archives are discarded before the
  result is returned, and an accepted import's archive is handed to the
  library (below), which adopts it or has it discarded.
- SwiftUI Import area with an explicit phase machine (idle, importing,
  succeeded, failed, cancelled), a success summary of the declared
  application metadata, user-facing rejection explanations composed from
  typed findings, and safe cancellation.
- Tests for the import use case (success, rejection, unreadable containers,
  file-type policy, staging failure, cancellation during and after staging),
  the platform intake against temporary directories (identifier-addressed
  staging, uniqueness and containment, readability through the established
  archive boundary, refusal of missing files and directories, discard
  behaviour, leftover clearing, cancellation cleanup), the import error
  constructors, and the presentation model's phases and staged-archive
  ownership.
- Application persistence and library records: a domain `ApplicationRecord`
  value (stable record identifier, declared identity, executable name,
  source file name, artifact reference with byte count and SHA-256 content
  fingerprint, inspection summary, import and last-updated timestamps) that
  can only be created from a package that passed inspection; an
  `ApplicationRecordStore` port (insert, update, fetch by identifier, list,
  delete) implemented as an explicitly versioned JSON catalog (`schemaVersion`
  1) in the application container's Application Support directory, replaced
  atomically on every change and failing closed on catalogs it cannot read or
  that are newer than the build; a `LibraryArtifactStore` port implemented
  over application-owned artifact storage that adopts an accepted import's
  staged archive by moving it under its artifact identifier.
- Library use case that admits accepted imports artifact-first and record-
  second, removes the adopted artifact again if the record cannot be written,
  lists records with their artifact's current availability (available,
  missing, or inconsistent — never repaired or recreated), removes an entry
  record-first and artifact-second, and detects and removes orphaned
  artifacts only on request.
- Deterministic duplicate policy: identical bytes held by an existing record
  are recognised and not recorded again, whatever the package declares;
  different bytes are always a new record, with the relation to existing
  records of the same bundle identifier (other versions, or the same
  declared version with different content) reported rather than used to
  replace anything.
- The import flow now hands accepted packages to the library, so nothing
  staged survives an import: the archive is adopted into library storage or
  discarded. The Import area states the library's decision and no longer
  describes imports as temporary.
- Tests for the record model and value types, the duplicate policy, the
  catalog-file record store (CRUD, persistence across store instances,
  ordering, catalog format, damaged and newer-schema catalogs, write
  failure), the artifact store (describing, adopting, refusing overwrites,
  observing, removing, enumerating, readability after adoption), the library
  use case over in-memory stores (admission outcomes, rollback, orphans,
  availability, removal), the import flow's library integration, the
  library error constructors, and an end-to-end persistence lifecycle over
  the real platform stores in a temporary directory.
- Applications Library screen: the Applications area of the shell lists the
  persisted records with their declared metadata and current artifact
  availability, opens a detail screen per record, imports another package
  through the existing document-import workflow with the list refreshed on
  success, and deletes a record together with the package file behind it
  through the library use case's removal operation, behind an explicit
  confirmation. Explicit loading, empty, and failure states keep an empty
  library from being presented while records are still being read and keep
  persistence failures surfaced with a retry action. The import
  presentation model gained a settlement hook so a screen embedding the
  import can react to its outcome without a second import flow.
- Tests for the library screen's presentation model over in-memory stores
  and synthetic import ports: loading into loaded, empty, and failed
  phases, retry after failure, import settlement refreshing the library,
  picker cancellation as an ordinary outcome, rejected and failed imports
  surfaced without library changes, removal with its in-flight state,
  failed deletions leaving records and announcements intact, and the row
  and detail display mappings including missing and inconsistent artifacts
  and undeclared metadata.
- Bundle explorer: a read-only browser of the files and folders inside a
  library application's bundle, reached from the application detail screen
  through an "Explore Bundle" entry that is offered only while the record's
  package is available. The explorer lists each entry's name, its location
  relative to the bundle root, its kind (folder, file, symbolic link, or
  unsupported entry), the byte count the package declares for a regular
  file, and a descriptive label on conventional locations — the bundle
  information file, the declared executable, an embedded provisioning
  profile, the code signature directory and its resource record, and the
  frameworks, plug-ins, and extensions directories — with a "Notable
  Entries" shortcut at the bundle root. Folders are entered in place;
  files open a metadata screen. Explicit loading, empty, and failure states
  with a retry action; the package is read once per visit and never again
  on view recomputation or while descending into folders.
- Bundle contents domain model: `BundlePath`, a bundle-relative location
  constructed under the same safety rules as archive paths (no absolute
  locations, no `..` or `.` components, no empty components, no NUL bytes
  or backslashes, bounded length), so nothing above the bundle root is
  representable; `BundleEntry` and `BundleEntryRole`, descriptions with no
  handle to any file; and `BundleContents`, the bundle's structure derived
  from a package's entry table — only entries strictly inside the bundle,
  directories the container did not record implied from the entries beneath
  them, deterministic ordering (folders first, then by name as Unicode
  scalars) independent of container order, first-recorded entry kept for a
  duplicated location, and entries with unsafe names counted rather than
  listed.
- Bundle contents inspection use case, composed from the existing library
  use case and the existing archive boundary over library storage — no
  second archive reader and no second artifact store. It reads a package's
  entry table only: no entry content, no extraction, no hashing, no parsing
  of any file inside the bundle. Typed errors for a record that no longer
  exists, a package the library no longer holds, a package that has changed
  since import, an unreadable container, and a package with no single
  application bundle; foreign errors are normalised so no platform text
  reaches the screen.
- Tests for bundle paths (construction, refusals, containment, derivation
  from archive locations), bundle contents (empty, single-file, nested, and
  multi-level bundles; implied directories; ordering and its independence
  from table order; the bundle boundary; unsafe names; duplicates; links and
  unsupported kinds; declared sizes including very large ones without any
  content read; unusual names; label recognition and its depth, kind, and
  exact-name rules), the label vocabulary, the inspection error
  constructors, the inspection use case (success, no content read for large
  files, executable labelling from the record, empty bundles, missing
  record, missing and inconsistent artifacts, typed and foreign open
  failures, unreadable tables, packages without or with several bundles,
  cancellation, and a synthetic container read through the platform
  boundary), and the explorer presentation model and display mappings
  (loading, loaded, empty, and failed phases; retry; idempotent and
  overlapping loads; foreign-error rendering; the detail screen's entry
  point; row, listing, and entry-detail content).
- Certificate inspection: untrusted certificate bytes are parsed by a bounded
  DER reader into the existing certificate metadata model. Subject and issuer
  attributes are kept in certificate order, including unrecognised attributes.
  The serial number is the exact INTEGER content, including leading zero
  octets, and is not a machine integer. Validity is evaluated against an
  injected clock and is not a trust decision. The SHA-256 fingerprint is of
  the accepted DER bytes. An unrecognised key or signature algorithm is
  recorded rather than rejected. Inspection does not persist certificates,
  does not handle private keys, and is not wired into the interface.
- Tests for certificate parsing, distinguished-name variants, serial-number
  variants, validity boundaries, algorithm combinations, fingerprint
  determinism, and structured input failures. The tests use synthetic public
  certificates and do not include private keys.

### Changed

- Staged imports are no longer retained by the presentation model. An
  accepted import's archive belongs to the library once recorded; the model
  owns no storage.
- The shell's Applications tab now shows the library instead of a
  placeholder, and the Import area, Settings, and the shell's section
  descriptions state that the Applications area lists the library.
- The application detail screen receives the bundle inspection use case
  from the library screen, which receives it from the shell; the
  application environment carries it alongside the library and import use
  cases. Settings and the shell's Applications description now state that
  the Applications area shows what each application bundle contains.

### Fixed

- Nested signing verification now honors per-target signing metadata
  (ZS-030): the independent post-sign check in `SignNestedCodeUseCase`
  required every signed binary to carry exactly a CodeDirectory and a CMS
  blob, so any nested target that embedded requirements or entitlements
  blobs failed verification even though the single-image pipeline had
  signed and verified it correctly. The check now compares the embedded
  slot layout against the expected per-target layout, requires the
  embedded requirements and entitlements bytes to equal the prepared
  metadata bytes, and binds both blobs to their CodeDirectory special-slot
  digests. The existing `testNestedTargetsCarryTheirOwnMetadataOnly`
  suite covers the corrected behavior.
- Filesystem nested-signing store confinement now falls on a path
  separator (ZS-030): `FileNestedSigningArtifactStore` accepted any
  canonical target with the bundle path as a string prefix, so a symlink
  resolving to a sibling such as `App.app-evil/x` passed the check for a
  bundle rooted at `App.app`. The target must now equal the bundle root
  or lie strictly beneath it. New `NestedSigningArtifactStoreTests`
  cover the sibling-prefix escape for reads and writes, a plain
  outside-the-bundle escape, and a legitimate nested read.

### Notes

- The ZS-030 review environment had no Swift toolchain and no Xcode: the
  two fixes above were checked by balanced-delimiter and type-consistency
  review against the mirrored single-image verification code, not by an
  executed test run. The host vector scripts
  (`Tests/Host/verify_macho_signing_vector.py` and
  `Tests/Host/verify_nested_code_signing_vector.py`) were executed and
  passed. Running the full XCTest suite remains a prerequisite to any
  release claim.
- Embedded signing metadata states facts, not permissions. An entitlement set

- Embedded signing metadata states facts, not permissions. An entitlement set
  being decoded, structurally valid, provisioning-compatible, or embedded says
  nothing about platform authorization: no local operation evaluates it, and
  the signing result carries that state explicitly as not performed. A
  CodeResources digest being present in special slot 3 establishes only that a
  digest is declared, never that it is correct for any resource tree.
- Requirements are preserved, never interpreted. A present-and-parsed
  requirements value means the framing decoded and the bytes round-trip; no
  requirement is evaluated, generated, or silently replaced.
- No Swift toolchain was available in the environment where ZS-029 was written;
  the new suites were authored against independently computed vectors but not
  executed locally, and running them is a prerequisite to any release claim.
- An integrated provisioning-profile result states which stage reached which
  outcome. A `valid` status means only that every stage ZynSign implements passed
  and that the configuration satisfies the policy rules ZynSign implements: it is
  not certificate trust, not platform authorization, not a signature, not proof
  that a private key was used, and not a claim that iOS would accept, install, or
  run the application.
- Reading an `embedded.mobileprovision` entry makes a profile discovered, nothing
  more. Discovery, parsing, authentication, and compatibility with an application
  and a signing configuration are four separate states, and none of them is
  inferred from another.
- Structural validity is not cryptographic validity. A `valid` structural outcome
  says nothing about signatures, entitlements, trust, or installability.
- Extracted metadata is a record of what a bundle's information file declares.
  It makes no claim that the application is signed, genuine, or installable.
- A library record is not a trust statement. Its fingerprint identifies bytes
  only; declared metadata remains untrusted; no record is evidence that a
  package is signed, genuine, or installable. No key material, credentials,
  certificate bodies, or profile data are persisted.
- The bundle explorer is a listing of what a package records inside its
  application bundle. It reads the container's entry table and nothing else:
  no file is opened, previewed, extracted, hashed, or parsed, and symbolic
  links are shown as links and never followed. Its labels on conventional
  locations describe what is usually found there; the presence of a code
  signature directory, a resource record, or an embedded provisioning
  profile is a filesystem observation and is not evidence that the
  application is signed, that any signature is valid, or that the
  application is trusted or installable.
- No signing, signature verification, Mach-O inspection,
  packaging, extraction, or installation functionality exists. The
  Applications area lists, imports, browses, and deletes library records; it
  makes no claim about signatures, trust, or installability.
