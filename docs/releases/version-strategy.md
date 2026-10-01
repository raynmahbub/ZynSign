# Version Strategy

ZynSign follows Semantic Versioning after its first stable release. Before
that, the progression below gates each stage on evidence, not on elapsed
time. No stage is entered because the previous one "looks complete", and no
versioned release section is written in `CHANGELOG.md` for a version that
was not actually produced.

The train owns the numbers, not the prose. `ReleaseTrain.current` names the
stop; `python3 Scripts/release_train.py status` prints it next to
`MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` as the Xcode project declares
them, and `release_train.py check` fails when a tag disagrees. Marketing
versions stay purely numeric (a pre-release suffix lives only in the tag and the
release name) and every stop gets a fresh `CFBundleVersion`. No page in
`docs/releases/` restates a version it could go stale on. The build is not an
App Store submission.

The `wired · never` counts describe what is **built** into the binary; the
release train decides what a Release build **shows**. Both are true at once: a
development stop exposes the core while every feature stays compiled in.
Every stop is distributed **privately** first (TestFlight internal + sideload
IPA) and only after the private gate is green is the tag published publicly —
see [private-testing.md](private-testing.md).

## Release sequence

The fixed progression from development to stable:

```
Development
├── 0.0.1-dev.1
├── 0.0.1-dev.2
├── 0.0.1-dev.3
└── 0.0.1            (the first build)
Alpha
├── 0.1.0-alpha.1
├── 0.1.0-alpha.2
└── 0.1.0-alpha.3
Beta
├── 0.9.0-beta.1
├── 0.9.0-beta.2
├── 0.9.0-beta.3
└── 0.9.0-beta.4
Release Candidate
├── 1.0.0-rc.1
├── 1.0.0-rc.2
└── 1.0.0-rc.3
Stable
└── 1.0.0
```

Each stage below defines what its builds establish and what must hold
before the progression advances. The counts are fixed: three development
stops, three Alphas, four Betas, three Release Candidates, then Stable.

## Feature rollout

The app is fully built, and its features are released gradually along this
sequence. [release-train.md](release-train.md) says which features each tag
switches on (0.0.1 core → alpha.1 Certificate Studio → alpha.2 Smart Sign →
alpha.3 App Store + Downloads → beta.1 the rest, feature complete). It also
covers how `ReleaseTrain.swift` and `Scripts/release_train.py` keep the code,
`MARKETING_VERSION`, and the tag in step. Marketing versions stay numeric
(`0.0.1` for the development stops and the first build, `0.1.0` for the alphas,
`0.9.0` for the betas, `1.0.0` for the RCs), and
`CFBundleVersion` increases with every release.

## Stages

### Development — `0.0.1-dev.N` → `0.0.1`

Internal development and testing builds. The working tree, the test suites,
and the host vector scripts are the product.

Three development stops run before the first build. They switch on **no** new
staged feature of their own: their job is to prove the release pipeline end to
end — quality gate → build + tests → version-stamped assets → publish — against
a real tag, before the signing surface is exposed publicly. A Release build of a
development stop shows the core — Files, Import, Library, Bundle Explorer, Home,
Settings — and, from `dev.3` on, the whole six-tab shell, because a hidden tab
reads as a lost feature. The gate closes staged *work*, not navigation, and the
entry-point map in [release-train.md](release-train.md) is the authority on
which checks are live. A Debug build exposes every feature, so development and
UI work are never blocked, and `-ZynSignReleaseStage <stage>` previews any later
stop.

The first build is `0.0.1`: market `0.0.1`, `10 wired · 3 never` — the delivery
hand-off and the local activity journal are among the wired rows; in-app
installation, Pairing/JIT/Mux, and off-device measurement stay claimed-never. It
is built once and distributed **privately** first (TestFlight internal / ad-hoc
IPA, see [private-testing.md](private-testing.md)); after the private matrix is
green the same commit is tagged `v0.0.1` and published for
sideloading/TestFlight. It is not App Store signed.

### Alpha — `0.1.0-alpha.N`

Core functionality and major real-world compatibility discovery. Three
Alphas are planned: `0.1.0-alpha.1`, `0.1.0-alpha.2`, and `0.1.0-alpha.3`.

Alpha exits to Beta when all of the following hold:

- the core workflow operates correctly: IPA import, archive validation,
  metadata extraction, library, signing for supported artifacts,
  verification, and IPA packaging;
- the security-critical tests pass;
- no Critical security issue remains;
- no known source-artifact corruption exists;
- the CI quality gates pass on hosted infrastructure;
- known limitations are documented.

### Beta — `0.9.0-beta.N`

