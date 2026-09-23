# ZynSign

ZynSign is an independently developed application for working with iOS application
packages. It is original software, written from scratch by this project. It is not a
fork, a clone, or a derivative of any other application, and it contains no code
taken from another project.

## Current Status

**Early development — package import, archive inspection, and library records.**

The repository contains an Xcode project with an iOS/iPadOS application target,
a SwiftUI application shell, a domain layer, and a unit-test target. The
application launches into its shell, and the Import area can bring an `.ipa`
package in through the system document picker: the selected document is staged
once into application-owned temporary storage, examined, and — if it passes —
recorded in ZynSign's library and kept across launches.

One workflow capability has a partial implementation: **inspection**, reachable
end to end through the import flow. It reads a ZIP-based package's entry table,
discovers the application bundle it contains, classifies the package's layout
against ZynSign's own structural and safety rules, and reads the metadata the
bundle declares in its bundle information file. It stops there. It does not
verify or produce signatures, does not parse provisioning profiles, does not
inspect executables, does not extract package contents, and does not install
anything. A valid result is not a statement about signatures, trust, or
installability.

Accepted imports become **library records**: the package's declared identity,
a reference to the copy ZynSign keeps in its own storage, a content
fingerprint used only to recognise the same package again, and the inspection
outcome, held in a versioned catalog inside the application container. A
record states that a package passed inspection when it was imported and which
bytes it refers to; it is not a trust statement. The **Applications area**
lists the library: it shows each record's declared metadata and the current
state of its package file, imports another package through the same
document-import workflow, and deletes a record together with the package file
behind it. From a record's detail screen, the **bundle explorer** lists the
files and folders inside the application bundle — names, locations relative to
the bundle, kinds, and the sizes the package declares — read from the
package's own entry table. It is read-only: nothing is extracted, opened,
hashed, or parsed, symbolic links are listed but never followed, and the
labels it puts on conventional locations such as `Info.plist` or
`_CodeSignature` describe what is usually found there and nothing more. It
makes no claim that any application is signed, trusted, or installable: no
application-signing, verification, packaging, or installation workflow exists.
No released build exists.

| Area | State |
| --- | --- |
| Source code | Shell UI, composition root, domain types, archive layer, inspection use cases, document-import workflow, library records and persistence, Applications library screen, bundle explorer |
| Build system / project file | Xcode project (`ZynSign.xcodeproj`): application target plus unit-test target |
| Automated tests | Unit and fixture-based tests for the domain foundation, the archive layer, the import workflow, its presentation model, the library's persistence, the library screen's presentation model, and the bundle explorer's domain, use case, and presentation model, written to run with Xcode's test runner |
| Dependencies | None — Apple frameworks and the Swift standard library only |
| Import | Partial: document selection, security-scoped staging into temporary storage, archive validation, declared-metadata extraction, library admission |
| Library | Partial: durable records for accepted imports, application-owned artifact storage, content-based duplicate recognition, missing-artifact detection, an Applications screen that lists, imports, and deletes records and opens a read-only explorer of each available package's application bundle. No repair or replacement of missing artifacts |
| Inspection | Partial: archive reading, application-bundle discovery, structural validation, declared metadata, read-only bundle structure listing. No signature examination, no file content access |
| Identity security | Explicit signature capability and experimental Keychain registry/resolver; not composed into the app, pending physical-device validation. No private-key import. The ZS-021 generic signing use case signs only through this boundary and is likewise not composed in. See [security design](docs/security/signing-identities.md) |
| Signing, verification, packaging, installation | Generic cryptographic foundation only (ZS-021): digest, signing request/result, a pure signing engine over the identity capability, and a signature-verification boundary — no application workflow, no code-signing construction, and success means only that a generic cryptographic operation completed. No packaging or installation |
| Releases | None |

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
.github/
  ISSUE_TEMPLATE/    Bug report and feature request templates
  workflows/         GitHub Actions workflow directory (no workflows yet)
  pull_request_template.md
                     Default pull request template
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
