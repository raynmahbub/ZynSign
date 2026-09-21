# ZynSign

ZynSign is an independently developed application for working with iOS application
packages. It is original software, written from scratch by this project. It is not a
fork, a clone, or a derivative of any other application, and it contains no code
taken from another project.

## Current Status

**Pre-development — repository foundation only.**

This repository currently contains documentation and no more. There is no source
code, no project file, no build configuration, no automated tests, and no released
build. Nothing here runs, and nothing here can be installed.

| Area | State |
| --- | --- |
| Source code | Not started |
| Build system / project file | Not started |
| Automated tests | None |
| Dependencies | None |
| Releases | None |
| Documentation | Foundation only |

## Intended Scope

The areas below describe what ZynSign is planned to become. They are **forward
looking only**. None of them has been implemented, and none should be assumed to
work, to be safe to rely on, or to be present in this repository.

- Working with iOS application packages (`.ipa`)
- Inspecting and preparing packages for re-signing
- Signing identities, provisioning profiles, and entitlements
- Installing prepared packages onto devices
- Moving files to and from devices
- Batch processing across multiple packages

Details such as architecture, module boundaries, and public interfaces are
deliberately undecided. They will be recorded under
[`docs/architecture/`](docs/architecture/) once they are real.

## Development Approach

ZynSign is built in small, explicitly scoped increments.

- **Task-driven.** Work is delivered as numbered tasks, each with a written
  objective, an explicit scope, and a stated list of things that are *not* in
  scope. A task is complete when its own scope is satisfied — not when adjacent
  work also gets done.
- **One task per branch.** Each task is developed on its own branch and kept
  there until it is reviewed.
- **No speculative code.** Nothing is implemented ahead of the task that calls
  for it. Documentation is not written about functionality that does not exist,
  and unimplemented work is labelled as planned.
- **Verifiable increments.** Every change is accompanied by whatever check the
  project has at that point — a build, a test, or an explicit statement that no
  automated check applies.
- **Human-controlled version control.** Commits, pushes, tags, and releases are
  performed by the developer. See [CONTRIBUTING.md](CONTRIBUTING.md).

## Developer Workflow

A basic pass through the workflow looks like this:

1. **Take a task.** Read its objective, its "create" list, and its "do not"
   list.
2. **Work on the assigned branch only.** Do not create, rename, or switch
   branches while a task is in progress.
3. **Make the change.** Keep it inside the task's scope. If the scope turns out
   to be wrong, stop and raise it rather than widening it.
4. **Run the checks.** Run the project's own tests or build if any exist. If
   none apply to the change, say so explicitly instead of implying otherwise.
5. **Review the diff.** Read `git diff` end to end before anything is committed.
   Every line should trace back to the task.
6. **The developer commits.** The developer decides what is committed, what the
   message says, and when it is pushed.

## Repository Layout

```
README.md            Project overview (this file)
CHANGELOG.md         Notable changes, by release
CONTRIBUTING.md      How development work is carried out
SECURITY.md          Handling of sensitive material and responsible disclosure
docs/
  architecture/      Architectural records (none written yet)
  development/       Development guides (none written yet)
  security/          Security documentation (none written yet)
  testing/           Testing strategy and practice (none written yet)
  releases/          Release process and history (none written yet)
```

## Security

Signing-adjacent material is sensitive by nature. Read [SECURITY.md](SECURITY.md)
before contributing anything that touches keys, credentials, profiles, or device
data. Vulnerabilities are reported privately; see the same file for how.

## License

No license has been chosen for this project yet. Until one is added, the
contents of this repository are not licensed for redistribution or reuse.
