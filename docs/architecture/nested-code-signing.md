# Nested code signing (ZS-028)

## Status and evidence

The nested code signing layer turns the cryptographic single-image capability
established by ZS-026 into a dependency-aware nested signing operation based
on the signing plan produced by ZS-027.

Release verification remains bounded by the development environment: host
vector checks and focused tests pass; no physical iOS device or Xcode toolchain
is available here. Do not promote nested signing to full application signing,
IPA packaging, or installation on the strength of host-only checks.

Evidence reviewed on 2026-09-23:

- **Verified — signing order dependency:** child components must be finalized
  before their enclosing container. The signature of a container seals its contents;
  changing a child component after signing its container invalidates the container's
  seal.
- **Verified — deterministic ordering:** topologically sorting the dependency
  graph with bundle-relative location tie-breaking guarantees reproducible,
  deterministic signing orders across runs.
- **Verified — format boundary:** existing cryptographic abstractions (ZS-021),
  Mach-O parser (ZS-022), CodeDirectory construction (ZS-023), SuperBlob
  serializer (ZS-024), and signature region writer (ZS-025) are reused directly;
  no duplicate signing pipeline is introduced.
- **Observed — existing signature replacement:** in-place signature replacement
  requires either matching region reservation or linkedit segment relocation.
  Because general relocation is unsupported, existing signatures are rejected by
  policy rather than risking unsafe mutation or preserving stale signatures.
- **Unknown — platform policy:** structural and cryptographic validity do not
  imply iOS AMFI or CoreTrust acceptance.
- **Requires experiment:** physical device execution of nested binaries signed
  with detached CMS.

## Architecture and nested signing flow

The nested signing pipeline consists of:

1. **Plan validation (`NestedSigningPlanValidator`):**
   - The input `NestedCodeSigningPlan` from ZS-027 is validated prior to mutation.
   - All bundle-relative paths are checked against directory traversal.
   - Duplicate items, duplicate executable paths, and cyclic dependencies are refused.
   - Ordering constraints are strictly enforced: every dependency must be scheduled
     before its container.
   - The root application executable is excluded from the nested target list and
     preserved for the later application pipeline.
   - Unsupported code kinds, universal binaries, and unestablished targets fail
     validation before any artifact modification.

2. **Sequential deterministic execution (`SignNestedCodeUseCase`):**
   - Nested targets are signed sequentially in exact topological order.
   - Concurrency is intentionally not introduced to prevent race conditions,
     non-deterministic execution, and uncontrolled file mutations.

3. **Single Mach-O signing (`SignMachOUseCase`):**
   - For each target, the binary is read from the artifact store.
   - Existing signatures are inspected. Unsigned binaries proceed; existing valid,
     malformed, or unsupported signatures fail cleanly.
   - The CodeDirectory is constructed with the target's identifier, team,
     SHA-256 hash type, and calculated code limit.
   - The existing cryptographic capability is invoked once per binary.
   - The signature SuperBlob is constructed and written to the Mach-O region.

4. **Independent verification:**
   - Every signed binary is reparsed and verified immediately after signing.
   - Structural verification checks Mach-O slices, `LC_CODE_SIGNATURE` bounds,
     SuperBlob slots, CodeDirectory fields, and recomputed page hashes.
   - Cryptographic verification checks the CodeDirectory digest against CMS
     signed attributes and verifies the CMS signature using the public key verifier.

5. **Failure atomicity & mutation strategy:**
   - `stagedWorkingCopy`: modifications are held in memory or working staging,
     and committed to the underlying artifact store only if all targets succeed.
     If a failure occurs, changes are discarded and `.noTargetsModified` is reported.
   - `directMutation`: modifications are written to the store sequentially. If a
     failure occurs midway, `.someTargetsModified` is reported, accurately reflecting
     partial completion.

## Supported scope and existing signature policy

Admitted nested targets:
- Thin little-endian arm64 Mach-O images.
- Code kinds: `.framework`, `.dynamicLibrary`, `.applicationExtension`.
- Unsigned binaries with valid two-segment layouts (`__TEXT` and `__LINKEDIT`).

Existing signature handling:
- **Unsigned:** signed via append mutation.
- **Correctly structured existing signature:** rejected by default (`.rejectExistingSignature`);
  if replacement is requested, returns `.unsupportedExistingSignature`.
- **Malformed existing signature:** rejected cleanly with `.malformedExistingSignature`.
- **Unsupported signature format:** rejected cleanly with `.unsupportedFormat`.
- **Universal (fat) Mach-O:** rejected cleanly with `.unsupportedFormat`.

## Extension points for future stages

- **ZS-029 (Entitlements & Requirements):** `NestedCodeSigningConfiguration` exposes
  `flags` and `specialSlots` hooks. No entitlements, requirement blobs, or
  `CodeResources` are fabricated in ZS-028.
- **Application signing:** Parent application executable signing is strictly deferred.
- **IPA packaging:** Creation of ZIP packages or distribution archives is out of scope.
