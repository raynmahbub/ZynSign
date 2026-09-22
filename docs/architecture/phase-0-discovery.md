# Phase 0 — Technical Discovery

## Purpose

Establish the technical facts, constraints, and unresolved questions needed before ZynSign's application architecture is designed. This document describes future capabilities only; none of the parsing, signing, packaging, or installation behavior described here is implemented.

## Relationship to the Architecture Document

ZynSign's product runtime is iOS and iPadOS, as set out in [architecture.md](architecture.md). This document is the findings record that feeds that architecture; where the two disagree on a platform question, the architecture document is authoritative.

Two consequences apply throughout the findings below:

- Capabilities described here are capabilities of the product's own runtime. The availability of an equivalent capability on a desktop operating system does not establish that it is available to a sandboxed iOS/iPadOS application, and nothing in this document should be read as claiming otherwise.
- macOS and Xcode appear in this document only as developer-side tooling: for generating controlled fixtures, for independently inspecting and validating artifacts, and for compatibility experiments. They are not part of the product runtime, and no workflow may depend on them at run time.

## Scope

The scope is inspection and eventual preparation of iOS application packages, together with the signing material and platform services those workflows may require. Findings are classified as **Verified**, **Observed**, **Inferred**, or **Unknown**, with **Unresolved** and **Requires feasibility research** used where a finding depends on iOS/iPadOS platform behavior that has not been established. A classification applies to the statement it follows, not to an entire section.

## IPA Structure

- **Verified:** An IPA is a ZIP archive. The conventional top-level application path is `Payload/<ApplicationName>.app/`.
- **Verified:** The `.app` directory is a bundle. `Info.plist` describes the bundle, and the executable named by `CFBundleExecutable` is expected at the bundle root.
- **Verified:** An application may contain resources, `Frameworks/`, and other bundle directories. Frameworks may contain dynamic libraries and nested framework bundles.
- **Verified:** App extensions are normally nested bundles under locations such as `PlugIns/`, with an extension executable and its own `Info.plist`. Other plug-ins and signed bundles may also occur in application-defined locations.
- **Verified:** A signed bundle commonly contains `_CodeSignature/CodeResources`. The executable contains a Mach-O code signature referenced by its load commands; these are related but distinct signature data.
- **Observed:** Real archives can include ZIP metadata, extra top-level files, directory entries, symlinks, unusual permissions, or paths that do not follow the conventional layout. ZynSign must not assume that a ZIP listing alone establishes a valid application package.
- **Inferred:** `embedded.mobileprovision`, when present in an application bundle, is useful signing-related material but its presence, absence, or exact location must be interpreted against the signing workflow and platform target rather than treated as a universal IPA requirement.
- **Inferred:** Nested applications, extensions, frameworks, dynamic libraries, and plug-ins are code-bearing candidates and must be considered separately from ordinary resources.

Important malformed or unsupported cases include an unreadable or corrupt ZIP, unsafe paths, no `Payload/`, no discoverable `.app`, multiple candidate application bundles, a bundle with a missing or unreadable `Info.plist`, a missing executable, duplicate/conflicting archive paths, unsupported Mach-O formats, malformed nested bundles, and symlink or permission patterns the eventual extractor cannot safely preserve.

## Application Metadata

The eventual inspection model should distinguish raw values from normalized display values and should retain the source path for diagnostics. Candidate metadata includes:

- bundle identifier (`CFBundleIdentifier`);
- display name (`CFBundleDisplayName`, with an appropriate fallback policy);
- marketing version (`CFBundleShortVersionString`);
- build number (`CFBundleVersion`);
- minimum OS version (`MinimumOSVersion`, where present and applicable);
- executable name (`CFBundleExecutable`);
- bundle URL/path and bundle type;
- discovered extensions, frameworks, dynamic libraries, plug-ins, nested applications, and other nested bundles.

- **Verified:** `Info.plist` is the primary bundle metadata source, but it is not sufficient by itself to establish that the executable exists, is loadable, or is correctly signed.
- **Inferred:** Metadata readers should preserve unknown keys and report malformed types rather than silently coercing arbitrary values. The exact fallback and display policy remains an architecture decision.

## IPA Validation

Validation should produce structured diagnostics and a classification rather than a single undifferentiated error.

**Valid** means the archive is readable, paths are safe and unambiguous, the expected application structure is identified, required metadata has acceptable types and values, and the declared executable is present. Whether signatures and nested code are valid is a separate validation phase.

**Invalid** means a required structural or metadata condition is definitively broken: for example, ZIP corruption, path traversal, a missing `Payload/`, an unreadable plist, a missing declared executable, or conflicting duplicate paths.

**Unsupported** means the input may be structurally coherent but falls outside a deliberately supported capability, such as an unsupported executable format, archive feature, platform variant, or filesystem construct.

