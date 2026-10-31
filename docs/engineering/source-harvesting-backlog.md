# ZynSign source-harvesting implementation backlog

Status: **Draft for prioritization; no source code imported or adapted.** This backlog turns the source-harvesting matrix into bounded work packages for ZynSign's existing architecture. It is a plan, not a parity or platform-support claim, and it is not a schedule.

**Decision rule:** harvest behaviors and design patterns first. Prefer a clean implementation at existing ZynSign boundaries. Do not merge whole projects or copy/adapt code until the per-component source, revision, license, dependency, notice, attribution, and security review is recorded and approved.

## Release gates and dependency order

```text
G0 Phase 1 DER review and Apple-platform validation
  └─ G1 Core signing reliability
       └─ G2 Authenticated device transport and installation verification
            └─ G3 Repository discovery, downloads, and Library update tracking
                 └─ G4 Tweak workflow behind explicit compatibility/security gates
                      └─ G5 Guest-runtime feasibility exit review
```

G3 can prepare a requirements/design dossier while G1/G2 proceed, but user-facing work must respect the implementation order above. G5 is a research spike only until its exit conditions pass. A later work item may proceed only when its upstream acceptance gate is met or the reviewer explicitly records a safe, independent scope.

### G0 — Finish Phase 1 review and validation (blocking)

**Goal.** Close the DER correctness review without enabling DER in the application signing path.

**Work.** Review the source diff; run a macOS/Xcode build and targeted and full XCTest suites; run the Apple `Security.framework` RSA tests on an iOS Simulator; resolve failures; keep all application-pipeline and coordinator DER refusal gates. Record test destination and toolchain version.

**Acceptance.** The actual source diff and test results are reviewed; Swift parser/typecheck and Xcode tests pass on Apple tooling; the Simulator RSA tests have actual passing results; architecture, security, dependency, and docs checks are recorded. DER remains disabled in app signing unless a separate policy decision is approved. Host parsing or test doubles do not substitute for the Apple-platform checks.

**Dependency.** Required before representing this phase as accepted or starting application-pipeline DER work. It does not authorize Phase 2.

### G1 — Core signing reliability (highest implementation priority)

These are sequential acceptance slices of one reliability gate. Existing code and tests are the baseline; first reproduce defects on real supported inputs rather than re-implementing existing subsystems.

#### G1.1 Archive intake, validation, and extraction

- Validate archive structure and supported IPA layout before mutation; enforce entry, expanded-size, path, duplicate, type, and nesting limits.
- Refuse traversal, path collisions, malformed central/local header disagreement, unsupported compression or archive features, and unsafe link behavior before writing.
- Extract only into an isolated working copy; preserve the source artifact on refusal, cancellation, and rollback.
- Keep archive reader/writer behavior deterministic and test resource exhaustion and partial I/O.

**Acceptance tests:** extend `ArchiveLimitsTests`, `ArchivePathTests`, `ZipArchiveReaderTests`, `ZipArchiveWriterTests`, `DirectoryArchiveExtractorTests`, `IPAArchiveInspectionTests`, and the host ZIP vectors. Assert hostile inputs fail with typed errors before unsafe writes; source bytes remain unchanged; an accepted package reopens and matches the planned entry set.

#### G1.2 Identity, profile, and entitlement authorization

- Validate the profile signature and bounded payload, expiration, application identifier, team, device restrictions, and signing-certificate relationship.
- Compare requested entitlements against established profile authorization without silently adding, dropping, or weakening claims.
- Distinguish satisfied, violated, and indeterminate facts; never convert missing evidence into success.
- Keep key availability, identity selection, certificate suitability, and user confirmation explicit. Do not infer Apple trust or account entitlements from names or UI state.

**Acceptance tests:** extend `ProvisioningProfileVerificationUseCaseTests`, `ProvisioningPolicyValidationTests`, `ProvisioningPolicyEntitlementComparisonTests`, `ValidateProvisioningConfigurationUseCaseTests`, `SigningIdentityTests`, and signing integration tests. Cover expired/mismatched profiles, wrong team/certificate, unavailable identity, unsupported claim types, hostile claim trees, and cancellation. Assert no signing capability is called on refusal.

#### G1.3 Nested signing and per-target metadata

- Preserve dependency ordering: sign nested targets before their containing code; reject cycles, duplicates, unsupported code kinds, existing signatures that cannot safely be replaced, and unsupported binaries.
- Bind each target only to its own established metadata. Bind parent resource seals to the finalized child state. Do not inherit parent entitlements or metadata implicitly.
- Verify each target after signing and make failure atomic for the selected mutation strategy.

