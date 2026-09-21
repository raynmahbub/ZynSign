# Phase 0 — Technical Discovery

## Purpose

Establish the technical facts, constraints, and unresolved questions needed before ZynSign's application architecture is designed. This document describes future capabilities only; none of the parsing, signing, packaging, or installation behavior described here is implemented.

## Scope

The scope is inspection and eventual preparation of iOS application packages, together with the signing material and platform services those workflows may require. Findings are classified as **Verified**, **Observed**, **Inferred**, or **Unknown**. A classification applies to the statement it follows, not to an entire section.

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
- **Verified:** A signing identity is an operational pairing of a certificate and an available matching private key, normally resolved through a keychain and security APIs.
- **Verified:** Relevant certificate metadata includes subject and issuer, serial number, validity interval, public-key algorithm and size, key-usage or extended-key-usage information, and chain information.
- **Inferred:** ZynSign should represent certificate inspection, identity resolution, and signing authorization as separate operations. Expiration, trust, revocation status, team association, and private-key availability must be reported independently.
- **Unknown:** The supported identity types, certificate-chain policy, UI for identity selection, and whether any signing operation will be permitted by the first release are not decided.

No real credentials, certificates, private keys, or keychain items are to be accessed or created during discovery.

## Provisioning Profiles

- **Verified:** A provisioning profile authorizes an application configuration for a team and distribution/development context. It is signed data containing entitlement and profile metadata.
- **Verified:** Relevant fields include the application identifier, team identifier, bundle identifier relationship, entitlements, profile UUID/name, creation and expiration dates, and development/distribution indicators. Device identifiers may be present for device-bound development or ad hoc profiles.
- **Verified:** The application identifier commonly combines a team identifier with a bundle identifier pattern. The effective application bundle identifier and profile authorization must be compared rather than displayed independently.
- **Inferred:** Compatibility evaluation must consider bundle identifier, entitlements, certificate/identity, platform, profile type, expiration, and device authorization where applicable. Entitlements should be treated as constrained authorization data, not arbitrary application metadata.
- **Unknown:** The exact profile types, entitlement allowlist, platform versions, and distribution workflows ZynSign will support require later macOS/Xcode testing and product decisions.

Provisioning-profile parsing is outside this phase; no profile is opened or modified here.

## Code Signing

- **Verified:** Executables and libraries commonly use Mach-O format. Mach-O load commands identify the code-signature region, and the code signature contains a code directory with hashes and associated signing data.
- **Verified:** Code signing covers executable content through defined hash slots and may include resource and entitlement information. A CMS signature binds signing data to a certificate chain.
- **Verified:** Code signing is not equivalent to checking that a file exists. Verification must account for the executable format, signature structure, hashes, certificate chain, requirements, entitlements, and platform policy.
- **Verified:** Bundle resource sealing is represented separately from the executable's embedded signature; `_CodeSignature/CodeResources` is relevant when resources are signed.
- **Inferred:** A future signing pipeline will need explicit policies for hash algorithms, requirements, entitlements, certificate selection, profile compatibility, and preservation or replacement of existing signatures.
- **Unknown:** The precise supported Mach-O architectures, signature versions, entitlement rules, and verification behavior must be confirmed against the target macOS toolchain and Apple platform behavior.

Additional research is required for fat/universal Mach-O handling, arm64 variants, code-directory versions, special slots, designated requirements, library validation, detached signatures, and how each platform evaluates nested signatures. No signing or signature verification is implemented in this phase.

## Nested Code

Potential code-bearing nested components include frameworks, dynamic libraries, app extensions, plug-ins, nested applications, and other signed bundles. Each may have its own executable, bundle metadata, resource seal, and signature.

- **Verified:** An outer application can depend on nested code, so changing or replacing nested content can invalidate its signature or its resource seal.
- **Inferred:** A future traversal must identify nested code deterministically, establish dependency relationships, and process innermost dependencies before containers. The exact traversal order and exceptions require validation with real signed packages and Apple tooling.
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
- **Unknown:** Required archive layout, permission policy, reproducibility requirements, and supported preservation of extended attributes require macOS testing and product decisions.

No extraction, modification, signature removal, signing, or archive rebuilding is implemented.

## Installation

Before installation functionality is designed, ZynSign must establish which mechanisms and targets are supported, how device communication is performed, and what authorization is required.

- **Verified:** Installation suitability depends on platform policy, a compatible signed application, provisioning and entitlement constraints, device state, and a trust relationship or authorization path.
- **Inferred:** Developer-mode requirements, device pairing, developer authorization, OS compatibility, transport, and failure reporting are platform- and workflow-specific and cannot be inferred from IPA structure alone.
- **Unknown:** Supported devices, macOS APIs or tools, transport mechanisms, authorization UX, and whether installation is in scope for an initial release are undecided.

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

- **Verified:** Swift and Foundation are appropriate candidates for pure data models, plist handling, path logic, diagnostics, and policy code, subject to platform availability.
- **Verified:** SwiftUI is a UI framework and should not be the boundary for archive parsing, validation, or signing policy.
- **Verified:** The Security framework and Keychain Services are the relevant platform areas for certificate, identity, private-key, and protected-secret access; their behavior is macOS-specific and permission-sensitive.
- **Inferred:** Filesystem and archive handling should use controlled URLs and explicit security policy. The eventual archive implementation must define support for ZIP features, symlinks, permissions, malformed entries, and resource limits.
- **Unknown:** The available system archive APIs, required third-party dependencies (if any), and their behavior across supported macOS versions are not established.
- **Unknown:** Device communication APIs, developer-mode behavior, installation tooling, and platform restrictions must be validated on actual supported macOS and device combinations.

Actual macOS/Xcode testing is required for Security framework and keychain behavior, Mach-O and signing-tool interoperability, archive permissions and extended attributes, Swift/SwiftUI deployment targets, and every device or installation workflow. No such testing is expected or performed in Phase 0.

## Architecture Implications

- Define domain models for archive entries, application bundles, metadata, nested code, certificates, profiles, diagnostics, validation results, and signed artifacts. Keep raw values and normalized values distinguishable.
- Put ZIP access, plist decoding, bundle discovery, Mach-O inspection, profile inspection, and certificate inspection behind narrow parsing boundaries that accept untrusted input and return diagnostics.
- Keep structural validation, metadata validation, signing compatibility, signature verification, and installation readiness as separate boundaries with explicit Valid, Invalid, Unsupported, and Ambiguous outcomes.
- Isolate keychain, Security framework, signing tools, filesystem extraction, and device communication behind platform-specific adapters. Keep policy and most transformations in testable pure Swift.
- Treat temporary extraction and artifact storage as controlled services with cleanup, permissions, retention, and cancellation semantics.
- Make nested-code discovery deterministic and preserve enough provenance to explain signing-order and dependency decisions.
- Reserve macOS/Xcode/device integration tests for behavior that cannot be established with fixture-based pure-Swift tests.

## Open Questions

1. Which macOS versions and device OS versions are in the supported target matrix?
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
12. Which behaviors require Apple tooling or real macOS/device fixtures rather than portable unit tests?

## Non-Goals

This document does not create an Xcode project, production Swift or SwiftUI code, dependencies, CI, or GitHub configuration. It does not implement IPA parsing or extraction, certificate or provisioning-profile parsing or management, signing, signature verification, entitlement processing, repackaging, installation, device communication, or tests against real credentials, certificates, private keys, profiles, macOS, Xcode, simulators, or devices.
