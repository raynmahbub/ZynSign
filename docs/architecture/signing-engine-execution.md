# Signing Engine Execution

**Status:** implemented · **Layer:** Application (+ Presentation) · **Step:** Alpha 1 — Step 7

This document records the decision behind the signing engine: the coordinator
that executes one complete on-device signing run behind a single entry point,
the working-copy boundary every write happens inside, the pre-signing
validation gate, the order nested code is signed in, the independent
verification that runs before anything is delivered, and the failure-recovery
facts a refused run reports.

The engine is the composition of pieces this repository already had — the nine
stage `SignApplicationPipeline`, nested code signing, Mach-O signing, resource
sealing, deterministic packaging, and the container verifier — behind one
vocabulary, one progress stream, one result type, and one set of safety
properties. It adds no new cryptographic machinery of its own.

Related records:
[application-signing-pipeline.md](application-signing-pipeline.md) (the nine
stages and their failure semantics), [nested-code-signing.md](nested-code-signing.md),
[codedirectory-construction.md](codedirectory-construction.md),
[macho-signature-region.md](macho-signature-region.md),
[signing-metadata.md](signing-metadata.md),
[installation-compatibility.md](installation-compatibility.md).

## The problem

The pipeline could sign one application correctly, but everything the product
needed around that run lived at the edges: progress was a single opaque call,
the interface had no structured account of what each stage established, a
refusal was a stage name and a sentence, and there was no agreed answer to
"what happened to the original, the temporary copy, and the delivery location
when the run stopped?"

Step 7 turns that into one execution contract:

- **one coordinator** — `SigningEngineCoordinator` — owns the order of a run;
- **one stage vocabulary** — `SigningEngineStage` — is shared by the
  coordinator, the progress tracker, diagnostics, and the interface;
- **one result type** — `SigningEngineResult` — carries either a delivered
  container with every stage's structured outcome, or the refusing stage with
  a typed reason and the recovery facts;
- **one progress stream** — `SigningEngineProgress` — that the interface and
  VoiceOver both render, with an estimate once one is meaningful.

## The run, stage by stage

`SigningEngineStage` is the single source of the run's order. Every stage
carries its title, its one-line summary, its SF Symbol, and its share of the
run's work (the weights sum to `1`, which is what makes the fraction
comparable across runs that sign twenty nested targets and runs that sign
none).

| # | Stage | What it does | What it can fail with |
|---|-------|--------------|-----------------------|
| 1 | Preparing | Creates the isolated working copy, fingerprints the original | storage failure |
| 2 | Validating | Structural validation, information file, declared executable, required files, nested readability, supported layout; then the pipeline's integrity, profile, discovery, and extraction stages into that working copy | invalid input, unsupported input |
| 3 | Signing Frameworks | Signs every `.framework` target, inner code first | nested signing failures |
| 4 | Signing Dynamic Libraries | Signs every bundled dynamic library, inner code first | nested signing failures |
| 5 | Signing Extensions | Signs every `.appex`, inner code first | nested signing failures |
| 6 | Signing Nested Applications | Signs any contained application bundle, inner code first | nested signing failures |
| 7 | Signing App | Seals resources, then signs the main executable with the selected identity, the embedded profile, and the entitlement set | sealing and Mach-O signing failures |
| 8 | Verifying | Re-reads the signed working copy and independently verifies every signed binary, the seal, the entitlements, the profile, and the bundle's own facts | any verification check |
| 9 | Packaging | Builds the deterministic `Payload/` container **outside** the delivery location, verifies the written container, and only then moves it into place | packaging and container verification |
| 10 | Complete | Discards the working copy and reports what was reclaimed and that the original was re-measured | — |

Stages 3–6 are reported as **skipped** with a reason when a bundle carries no
code of that kind. The engine never hides them: "Signing Dynamic Libraries —
skipped, none in this bundle" is a fact about the run, while an absent row
would be an absence of information.

The nested stages are presented in dependency order, and the underlying plan
sorts targets so that every child is finalized before its container. The
engine does not re-derive that order, and it never signs the host application
before nested code: the host's executable is signed in stage 7, after the
seal that references each nested binary by its code-directory digest.

## The working-copy boundary