**Ambiguous** means inspection cannot safely choose one interpretation, such as multiple top-level application candidates or conflicting metadata. Ambiguous input must not be silently selected for later signing or installation.

Required validation stages are:

1. read the archive and verify ZIP integrity and path safety;
2. locate application candidates under the expected layout, without assuming a single match;
3. detect multiple applications and nested applications explicitly;
4. parse and validate required `Info.plist` fields;
5. resolve the declared executable and verify it is a regular, readable file;
6. inventory nested code and signing-related files;
7. leave signature, entitlement, provisioning, and platform compatibility checks to explicit later validators.

- **Inferred:** “Readable IPA” and “installable IPA” must remain different outcomes. Installation suitability requires additional platform and signing checks.

## Certificates and Signing Identities

- **Verified:** A signing certificate contains a public key and is signed by an issuer; the corresponding private key is required to create signatures. Possession of a certificate alone does not provide the private key.
- **Verified:** A signing identity is an operational pairing of a certificate and an available matching private key, resolved through the platform's protected key storage and certificate APIs.
- **Verified:** Relevant certificate metadata includes subject and issuer, serial number, validity interval, public-key algorithm and size, key-usage or extended-key-usage information, and chain information.
- **Inferred:** ZynSign should represent certificate inspection, identity resolution, and signing authorization as separate operations. Expiration, trust, revocation status, team association, and private-key availability must be reported independently.
- **Unknown:** The supported identity types, certificate-chain policy, UI for identity selection, and whether any signing operation will be permitted by the first release are not decided.
- **Unresolved:** Whether code-signing identity material can be imported, stored, and used for signing by an iOS/iPadOS application at all, and which platform mechanism would provide that capability, is not established. Key storage and access control on iOS/iPadOS differ from macOS, and the differences must be researched before any identity workflow is designed. Certificate parsing and chain interpretation are subject to the same reservation.

No real credentials, certificates, private keys, or keychain items are to be accessed or created during discovery.

## Provisioning Profiles

- **Verified:** A provisioning profile authorizes an application configuration for a team and distribution/development context. It is signed data containing entitlement and profile metadata.
- **Verified:** Relevant fields include the application identifier, team identifier, bundle identifier relationship, entitlements, profile UUID/name, creation and expiration dates, and development/distribution indicators. Device identifiers may be present for device-bound development or ad hoc profiles.
- **Verified:** The application identifier commonly combines a team identifier with a bundle identifier pattern. The effective application bundle identifier and profile authorization must be compared rather than displayed independently.
- **Inferred:** Compatibility evaluation must consider bundle identifier, entitlements, certificate/identity, platform, profile type, expiration, and device authorization where applicable. Entitlements should be treated as constrained authorization data, not arbitrary application metadata.
- **Unknown:** The exact profile types, entitlement allowlist, platform versions, and distribution workflows ZynSign will support require later platform research and product decisions.
- **Unresolved:** A provisioning profile is signed structured data. Interpreting its contents and validating the container signature are separate problems, and on-device support for CMS signed-data handling — for which no documented iOS/iPadOS equivalent has been confirmed — remains a feasibility question.

**Observed after ZS-017:** ZynSign now parses a caller-supplied decoded XML or binary property-list payload into typed profile metadata and performs bounded structural/date validation. The raw container-to-payload seam is explicit, but no CMS unwrap or signature verification is implemented; an embedded profile is not opened by the archive inspection workflow. Parsed fields remain untrusted observations and no profile is modified or persisted.

## Code Signing

