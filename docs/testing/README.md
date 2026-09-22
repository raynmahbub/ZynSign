# Testing Documentation

Testing strategy and practice for ZynSign will be recorded here.

## Current State

The repository has a unit-test target (`ZynSignTests`) with pure tests for the
domain foundation:

- bundle identifier validation rules;
- application identity construction, including its typed error;
- the structured error model (user-presentable message, diagnostic rendering,
  underlying-cause preservation, stable categories);
- workflow stage set and pipeline order;
- validation classification rules, including that only a `valid`
  classification proceeds to later stages;
- resolution of the application's own descriptive information.

It also has tests for the archive layer:

- archive entry construction, name acceptance, and diagnostic name sanitisation;
- the resource policy, including that its comparisons do not overflow on
  hostile declared sizes;
- application-bundle discovery, including determinism, missing payloads,
  missing bundles, ambiguity, nested and misplaced bundles, and containers that
  omit directory entries;
- structural validation, including the classification precedence rules and the
  bound on findings recorded for one issue;
- the inspection use case, including that it reads no entry content, that it
  closes its reader on every path, and that it does not copy arbitrary platform
  error text into findings;
- the ZIP container reader, against containers generated in memory by the test
  fixture builder, covering valid packages, unreadable and damaged containers,
  unsafe entry names, entry kinds, duplicates, the entry-count policy, bounded
  reads, checksum failure, and reader lifecycle.

It also has tests for the application metadata layer:

- the metadata model: the display-name fallback policy, preservation of
  declared values, device-family interpretation including unknown values, and
  value equality;
- the metadata reader, against property lists generated in memory and written
  by hand, covering complete and partial metadata, missing required and
  optional fields, wrong value types, non-dictionary roots, malformed and
  truncated property lists, unsupported property list formats, unknown keys,
  and hostile declared values;
- the metadata inspection use case, including that it reads exactly the
  bundle's information file, that it closes its reader on every path, that a
  failed metadata examination invalidates a structurally valid artifact, that
  declared executables are resolved only when present as regular files, and
  that foreign failure text is not copied into findings;
- the extended artifact lifecycle, including the metadata-examination
  transitions and the updated issue-code set.

Test fixtures are generated programmatically. No binary fixture is committed,
and no real package, signing material, profile, or certificate appears anywhere
in the suite. Filesystem-backed tests write only into a temporary directory that
the test removes.

The tests are written to run inside the unit-test target with Xcode's test
runner (Product ▸ Test, or `xcodebuild test` against the shared `ZynSign`
scheme). **They have not been executed yet.** The checks that have actually been
run against this code are recorded with the work that produced it, and none of
them constitutes an executed test run.

## Expectations Today

Until a test suite exists, the expectations in
[CONTRIBUTING.md](../../CONTRIBUTING.md) apply:

- Run whatever checks exist for the area you changed.
- Report what you ran and what it returned, naming the code path that was
  actually executed.
- If no automated check applies, say so explicitly instead of implying that
  tests were run.
- If a required tool is unavailable, say so. Do not claim a build or test was
  performed when it was not.
- A failing or unexpected result is the answer — fix it and run again.

## What Will Live Here

Once code exists:

- The testing approach and the layers it covers.
- How to run the suite, and how to run a single test.
- Conventions for fixtures and test data.
- What is expected of new functionality before it lands.

## Test Data

Test data must be synthetic. Never use real signing material, credentials,
private keys, provisioning profiles, real bundle or team identifiers, device
identifiers, or user data. See [SECURITY.md](../../SECURITY.md).

## Index

No documents yet.