`SigningWorkingCopy` owns the only directory a run writes to:

- it lives under `ZynSignSigning-<UUID>/` beneath the configured root (the
  system temporary directory by default), so two runs never share a path;
- the original container is fingerprinted (SHA-256 over its exact bytes) when
  the copy is created, and **re-measured** when the copy is discarded — the
  reported `originalUnchanged` is a measurement, never an assumption;
- discarding is idempotent and reports how many items and bytes were
  reclaimed;
- the source container is never extracted into place, never written beside,
  and never renamed. Validation, integrity, profile, discovery, and extraction
  all read it through the ordinary read-only archive boundary.

The pipeline accepts a caller-supplied working root and, on that path, never
removes it: the engine that created the copy is the engine that discards it.
This is what makes the cleanup observable — the interface reports the items
reclaimed, and a test can assert the root is empty afterwards.

## Validation before signing

`SigningEngineBundleValidator` reads the source container and returns a
`BundleValidationReport` of six fixed checks, in this order:

1. **payloadStructure** — `Payload/` holds exactly one application bundle, and
   its name is a bundle name.
2. **informationFile** — `Info.plist` is present, readable, and parses into
   bundle metadata that declares an identifier and an executable.
3. **executableFile** — the declared executable is recorded exactly once as a
   regular file and is a Mach-O image this build signs (thin, 64-bit,
   little-endian, arm64, `MH_EXECUTE`).
4. **requiredFiles** — the information file and the declared executable are
   each present exactly once.
5. **nestedBundles** — every nested container discovery located has a readable
   information file and a recorded executable, so nested signing cannot
   discover an unreadable container halfway through.
6. **supportedLayout** — the container uses only forms this build signs:
   no existing signature under the run's policy (the default rejects signed
   inputs, because signing appends and never replaces), no unsupported nested
   items, and no rejected discovery.

The checks run **before** a byte is signed. A failed check ends the run at
the Validating stage with the first failing check's title and detail; nothing
is written, and the working copy is discarded in the same breath.

An unreadable container is not a validation finding: it throws out of the
validator and the coordinator reports it as an unavailable input, because
"the file cannot be read" is an infrastructure fact, not a verdict about the
bundle's structure.

## Independent verification

Two independent verifications run before the product claims anything, and
neither reuses signing state.

`SigningEngineVerifier` operates on the **signed working copy**. For every
binary — the main executable and each nested target — it re-reads the bytes
from disk and checks:

- `code-directory` — the decoded CodeDirectory's identifier, team, hash type,
  page size, and code limit; the code limit must name the byte where the
  signature region begins, and the region must end at the artifact's end;
- `page-hashes` — the page hashes are recomputed from the signed bytes with a
  fresh hasher and compared slot by slot;
- `special-slots` (main executable) — slot 3 must bind the **seal bytes** and
  slot 5 the **canonical entitlement blob**, both recomputed at verification
  time;
- `entitlements` (main executable) — the embedded entitlements blob must
  decode to exactly the set the run was asked to sign;
- `signature` — the CMS blob must verify over the CodeDirectory under the
  certificate resolved *now* from secure storage.

