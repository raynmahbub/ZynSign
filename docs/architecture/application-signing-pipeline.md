# Application Signing Pipeline

The end-to-end application signing workflow: integrity, profile,
discovery, extraction, nested signing, resource sealing, main-executable
signing, packaging, and independent verification. The pipeline composes
the archive, provisioning, nested-signing, resource-sealing, Mach-O
signing, packaging, and verification machinery into the single order a
signed container requires. It is implemented at the application layer,
constructed at the composition root, and covered by unit tests; since
0.1.0-dev it is installed in the application environment and reachable from
`Library`/`Application Detail` (`SigningView`) and `Settings → Signing → Certificates & Profiles`;
installation remains unavailable and device validation with real identities
and profiles is the next step.

The pipeline is driven by the signing engine, which owns the run around it —
the stage vocabulary and progress, the isolated working copy, the pre-signing
validation gate, delivery only after verification, and the recovery facts a
refused run reports. See [signing-engine-execution.md](signing-engine-execution.md).
The pipeline document below stays authoritative for the nine stages themselves
and for the composition facts that bound what they can sign.

## Order and failure semantics

A run proceeds through nine stages in fixed order, each running on the
previous stage's established output:

1. **Integrity** — the source container is structurally validated and its
   bundle, metadata, and executable are established.
2. **Profile** — the replacement profile is validated against the
   application, the identity, and the caller's configuration. Anything
   short of the pipeline's `valid` status fails the run.
3. **Discovery** — nested code is discovered over the source container
   and a validated signing plan is derived. Unsupported items fail the
   run; the pipeline signs nothing it cannot establish.
4. **Extraction** — the source container is extracted to a disposable
   working copy and the replacement profile is embedded.
5. **Nested signing** — every nested target is signed inside the working
   copy through the existing nested use case.
6. **Resource sealing** — the working copy's resources are sealed, the
   seal references each nested binary by its code-directory digest, and
   the seal is written into the working copy.
7. **Main executable** — the main executable is signed with the seal and
   the caller's entitlements.
8. **Packaging** — the working copy is rebuilt as a deterministic
   container.
9. **Verification** — the rebuilt container is independently verified
   against the run's expectations.

Any refusal or failure ends the run with the refusing stage and a typed
reason, and no container is delivered. The working copy is discarded on
every path. Cancellation propagates as `CancellationError`; every other
failure is a returned result, never a thrown error.

## Composition facts

Three facts of the composed machinery shape what the pipeline can sign,
and all three are documented on the pipeline itself:

- **Existing signatures are rejected.** The signing machinery appends
  signatures and refuses replacement, so inputs must be unsigned. A
  signed input fails, at the latest, when its first binary is signed.
- **Nested targets sign without their own resource seals.** The nested
  use case takes no per-target seal input, so nested binaries carry no
  slot-3 binding. The main seal references each nested binary by its
  code-directory digest.
- **Symbolic links are recorded as seal omissions.** The platform's own
  treatment of links is not established in ZynSign's record, so the
  pipeline seals what it can state and omits the rest explicitly under
  the sealing configuration's `exclude` policy.

The pipeline's use of the single-image cryptographic policy is the
explicit opt-in point for the cryptographic act; it is not an
authorization claim, and device validation remains required before any
conclusion about installation.

## Deterministic packaging

Signed bundles are rebuilt through the `ArchiveWriter` boundary. The
entry set is validated before anything is written: duplicates, file and
link conflicts against implied directories, non-empty directories, and
resource overflows refuse the whole set. Recorded names are ordered in
ascending UTF-8 order with implied parent directories inserted, so the
same bundle always yields the same container bytes. The concrete
selection is a stored-only ZIP writer with fixed timestamps, fixed Unix
modes, executable bits preserved from the working copy, and symbolic
links recorded with their targets; ZIP64, encryption, and multi-disk
containers are refused.

Every rebuilt container is reopened through the ordinary archive
boundary and held to the same rules as any imported package:
structural validation must pass, the bundle must be discovered at its
expected location, and the recorded entry sequence must equal the plan
that produced it. A container that fails any of those checks is removed
and reported, never delivered.

## Safe extraction

Extraction reads through the `ArchiveReader` boundary and writes
regular files, directories, and — under an explicit policy — symbolic
links. Every entry is validated before anything is written, and writing
runs directories shallow-first, then files, then links, so no recreated
link can redirect a write that follows it. Every written location is
confined to the destination by its canonical path, link targets must
resolve inside the destination, and file permission bits come from the
Unix mode the container records when it records one. The signing
pipeline extracts with link recreation enabled, because real bundles
contain links; the default policy refuses them.

## Independent verification

Verification reopens the delivered container through the archive
boundary and checks it against expectations captured from the signing
run: structure, metadata, executable presence, exact profile bytes,
exact seal bytes, re-computed seal digests, main-executable signature
presence with embedded entitlements and the slot-3 binding to the
sealed resources, and nested-executable signature presence. The
verifier shares the deterministic parsers and inspectors with the rest
of ZynSign but no signing state: nothing the signer believed is taken
on trust.

A passing report means the container is exactly what the signing run
produced and internally coherent — nothing more. Cryptographic validity
to any trust evaluator is not established, platform authorization is
not claimed, and installability is not concluded.

## Installation capability

Installation assessment is a pure function over evidence the caller
establishes elsewhere: the provisioning pipeline's status, target-device
authorization, and platform support. It reports one outcome —
installation is not available — with the exact limitations in
deterministic order, always including the platform fact that no
supported delivery mechanism exists. The model carries no installable
case; adding one requires a demonstrated mechanism. See
[installation-compatibility.md](installation-compatibility.md) for the
six validity and compatibility statements this assessment speaks in.

## Evidence levels

- The writer's format contract is held by independent golden vectors:
  byte sequences assembled outside the implementation and validated by
  host tooling, embedded in the test target.
- The pipeline's success paths sign synthetic containers assembled at
  run time — fixture Mach-O binaries, a fixture information file, and
  the synthetic profile container the provisioning suites commit — and
  assert every stage's evidence.
- Refusal paths prove each stage fails closed and delivers nothing.
- No XCTest suite in this increment was executed in the review
  environment, which has no Xcode runner. The suites passed on hosted CI
  afterwards (run 35992989870, on a simulator). The host vector script for
  the writer goldens checks the committed vectors, not the Swift
  implementation.
- The pipeline suites prove orchestration, not cryptography: they sign
  through a replay capability that returns one fixed signature for any
  input and verify through an always-valid verifier. A real private-key
  signature first passes through the pipeline in the ZS-031 external
  validation export, where Apple's `codesign` rejects the delivered bundle
  because it does not recognize the resource seal, and the signature
  format fails Apple's documented iOS 15+ requirements. See
  [external-validation.md](external-validation.md).
- Device conclusions — installation, platform acceptance, trust
  evaluation — remain unvalidated and unclaimed throughout.
