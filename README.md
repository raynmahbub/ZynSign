# ZynSign

ZynSign is an independently developed application for working with iOS application
packages. It is original software, written from scratch by this project. It is not a
fork, a clone, or a derivative of any other application, and it contains no code
taken from another project.

## Current Status

**Development — import, inspection, and library in the application; signing
pipeline, packaging, and verification below the interface; no signing
interface, no installation, no release.**

The repository contains an Xcode project with an iOS/iPadOS application target,
a SwiftUI application shell, domain, application, platform, and presentation
layers, and a unit-test target. The application launches into its shell, and
the Import area can bring an `.ipa` package in through the system document
picker: the selected document is staged once into application-owned temporary
storage, examined, and — if it passes — recorded in ZynSign's library and kept
across launches.

One workflow capability is reachable end to end through the interface:
**import, inspection, and library**. It reads a ZIP-based package's entry
table, discovers the application bundle it contains, classifies the package's
layout against ZynSign's own structural and safety rules, reads the metadata
the bundle declares in its bundle information file, and records accepted
packages as library records. A valid inspection result is not a statement
about signatures, trust, or installability.

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
makes no claim that any application is signed, trusted, or installable.

Below the interface, and not reachable from any screen, the repository also
holds: certificate inspection and signing-identity models with an experimental
Keychain registry that is not composed into the application; a
provisioning-profile pipeline (payload parsing, CMS container verification,
policy validation, and one staged integration over all three, including a
read-only intake for a bundle's embedded profile); a read-only Mach-O
code-signature inspector behind an opt-in use case; and an experimental
signing stack (generic cryptographic foundation, CodeDirectory construction,
SuperBlob construction, signature-region framing, single-image signing with
independent post-sign verification, dependency-aware nested signing, and the
entitlements/requirements/CodeResources metadata layer); a nine-stage
application-signing pipeline that runs integrity, profile, discovery,
extraction, nested signing, resource sealing, main-executable signing,
packaging, and independent verification in fixed order and delivers
nothing when any stage refuses; a deterministic packaging writer and a
safe archive extractor behind new archive ports; and a pure
installation-capability assessment. The pipeline, the packager, and the
verifier are constructed at the composition root and covered by unit
tests, but none is installed in the application environment: there is no
signing interface, no installation mechanism, and no released build.

| Area | State |
| --- | --- |
| Source code | Shell UI, composition root, domain/application/platform types, archive layer, inspection use cases, document-import workflow, library records and persistence, Applications library screen, bundle explorer, certificate and identity foundation, provisioning-profile pipeline, Mach-O inspection, experimental single-image and nested signing with signing metadata |
| Build system / project file | Xcode project (`ZynSign.xcodeproj`): application target plus unit-test target |
| Automated tests | Unit and fixture-based tests across the domain foundation, archive layer, import workflow and presentation models, library persistence and screens, bundle explorer, certificates and identities, provisioning profiles and policy, Mach-O parsing and signing, nested discovery and signing, and signing metadata, written to run with Xcode's test runner; plus host vector scripts under `Tests/Host` |
| Dependencies | None — Apple frameworks and the Swift standard library only |
| Import | Partial: document selection, security-scoped staging into temporary storage, archive validation, declared-metadata extraction, library admission |
| Library | Partial: durable records for accepted imports, application-owned artifact storage, content-based duplicate recognition, missing-artifact detection, an Applications screen that lists, imports, and deletes records and opens a read-only explorer of each available package's application bundle. No repair or replacement of missing artifacts |
| Inspection | Partial: archive reading, application-bundle discovery, structural validation, declared metadata, read-only bundle structure listing. No signature examination, no file content access |
| Provisioning profiles | Application layer only: payload parsing, CMS container verification, policy validation, and a staged integrated pipeline with a read-only embedded-profile intake. No trust evaluation, no authorization, no interface. See [security design](docs/security/provisioning-profiles.md) |
| Identity security | Explicit signature capability and experimental Keychain registry/resolver; not composed into the app, pending physical-device validation. No private-key import. The generic signing use case signs only through this boundary and is likewise not composed in. See [security design](docs/security/signing-identities.md) |
| Signing and verification | Below the interface: single-image and nested Mach-O signing with independent post-sign verification and per-target metadata, composed into a nine-stage application pipeline with independent container verification. Built at the composition root and covered by unit tests; no signing interface until device validation completes |
| Packaging and extraction | Below the interface: deterministic packaging through a validated entry set and a stored-only ZIP writer, and safe extraction with confinement and an explicit link policy. Built at the composition root; no interface |
| Installation | None. No supported arbitrary-IPA installation mechanism is available to the application on iOS/iPadOS; a pure capability assessment reports installation as unavailable with exact limitations. See [installation and compatibility](docs/architecture/installation-compatibility.md) and [application signing pipeline](docs/architecture/application-signing-pipeline.md) |
| Releases | None |

## Intended Scope

The areas below describe what ZynSign is intended to become. Import,
inspection, and the application library exist in the application; signing,
verification, and packaging exist below the interface, and installation
does not exist at all. Nothing below should be assumed to work end to
end, to be safe to rely on, or to be present as a finished workflow.

- Working with iOS application packages (`.ipa`)
- Inspecting and preparing packages for re-signing
- Signing identities, provisioning profiles, and entitlements
- Verifying produced signatures independently of signing
- Rebuilding signed packages deterministically
- Installing prepared packages onto devices, where a supported mechanism exists

Architecture, module boundaries, and public interfaces are recorded under
[`docs/architecture/`](docs/architecture/) as they become real. Open
platform questions stay open there until they are demonstrated on a
supported deployment target.

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
  workflows/         GitHub Actions workflows (build, test, hygiene)
  pull_request_template.md
                     Default pull request template
docs/
  architecture/      Architecture records, feasibility research, and design notes
  development/       Development guides (toolchain, continuous integration)
  security/          Security designs and the release security review
  testing/           Testing strategy, practice, and per-increment check records
  releases/          Release process, version strategy, and history (no releases yet)
```

## Security

Signing-adjacent material is sensitive by nature. Read [SECURITY.md](SECURITY.md)
before contributing anything that touches keys, credentials, profiles, or device
data. Vulnerabilities are reported privately; see the same file for how.

## License

No license has been chosen for this project yet. Until one is added, the
contents of this repository are not licensed for redistribution or reuse.