**Acceptance tests:** extend `NestedCodeSigningOrderTests`, `NestedCodeSigningTests`, `SigningMetadataIntegrationTests`, and `MachOSigningIntegrationTests`. Assert deterministic topological order, per-target metadata isolation, child-change invalidation of parent seals, no partial mutation in staged mode, and typed refusal for unsupported inputs.

#### G1.4 Verification and packaging

- Reopen the generated package through the normal import/archive boundary.
- Independently recompute CodeDirectory page hashes, special-slot digests, resource seals, nested signatures, profile bytes, and entitlement bytes against captured signing expectations.
- Deliver only after verification. Preserve the distinction between internal structural/cryptographic checks and Apple platform acceptance.

**Acceptance tests:** extend `VerifySignedApplicationTests`, `SignApplicationPipelineTests`, `ApplicationLibraryTests`, and ZIP golden-vector tests. Tamper each relevant class of bytes and assert rejection; ensure a package failing verification is not delivered or admitted as accepted. A passing internal verifier must not display “Apple accepted,” “installed,” or “launches.”

**G1 exit criterion.** Supported real IPA/profile/identity fixtures pass the complete signing and verification workflow on Apple tooling; unsupported and hostile cases fail closed; source preservation and rollback are verified. Device acceptance remains a separate gate.

### G2 — Authenticated device transport and installation verification

**Goal.** Replace blocked transport assumptions with a measured, authenticated, encrypted session and honest install outcomes.

**Work.** Start with protocol and threat-model review of pairing, session identity, framing, key use, confidentiality, replay protection, timeouts, cancellation, and teardown. Implement only after each platform mechanism is verified; transport must be authenticated and encrypted before production use. Verify the target device and installation service response independently. Report unsupported OS, entitlement, pairing, or install conditions as explicit limitations, not generic success.

**Acceptance tests:** extend `DeviceTransportFramingTests`, pairing/service tests, `InstallationPreparationQueueTests`, `InstallationDeliveryTests`, `InstallationReadinessTests`, and `InstallationWorkspaceTests`. Cover tampered frames, replay/wrong peer, oversized/truncated messages, authentication failure, disconnect/cancel cleanup, stale device identity, install rejection, and a device-confirmed installed state. A sent request or accepted socket alone must not pass the installation assertion.

**Exit criterion.** Controlled tests on each claimed device/OS family confirm peer authentication, encrypted transport, correct protocol framing, cancellation cleanup, and a device-observed result. Until then, the production gate remains closed.

### G3 — Repository discovery, downloads, and app-library update tracking

**Goal.** Improve the existing Store Browser, repository directory, Download Center, and Library; do not build duplicate systems or treat source metadata as trust evidence.

**Work.**

1. Perform a gap review against current `RepositoryDirectory`/Store Browser behavior. Harvest Feather's repository browsing, library, and source-presentation patterns only where a documented gap exists.
2. Strengthen catalog validation, source identity, last-success/stale status, removal and disable semantics, and honest offline behavior. Treat FlareStore as an optional external API integration; isolate its adapter and make its availability, terms, and data handling explicit.
3. Reuse and harden the existing bounded download queue and explicit import boundary. Preserve URL/redirect policy, size/hash checks, quarantine of invalid files, cancellation, honest resume status, and duplicate confirmation. A download is not a signing or installation event.
4. Keep update tracking source-aware and user-selected. Never silently switch the preferred source, trust a version string as authenticity, or delete an imported Library artifact to replace a download.

**Acceptance tests:** extend `StoreRepositoryTests`, `StoreDownloadQueueTests`, `StoreUpdatePolicyTests`, `DownloadCenterTests`, `DownloadsResilienceTests`, `DownloadCatalogTests`, `ApplicationLibraryTests`, and `LibraryIndexTests`. Cover malformed/oversized catalogs, stale cache and failed refresh retention, source removal, explicit-source preference, redirect-to-insecure URLs, size/hash mismatch, interrupted jobs, duplicate-version confirmation, no import before validation, and no update fallback to another source.

**Exit criterion.** Repository and transfer state remain deterministic across refresh, cancellation, restart, and source removal; every downloaded artifact crosses the existing validation/import boundary; source health and metadata are never presented as code-signing trust.

### G4 — Tweak workflow behind explicit compatibility and security gates

**Goal.** Improve existing tweak discovery/staging without making arbitrary binary modification the default or implying compatibility.

