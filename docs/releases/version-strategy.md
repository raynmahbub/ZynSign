# Version Strategy

ZynSign uses an ordered release train before `1.0.0`, then Semantic Versioning. A stage advances only when its evidence and exit criteria are met—not because time passed. The source of truth is `ReleaseTrain.current` in [`ZynSign/Application/ReleaseTrain.swift`](../../ZynSign/Application/ReleaseTrain.swift); `Scripts/release_train.py` derives the tag, marketing version, and build number from it.

Marketing versions remain numeric for Apple (`0.0.1`, `0.1.0`, `0.9.0`, `1.0.0`); pre-release suffixes live in the Git tag and GitHub Release. Each promoted stop advances `CURRENT_PROJECT_VERSION`. Inspect the current values with:

```sh
python3 Scripts/release_train.py status
```

## Ordered progression

```text
Development: 0.0.1-dev.1 → 0.0.1-dev.2 → 0.0.1-dev.3 → 0.0.1
Fixes-only:  0.0.2-dev.1
Alpha:       0.1.0-alpha.1 → 0.1.0-alpha.2 → 0.1.0-alpha.3
Beta:        0.9.0-beta.1 → 0.9.0-beta.2 → 0.9.0-beta.3 → 0.9.0-beta.4
RC:          1.0.0-rc.1 → 1.0.0-rc.2 → 1.0.0-rc.3
Stable:      1.0.0
Professional: 2.0.0
Nova:        3.0.0-nova.1 → 3.0.0
```

The train lists new feature exposure per stop in [release-train.md](release-train.md). Later stops accumulate earlier capabilities. The Features catalogue under Settings reports availability from the train; Debug builds may expose later-stage code for development, while Release builds follow the current stage.

## Stage exit criteria

### Development

Prove the release pipeline, core package import and inspection, storage safety, and required device matrix. Development stops do not imply a feature or device workflow has passed merely because the app compiles. `0.0.2-dev.1` is a fixes-only follow-up; it introduces no new `ReleaseFeature`.

### Alpha

Validate the major signing workflow with real artifacts, certificates, and provisioning profiles. Before Beta:

- IPA/TIPA intake, archive validation, metadata extraction, signing, independent verification, and packaging work on supported device/OS combinations.
- Security-critical tests pass and no Critical issue remains.
- Malformed and representative nested artifacts are handled safely.
- Known platform limits and recovery paths are documented.
- CI and the required private device matrix pass.

### Beta

Feature-complete; focus on compatibility, stability, security, performance, and representative real-world packages. Before RC:

- Repeated signing, export, and verification cycles are stable.
- Representative bundle layouts, nested code, profiles, malformed inputs, and large inputs have been exercised.
- No release-blocking High or Critical defect or known data-loss/artifact-corruption issue remains.
- Device matrix, regression tests, and CI are green; platform limitations are explicit.

### Release Candidate

An RC is the exact candidate intended for stable. Produce another RC only for a release-blocking change. Before `1.0.0`, freeze the feature set; complete security review; pass the complete test suite and private device matrix; verify the exact artifact and packaging round trip; reconcile release notes and version metadata; and document remaining limitations.

### Stable

`1.0.0` requires feature completeness, end-to-end and device-level workflow success, independent verification, security-regression success, green CI, no known release-blocking High/Critical defect or data-loss/corruption issue, and complete release documentation. Unsupported iOS capabilities remain explicitly unsupported rather than being represented as install success.

## After 1.0.0

- `2.0.0` deepens the professional platform without introducing a new release gate.
- `3.0.0-nova.1` previews Nova Assistant; `3.0.0` completes the [Nova roadmap](../product/ROADMAP-v3.0-nova.md).

After stable, use SemVer: patch for compatible fixes/security updates, minor for backward-compatible features, and major for breaking changes. The release train still validates each permitted stop.

## Promote and publish

```sh
python3 Scripts/release_train.py status
python3 Scripts/release_train.py promote            # next permitted stop
python3 Scripts/release_train.py promote alpha2     # named stop, if permitted
python3 Scripts/release_train.py check --tag v0.1.0-alpha.1
```

Review and commit the source changes before tagging. Follow [private testing](private-testing.md) and [release automation](release-automation.md): rehearse with `dry_run: true`, inspect the generated assets, publish only the current stop, and review the resulting changelog PR. A successful build or CI run is not proof of physical-device signing or installation behavior.
