# Contributing to ZynSign

ZynSign is developed as a sequence of small, well-defined tasks. This document
describes how that work is carried out, reviewed, and recorded.

## Project State

The project is in development: an Xcode project with an iOS/iPadOS
application target and a unit-test target, a SwiftUI shell with working
import, inspection, and library areas, signing foundations below the
interface, and a continuous-integration workflow definition. The
expectations below apply to all work; where the toolchain is unavailable in
an environment, that is stated explicitly instead of implied otherwise.

## Focused Development Tasks

Work arrives as discrete tasks. Each task should state:

- **Objective** — the single thing the task accomplishes.
- **Create / change** — the concrete artifacts the task produces.
- **Strict scope** — an explicit list of what the task must *not* do.
- **Validation** — how the result is checked.

Follow these rules while working:

- Do one task at a time. Do not pull adjacent work into the current task.
- Treat the "strict scope" list as binding. An item listed as out of scope is
  out of scope even if it looks trivially related.
- If a task's scope is wrong, incomplete, or contradicts itself, stop and raise
  it. Do not quietly widen the scope to make the task pass.
- Do not implement functionality the task did not ask for.
- Do not document functionality as existing unless it exists.

## Branch-Based Development

- Each task is developed on its own branch, kept isolated from other work.
- Work on the branch assigned to the task. Verify the current branch before
  starting (`git branch --show-current`).
- Do not create, rename, delete, or switch branches in the middle of a task. If
  the branch does not match the assignment, report the mismatch rather than
  fixing it yourself.
- Keep branches short-lived. A branch that has drifted far from its task is a
  signal the task was scoped too broadly.

## Testing Expectations

- Run whatever checks exist for the area you changed: the project's tests, its
  build, or the entry point that actually reaches the change.
- Report what you ran and what it returned. Name the function, path, or code
  that was executed. A clean exit code on a check that never touched the change
  is not a verification.
- If no automated check applies — for example, a documentation-only task —
  state that plainly rather than implying tests were run.
- If a required tool is unavailable in your environment, say so. Do not claim a
  build or test was performed when it was not.
- A failing or surprising result is the answer. Fix it and run again; do not
  report around it.
- As the codebase grows, new functionality is expected to arrive with tests.

## GitHub Issues and Pull Requests

GitHub issue and pull request templates are provided under `.github/` to keep
reports concise and reviewable.

- Use the bug report template for reproducible, non-security problems.
- Use the feature request template for proposed improvements. Feature requests
  are reviewed for fit and feasibility, but they are not a promise that the
  feature will be implemented.
- Use the pull request template to summarize the change, list important changes,
  and report only the testing and validation that were actually performed.
- Do not include passwords, private keys, certificates containing sensitive
  material, provisioning profiles containing sensitive information,
  authentication tokens, or other secrets in issues, pull requests, logs, or
  screenshots.
- Report security vulnerabilities privately, as described in
  [SECURITY.md](SECURITY.md), rather than opening a public issue.

## Code Review

Every change is reviewed by the developer before it lands. Review covers:

- **Correctness** — does the change do what the task asked, and nothing more?
- **Scope** — is anything present that the task did not call for?
- **Honesty** — do the claims in code, docs, and the task report match what was
  actually built and verified?
- **Consistency** — does the change follow existing conventions in structure,
  naming, and style?
- **Safety** — see [SECURITY.md](SECURITY.md). Sensitive material must not be
  introduced, logged, or committed.

## Diff Review

Read the diff before anything is accepted:

```
git status
git diff --stat
git diff
```

Confirm that:

- only files the task called for were added or modified;
- no unrelated, generated, or scratch files were left behind;
- no secrets, credentials, tokens, private keys, or device data appear anywhere
  in the diff;
- documentation describes only what exists, with planned work clearly marked as
  planned.

A diff that cannot be explained line by line is not ready.

## Conventional Commits

Commit messages follow [Conventional Commits](https://www.conventionalcommits.org/):

```
<type>(<optional scope>): <short description in imperative mood>
```

Common types:

| Type | Use |
| --- | --- |
| `feat` | New user-facing functionality |
| `fix` | A bug fix |
| `docs` | Documentation only |
| `test` | Adding or correcting tests |
| `refactor` | Code change that neither fixes a bug nor adds a feature |
| `chore` | Repository tooling and maintenance |
| `ci` | Continuous integration configuration |

Conventions:

- Keep the subject line short, lowercase after the colon, imperative mood, no
  trailing period.
- One logical change per commit.
- Use the body for the why, and for anything a reviewer could not infer from
  the diff.
- Reference the task where one exists.

## Developer-Controlled Git Workflow

All of the following are performed by the developer, and only by the developer:

- creating commits;
- pushing to any remote;
- creating, moving, or deleting branches;
- creating, moving, or deleting tags;
- opening pull requests and merging them;
- creating releases.

The agent's role is to make the change in the working tree, run the available
checks, and report exactly what was changed and what was verified. It may
suggest a commit message; the developer decides whether to use it. Work is left
in the working tree, uncommitted, for the developer to inspect and commit.

## Reporting Work

A task report should cover, at minimum:

- **Changed** — the files added or modified, and why.
- **Tests** — what was run and what it returned, or an explicit statement that
  no automated check applies.
- **Validation** — the checks performed against the task's requirements.
- **Diff Review** — the result of reading the diff.
- **Documentation** — what was documented, and confirmation that no
  unimplemented functionality is described as working.
- **Recommended Commit** — a suggested Conventional Commit message.
- **Git** — confirmation that no commit, push, tag, or release was created.

Report what actually happened, including gaps and things that could not be
checked. An honest gap is useful; a guessed result presented as verified is not.
