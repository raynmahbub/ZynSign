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

The tests are written to run inside the unit-test target with Xcode's test
runner (Product ▸ Test, or `xcodebuild test` against the shared `ZynSign`
scheme). **They have not been executed yet** — the first execution is part of
reviewing the foundation work, and results will be recorded here.

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