**Work.** Compare RyukSign's tweak and update UX, but do not duplicate Feather-derived work already covered by G3. Keep injection explicitly opt-in, per-target, and limited to supported architectures and code kinds. Require a compatibility record for each supported OS/app combination; unsupported or unknown combinations must be refused or clearly marked experimental. Re-verify the final signed artifact and preserve rollback. Any file-transfer workflow must use independently reviewed authenticated, encrypted transport; do not reuse an insecure transport pattern.

**Acceptance tests:** extend `TweakLibraryDomainTests`, `TweakLibraryServiceTests`, `TweakStagingTests`, nested signing tests, and final verification tests. Cover unknown architecture/target, malformed or mismatched payload fingerprints, duplicate install names, path/collision attacks, opt-in state, failure rollback, post-injection signature verification, and compatibility refusal. Add device evidence for each claimed compatibility combination.

**Exit criterion.** Security review approves the mutation model; compatibility is evidence-backed; unsupported targets refuse; resulting packages are independently verified. UX similarity alone is not compatibility evidence.

### G5 — Guest-runtime feasibility study (research only; lowest priority)

**Goal.** Decide whether safe, policy-compliant guest hosting is feasible before any feature implementation or source reuse.

**Work.** Produce a threat model and feasibility report covering process isolation, executable loading, code-signing and entitlement constraints, inter-app data access, extensions, permissions, lifecycle, termination, crash containment, background work, and supported OS versions. Inspect LiveContainer behavior as research only. Record AGPL-3.0 and dependency obligations before considering any code use. Prototype only in a controlled, disposable environment; do not load untrusted guests in the production host process.

**Acceptance / exit criteria.** The report demonstrates a safe isolation boundary, supported platform path, cleanup and lifecycle guarantees, and reviewable device evidence—or records a clear no-go. A prototype, staged guest bundle, successful `dlopen`, or host-process probe is not functional guest execution and does not demonstrate sandbox isolation or LiveContainer parity.

## Source review register

Project names and license summaries below are the user's supplied matrix, not independent verification for a specific revision. Before analysis or reuse, record the exact canonical repository URL, commit/release revision, license file/SPDX identifier, notices, and transitive dependencies. Verify license and dependency state again at that revision.

| Source | Research target | Priority | Reuse gate / caution |
|---|---|---:|---|
| Feather | Signing UX, repository browsing, app library, signing options, certificate/profile presentation | High | Matrix identifies GPL-3.0. Inspect dependencies and notices; behavior study is preferred over code reuse. |
| FeatherPlus | None until identity is resolved | Hold | Exact repository URL required; do not analyze or copy from an unverified name. |
| KSign | Signing workflow and user-facing flow comparison | Medium | Matrix identifies GPL-3.0 and Feather basis; avoid duplicate research and any code reuse without full review. |
| RyukSign | Download queue, update checks, tweak UX, file-transfer flow | Medium | Matrix identifies GPL-3.0 Feather derivative; redesign transport to authenticated encryption before production use. |
| FlareStore | Optional distribution/API integration; compare source discovery | Medium | Treat only as an external service adapter; review API terms, data exposure, availability, and source trust. It is not signing/install evidence. |
| SideStore | Refresh workflow and device-communication feasibility research | High research / later implementation | Verify exact revision, license, dependencies, and protocol behavior; independently test device transport. |
| LiveContainer | Guest app slots, lifecycle, compatibility-reporting feasibility | Low / later | Matrix identifies AGPL-3.0. Guest isolation/extension/permission limitations apply; no parity claim from a prototype. |
| Odysseus | None until identity is resolved | Hold | Exact repository URL required; verify intended project and license first. |

## Required record for every selected feature

Before implementation begins, attach a feature record containing:

1. Canonical source URL and exact commit/tag/release inspected.
2. Observable behavior to reproduce, with boundaries and unsupported cases.
3. Code copied/adapted (paths and revision), or an explicit **clean implementation; no source code reused** statement.
4. License determination, dependency tree, attribution/notices, source-offer obligations if applicable, and reviewer approval.
5. Security threat model and review owner; network, archive, signing, identity, and guest-code risks called out separately.
6. Existing ZynSign architecture seam and files/tests to extend; rationale for not adding a parallel subsystem.
7. Unit, integration, host, Apple-platform, simulator/device tests as applicable, with exact acceptance conditions and honest evidence status.
8. Release/UI claims allowed by the test evidence; no trust, install, launch, or compatibility claim based only on source comparison.

**No-go rule:** if source identity, license, dependency obligations, security boundary, or acceptance evidence is unresolved, keep the item at research/hold. Do not bulk-import code or treat a source project's behavior as proof that ZynSign's implementation works.
