# Version Strategy

ZynSign follows Semantic Versioning after its first stable release. Before
that, the progression below gates each stage on evidence, not on elapsed
time. No stage is entered because the previous one "looks complete", and no
versioned release section is written in `CHANGELOG.md` for a version that
was not actually produced.

The Xcode project currently declares marketing version `0.1.0`, build `1`:
a development state. That is the only version that exists.

## Release sequence

The fixed progression from development to stable:

```
Development
└── 0.1.0-dev
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
before the progression advances. The counts are fixed: three Alphas,
four Betas, three Release Candidates, then Stable.

## Stages

### Development — `0.1.0-dev`

Internal development and testing builds. The working tree, the test suites,
and the host vector scripts are the product. Nothing is tagged and nothing
is distributed.

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

Semantic Versioning applies:

- `1.0.1` — patch, security, or bug fix;
- `1.1.0` — backward-compatible feature;
- `2.0.0` — breaking change.

## Current Position

No Alpha, Beta, RC, or stable version has been produced. The blockers are
recorded with the final-integration review: IPA packaging and the complete
application pipeline are unimplemented, no supported on-device installation
mechanism exists, and the test suites have not been executed in an
environment with the Swift toolchain. The intended progression ends at ZynSign 1.0.0 Stable. Until the exit
criteria above are met, the project stays in development and says so.
