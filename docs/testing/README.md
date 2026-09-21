# Testing Documentation

Testing strategy and practice for ZynSign will be recorded here.

## Current State

**There is no test suite and no automated tests.** ZynSign is in a pre-development
state and contains documentation only, so there is no code under test and no test
tooling configured.

No tests were run for the work that created this directory, because there is
nothing yet that a test could exercise.

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