- **Verified:** Executables and libraries commonly use Mach-O format. Mach-O load commands identify the code-signature region, and the code signature contains a code directory with hashes and associated signing data.
- **Verified:** Code signing covers executable content through defined hash slots and may include resource and entitlement information. A CMS signature binds signing data to a certificate chain.
- **Verified:** Code signing is not equivalent to checking that a file exists. Verification must account for the executable format, signature structure, hashes, certificate chain, requirements, entitlements, and platform policy.
- **Verified:** Bundle resource sealing is represented separately from the executable's embedded signature; `_CodeSignature/CodeResources` is relevant when resources are signed.
- **Inferred:** A future signing pipeline will need explicit policies for hash algorithms, requirements, entitlements, certificate selection, profile compatibility, and preservation or replacement of existing signatures.
- **Unresolved:** No assumptions may be made about which signing-related cryptographic operations are available to an iOS/iPadOS application. Digest and signature primitives, key types and attributes, and the usable algorithm set must each be established for the product's own runtime rather than inferred from another Apple platform.
- **Unresolved:** Signed-data (CMS/PKCS#7) construction is a specific concern. Apple's signed-data encoding and decoding services are documented for macOS and are not documented for iOS; whether a supported on-device equivalent exists, and what would be used in its place if not, is unresolved.
- **Unknown:** The precise supported Mach-O architectures, signature versions, entitlement rules, and verification behavior must be confirmed against the target iOS/iPadOS deployment target and the behavior of the platform that evaluates signed content.

Additional research is required for fat/universal Mach-O handling, arm64 variants, code-directory versions, special slots, designated requirements, library validation, detached signatures, and how each platform evaluates nested signatures. No signing or signature verification is implemented in this phase.

## Nested Code

Potential code-bearing nested components include frameworks, dynamic libraries, app extensions, plug-ins, nested applications, and other signed bundles. Each may have its own executable, bundle metadata, resource seal, and signature.

- **Verified:** An outer application can depend on nested code, so changing or replacing nested content can invalidate its signature or its resource seal.
- **Inferred:** A future traversal must identify nested code deterministically, establish dependency relationships, and process innermost dependencies before containers. The exact traversal order and exceptions require validation with real signed packages; developer-side Apple tooling may be used as a reference for generating and inspecting such fixtures, but it is not part of the product runtime.
- **Unknown:** The complete set of supported nested-code locations and platform-specific signing rules is not established.

No signing traversal is implemented.

## Repackaging

A future repackaging workflow will need to:

1. extract into a controlled temporary location while preventing path traversal and unsafe links;
2. preserve or intentionally normalize file contents, modes, executable bits, timestamps, and relevant extended attributes;
3. modify only explicitly selected content;
4. remove or replace signatures and related metadata consistently;
5. sign nested code before containing bundles, then sign the application;
6. rebuild an IPA with a compatible ZIP layout and deterministic path handling;
7. validate the resulting archive separately from validating its signatures.

- **Verified:** Rebuilding a ZIP is not a byte-preserving operation. ZIP entry names, permissions, compression, timestamps, directory entries, and ordering can change.
- **Inferred:** Metadata preservation must be policy-driven. Keeping stale signatures after content changes is unsafe; deleting signature material without a complete replacement produces an unsigned or invalid artifact.
- **Unknown:** Required archive layout, permission policy, reproducibility requirements, and supported preservation of extended attributes require iOS/iPadOS feasibility research — including what the application sandbox and the available archive capabilities permit — together with product decisions.

No extraction, modification, signature removal, signing, or archive rebuilding is implemented.

## Installation

Before installation functionality is designed, ZynSign must establish which mechanisms and targets are supported, how a signed artifact reaches a device, and what authorization is required. Installation is a separate capability boundary from signing: producing a validly signed package does not establish that the package can be installed, or that it can be installed on the device ZynSign itself is running on.

- **Verified:** Installation suitability depends on platform policy, a compatible signed application, provisioning and entitlement constraints, device state, and a trust relationship or authorization path.
- **Inferred:** Developer-mode requirements, device authorization, OS compatibility, transport, and failure reporting are platform- and workflow-specific and cannot be inferred from IPA structure alone.
- **Unresolved:** No public, application-facing mechanism is known through which a sandboxed iOS/iPadOS application installs an IPA onto its own device. The candidate mechanisms sit outside the application — managed-device installation on managed or supervised devices, over-the-air installation through a manifest served over HTTPS with explicit user confirmation, and host-based developer tooling that is not part of the product runtime. Each requires an authorization, a managed relationship, or a user action that ZynSign cannot supply by itself.
- **Unknown:** Which of those mechanisms, if any, fits the product; what authorization and user-consent model applies; and whether installation is in scope for an initial release are undecided.

ZynSign currently does not support installation. No device communication, authorization, simulator, or installation testing is performed here.

## Security Considerations

Sensitive boundaries include private keys and keychain items; certificate and provisioning-profile material; authentication or pairing data; imported IPAs; extracted temporary files; signed output artifacts; logs, crash reports, and diagnostics; and device metadata.

Future security requirements should include:

- never exporting or logging private key material or authentication secrets;
- minimizing the lifetime of imported, extracted, and generated artifacts;
- using private temporary directories with restrictive permissions and cleanup on success and failure;
- treating archives, plist values, Mach-O data, profiles, and logs as untrusted input;
- preventing path traversal, symlink escapes, decompression/resource exhaustion, duplicate-path confusion, and unsafe permission changes;
- separating inspection from privileged keychain, signing, and device operations;
- requiring explicit user intent before selecting identities, accessing protected keychain items, or producing a signed artifact;
- redacting certificates, profiles, entitlements, device identifiers, and paths where logs could expose sensitive context;
- defining retention, cancellation, crash-recovery, and secure cleanup behavior;
- avoiding access to real credentials during development and testing.

- **Inferred:** Security boundaries should be represented in APIs and storage policy, not only in UI warnings. Exact keychain access groups, entitlement requirements, and threat model remain open.

## Platform Constraints

- **Verified:** Swift and Foundation are appropriate candidates for pure data models, plist handling, path logic, diagnostics, and policy code, subject to platform availability on the deployment target.
- **Verified:** SwiftUI is a UI framework and should not be the boundary for archive parsing, validation, or signing policy.
- **Requires feasibility research:** The Security framework and Keychain Services are the relevant platform areas for certificate, identity, private-key, and protected-secret access, but their iOS/iPadOS behavior has not been verified for the operations ZynSign needs. Availability, access control, protection classes, key attributes, import restrictions, and per-use authorization each differ from macOS and must be established rather than assumed.
- **Inferred:** Filesystem and archive handling should use controlled URLs and explicit security policy inside the application sandbox. The eventual archive implementation must define support for ZIP features, symlinks, permissions, malformed entries, and resource limits, and must account for user-selected document access rather than unrestricted filesystem access.
- **Unknown:** The available system archive APIs, required third-party dependencies (if any), and their behavior across supported iOS/iPadOS deployment targets are not established.
- **Unknown:** Device communication mechanisms, developer-mode behavior, installation tooling, and platform restrictions must be validated on actual supported device and OS combinations.

Platform research on iOS/iPadOS is required for key storage and access behavior, the availability of the cryptographic primitives the signing formats need, archive capability and filesystem metadata fidelity, and the deployment target itself. macOS and Xcode may be used alongside that research for developer-side fixture generation and independent artifact inspection, which is not the same as proving on-device capability. No such testing is expected or performed in Phase 0.

## Architecture Implications

- Define domain models for archive entries, application bundles, metadata, nested code, certificates, profiles, diagnostics, validation results, and signed artifacts. Keep raw values and normalized values distinguishable.
- Put ZIP access, plist decoding, bundle discovery, Mach-O inspection, profile inspection, and certificate inspection behind narrow parsing boundaries that accept untrusted input and return diagnostics.
- Keep structural validation, metadata validation, signing compatibility, signature verification, and installation readiness as separate boundaries with explicit Valid, Invalid, Unsupported, and Ambiguous outcomes.
- Isolate key storage and access, certificate and profile services, filesystem and document access, temporary storage, and device integration behind platform-specific adapters that implement ports declared by the layers that consume them. Keep policy and most transformations in testable pure Swift. Developer-side desktop tooling is not an adapter and does not appear in the runtime layer model.
- Treat temporary extraction and artifact storage as controlled services with cleanup, permissions, retention, and cancellation semantics.
- Make nested-code discovery deterministic and preserve enough provenance to explain signing-order and dependency decisions.
- Reserve physical-device and simulator tests for behavior that cannot be established with fixture-based pure tests, and gate any test of a capability on that capability having been verified as available. Developer-side macOS/Xcode tooling is used to generate fixtures and inspect artifacts; it is not a substitute for product testing.

## Open Questions

1. Which iOS/iPadOS versions are in the supported target matrix, and therefore which platform capabilities are available?
2. Is ZynSign intended to inspect only, or will a later release produce signed and installable artifacts?
3. Which IPA layouts, ZIP features, symlinks, permissions, and archive limits are supported?
4. What is the policy when multiple application bundles or nested applications are present?
5. Which Mach-O architectures, code-signature versions, entitlements, and requirements must be understood?
6. Which certificate types, trust policies, identity-selection rules, and keychain access patterns are supported?
7. Which provisioning-profile types and entitlement compatibility rules are supported?
8. Which nested-code locations are traversed, and what exceptions affect signing order?
9. Which archive metadata and filesystem attributes must be preserved when repackaging?
10. What installation mechanisms, device transports, developer-mode states, and authorization flows are in scope?
11. What is the threat model, retention policy, and cleanup guarantee for imported files, temporary data, logs, profiles, and signed artifacts?
12. Which behaviors require physical-device or simulator execution rather than portable unit tests, and which fixtures must be produced with developer-side tooling?
13. Which cryptographic primitives needed by the signing formats are usable from an iOS/iPadOS application, and how is signed-data construction handled if no supported on-device encoder exists?
14. Can code-signing identity material be imported, protected, and used on-device, and under what access control?
15. Is on-device installation of a produced artifact possible at all through supported means, and if so, what authorization and consent model applies?

## Non-Goals

This document does not create an Xcode project, production Swift or SwiftUI code, dependencies, CI, or GitHub configuration. It does not implement IPA parsing or extraction, CMS/profile authenticity or management, signing, signature verification, entitlement authorization, repackaging, installation, device communication, or tests against real credentials, certificates, private keys, profiles, macOS, Xcode, simulators, or devices. ZS-017's decoded-payload parser is implementation work recorded separately in the architecture document.