Two bundle-level checks sit above them: `main/bundle-consistency` (the
information file still declares the identifier and executable the run
recorded, and the executable and seal are present) and
`main/provisioning-compatibility` (the embedded profile bytes are the profile
the run was given, the profile authorizes the bundle identifier, and no
requested claim conflicts with the profile's allowlist). A
`main/certificate-relationship` check states which certificate the signature
was verified against.

`VerifySignedApplication` operates on the **written container** after
packaging: it reopens the archive through the ordinary reader and re-checks
structure, metadata, profile bytes, seal bytes, seal digests, the main
executable's presence in the signature, and the nested executables.

Both reports are facts, not policy: a passing check says the bytes hold up.
Neither evaluates certificate trust, platform authorization, or
installability.

## Packaging and delivery

Packaging runs only after the working copy verified. The container is written
to a scratch path **inside** the working copy, verified again there, and moved
into the delivery location only after it passed. Consequences, stated plainly:

- a failed run never overwrites an artifact that was already at the delivery
  location, and says so (`outputPreexisted`);
- a verification failure removes nothing the user has: the scratch container
  is discarded with the working copy;
- the delivery move is the only step that replaces an existing artifact.

Verification's "Verify Again" action re-runs the container verification on the
delivered file. It reads and never removes: a container that no longer
verifies is reported, not deleted.

## Failure recovery

Every refusal returns a `SigningEngineResult` with `status == .failed` and a
`SigningEngineFailure` carrying:

- the **stage** that refused, in the engine's own vocabulary;
- a bounded **detail** (bundle-relative locations only — never identities,
  keys, or profile content) and a **category** (`DiagnosticCategory`);
- a user-presentable **userMessage**;
- the recovery facts: `originalUnchanged` (re-measured after the failure),
  `workingCopyDiscarded`, `outputRemoved`, and `outputPreexisted`;
- the run's **diagnostics**: the stage detail lines in stage order.

`isRetryable` distinguishes input faults (invalid, unsupported, or ambiguous
input — the same inputs fail the same way) from conditions (unavailable
capability, storage failure, cancellation, internal failure). The interface
offers **Try Again** only in the retryable case.

Cancellation is not a failure result: it propagates as `CancellationError`
after the working copy is discarded, exactly like every other use case in this
repository.

## Progress and presentation

`SigningEngineProgressTracker` is reference-typed, I/O-free, and clock-free:
callers pass the elapsed time in, so estimates are testable without waiting.
A snapshot carries one record per stage (state, completed and total item
counts, the latest detail line), the current stage, the fraction, the elapsed
time, and an estimate. The estimate is offered only once the run has done at
least 10% of its work and has been running for at least 0.4 seconds — before
that a projection would be noise.

The tracker is driven from inside the run: the pipeline reports stage events
and one event per nested target, the nested signer reports per-target
progress, and the coordinator maps both into engine stages. The observer
cannot influence the run — it has no return value and no failure channel.

The interface renders the same snapshot the tests assert on:

- `ZSigningStageList` shows one row per stage with a checkmark, a spinner, an
  honest dash, or a failure mark, plus counts and the live detail;
- `ZProgressRing` carries the fraction and the current stage's name;
- the estimate appears as "≈ Ns left" only when the tracker offers one;
- **Export IPA** shares the delivered container, **Open Details**
  (`SigningDetailsView`) shows the stage table, every verification check, and
  the recovery facts, **Verify Again** re-runs container verification, and
  **Return to Library** leaves the screen;
- Dynamic Type is honoured (semantic fonts, no fixed sizes), VoiceOver reads
  each stage row as one element ("Signing Frameworks, in progress, 2 of 3"),
  the design tokens resolve through semantic colors so Dark Mode needs no
  separate treatment, and the layout is a plain `List` so iPhone and iPad both
  get the platform's own behavior.

## What this does not establish

A signed, verified, delivered container is internally coherent: it carries the
identity's signature, the profile the run was given, the entitlement set it
was asked to sign, and a resource seal that references its nested binaries.
It is **not** a claim that any certificate is trusted, that the platform
authorizes the result, that the application will install, or that a device
would accept it. Those conclusions require evidence this run never holds, and
no screen in the product states them.

## Tests

`Tests/ZynSignTests/SigningEngineCoordinatorTests.swift` covers the run's
promises against synthetic containers built at run time:

- signing end to end and delivering a verified container — stage outcomes for
  every stage, skipped nested stages with reasons, summary counts, both
  verification reports, and the working-copy facts;
- signing a nested framework — the framework stage succeeds with its target
  count, and the nested binary's page hashes were verified;
- refusing an already-signed input **before signing**, with nothing delivered,
  the original byte-identical, and later stages reported as not reached;
- refusing a bundle with no information file;
- a failed run leaving an artifact that was already at the delivery location
  untouched;
- discarding the working copy on success and on failure, measured by the
  injected root being empty;
- progress: monotonic fractions within `0...1`, one record per stage, an
  estimate that is absent or a positive whole number of seconds, and a final
  snapshot that is complete;
- verifying the delivered container again without removing it, including after
  the container is tampered with.

The host-runnable scripts in `Tests/Host/` (Mach-O signing vector, nested code
signing vector, ZIP writer vectors, external validation self-test) do not
exercise the engine directly; they cover the byte-level machinery its stages
compose.