Feature-complete and focused on compatibility, stability, security,
performance, and real-world artifact testing. The first Beta is
`0.9.0-beta.1`; further Betas are cut only when a genuine Beta-level change
requires another build — never merely because time has passed.

Beta exits to Release Candidate when all of the following hold:

- the major features are complete;
- repeated signing and export cycles are stable;
- representative IPA structures, nested code, provisioning configurations,
  malformed artifacts, and large artifacts have been tested;
- the security regression tests pass;
- no release-blocking High or Critical issue remains;
- installation limitations are documented;
- CI remains green.

### Release Candidate — `1.0.0-rc.N`

Each RC is the exact candidate intended for the stable release. The first
is `1.0.0-rc.1`; a further RC is produced only when a genuine
release-blocking issue is found and fixed. Tests are never weakened to make
an RC pass.

Before `1.0.0`, all of the following hold:

- the final feature set is frozen;
- no known release-blocking defect remains;
- the security review is complete;
- the complete test suite passes;
- the final IPA workflow passes, including independent verification and
  packaging round-trip verification of the exact artifact being released;
- documentation and `CHANGELOG.md` are complete;
- version metadata is consistent across the project, the documentation,
  and the release notes;
- known limitations are documented.

### Stable — `1.0.0`

The final target. It requires:

- feature completeness;
- end-to-end workflow success;
- independent verification;
- security regression success;
- CI quality-gate success;
- no known Critical or High release-blocking security defect;
- no known data-loss or artifact-corruption defect;
- documented platform and installation limitations;
- completed release documentation.

## After 1.0.0

`2.0.0` (“Professional Platform”) deepens the 1.0 surface without adding a
release gate. `3.0.0` (“Nova”) is the complete-platform release: `3.0.0-nova.1`
previews the Nova Assistant on the Smart Workspace home that shipped in RC 2,
and `3.0.0` switches on the remaining areas in [../product/ROADMAP-v3.0-nova.md](../product/ROADMAP-v3.0-nova.md).
Both are stages on the same train (`ReleaseStage.professional`, `.nova1`,
`.nova`); the marketing version stays numeric (`2.0.0`, `3.0.0`).

Semantic Versioning applies:

- `1.0.1` — patch, security, or bug fix;
- `1.1.0` — backward-compatible feature;
- `2.0.0` — breaking change.

## Current Position

This section does not restate the stop, for the reason given at the top of this
file. `python3 Scripts/release_train.py status` prints the current stop beside
`MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` exactly as the Xcode project
declares them, and `python3 Scripts/release_train.py check` fails when a tag
disagrees with the tree. Writing the stop down here is precisely how this page
came to assert `v0.1.0-alpha.3`, market `0.1.0`, build `2` and
`ReleaseTrain.current = .alpha3` while the source said otherwise — prose
outliving code, which the rule above forbids. It is removed rather than
corrected, so it cannot go stale a second time.

What is true at every stop, and so is safe to write: every feature stays
compiled in and visible in a Debug build whatever a Release build shows; the
private binary and the public release are the same binary, with no rebuild
between them; distribution is TestFlight internal or an ad-hoc IPA rather than a
public App Store submission; and each tag is gated by the device matrix in
[private-testing.md](private-testing.md).

Of the blockers recorded with the final-integration review, three have
changed since:

- IPA packaging and the complete application pipeline exist: the pipeline is
  composed in the application environment and reachable from
  `Library`/`Application Detail` and `Settings → Certificates`.
- Certificate import via `SecPKCS12Import` (`.p12`/`.pfx`) and the `tipa` alias
  are now composed and covered by the interface.
- The test suites pass on hosted CI, on a simulator, which is not device evidence; external validation (ZS-031) still shows Apple's desktop verifier accepts ZynSign's single-image signatures but rejects the pipeline's bundles, and the signature format fails the requirements Apple documents for iOS 15 and later ([external-validation.md](../architecture/external-validation.md)). "Signing for supported artifacts" and "verification" in the Alpha criteria are therefore not established.

Installation remains unavailable: no supported arbitrary-IPA installation mechanism is available to an iOS/iPadOS application, and the pure installation assessment reports installation as unavailable with exact limitations (see [installation-compatibility.md](../architecture/installation-compatibility.md)). Whether installation belongs in a release is unresolved (architecture decision 24). ZynSign is honest about that limitation and about the facts that its synthetic `empty` entitlements are only compatible with the test fixture profile, that no App Store submission is attempted, and that on-device signing of real developer identities and profiles has not yet been demonstrated until the private device matrix passes (see private-testing.md).

Alpha exits when the criteria above hold; until they do, the project stays in development and says so. The next step is device validation of certificate import, `tipa` handling, and single-target signing with real provisioning profiles — exactly the private matrix in [private-testing.md](private-testing.md).
