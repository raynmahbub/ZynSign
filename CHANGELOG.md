# Changelog

All notable changes to ZynSign will be documented here.

## [Unreleased]

### Added

- Initial repository foundation.
- iOS/iPadOS application foundation: an Xcode project with an application
  target and a unit-test target, a SwiftUI application shell whose future
  workflow areas are explicitly marked as not implemented, a composition root
  with a centralized dependency seam, and a minimal pure domain layer
  (application identity, workflow stages, validation classifications, and a
  structured error model). No signing, inspection, or installation
  functionality exists.
- IPA archive layer: bounded ZIP container reading behind an `ArchiveReader`
  boundary, with the concrete reader selected by the composition root and no
  third-party archive dependency.
- Application-bundle discovery over an archive entry table. Discovery is
  deterministic, independent of container entry order, and reports ambiguity
  rather than choosing between candidate bundles.
- Structural validation of an imported package's layout: payload directory,
  application bundle, bundle information file, unsafe and conflicting entry
  paths, unsupported entry forms, nesting depth, and resource-policy limits.
- Archive security protections: entry names are validated before anything is
  read; absolute, escaping, malformed, over-long, and undecodable names are
  refused; every read is bounds-checked against the container's own size; and
  entry count, entry size, total expanded size, nesting depth, expansion ratio,
  and single-read size are bounded by an explicit policy.
- Package inspection use case, which reads a container's entry table and records
  a typed structural outcome without extracting any entry and without creating
  temporary files.
- Tests covering entry validation, the resource policy, bundle discovery,
  structural validation, the inspection use case, and the ZIP reader against
  programmatically generated containers.
- Application metadata layer: a strongly typed domain model for the metadata a
  bundle declares in its bundle information file (bundle identifier, display
  name with a deterministic fallback, version and build strings, executable
  name, minimum OS version, device families, and icon name), a pure domain
  reader that extracts and validates it with structured, deterministic
  failures, and an application-layer use case that reads the one information
  file entry for an established bundle and records the outcome on the
  artifact.
- Metadata extraction: bundle identifier is required; name, version, build,
  executable, and supplementary values are optional and preserved exactly as
  declared. Malformed property lists, non-dictionary roots, wrong value types,
  missing required fields, and unsupported property list formats fail with
  typed findings rather than by guessing. Unknown keys are ignored, and the
  declared executable is resolved only when present as a regular file.
- Tests covering the metadata model, the metadata reader (valid, missing,
  mistyped, malformed, hostile, and unsupported inputs), the metadata
  inspection use case, and the extended artifact lifecycle.
- Package import workflow: user-driven selection of an `.ipa` file through
  the system document picker, restricted to the accepted package type, with
  typed outcomes for cancellation, unreachable or inaccessible files,
  staging failures, and unexpected infrastructure failures. The file-type
  policy is a cheap gate and is never trusted as evidence about content.
- Application-owned temporary staging: each selected document is copied
  once, in bounded chunks and never held whole in memory, into a unique
  location named only by the artifact's identifier; security-scoped access
  is acquired for the copy and released on every outcome. Failed, cancelled,
  and rejected imports discard the staged copy; leftovers from a previous
  process are cleared before the first import of a new process.
- Import use case that composes the existing structural and metadata
  inspection use cases over the staged archive, with an explicit staged-
  archive lifetime: rejected imports' archives are discarded before the
  result is returned, and an accepted import's archive is handed to the
  library (below), which adopts it or has it discarded.
- SwiftUI Import area with an explicit phase machine (idle, importing,
  succeeded, failed, cancelled), a success summary of the declared
  application metadata, user-facing rejection explanations composed from
  typed findings, and safe cancellation.
- Tests for the import use case (success, rejection, unreadable containers,
  file-type policy, staging failure, cancellation during and after staging),
  the platform intake against temporary directories (identifier-addressed
  staging, uniqueness and containment, readability through the established
  archive boundary, refusal of missing files and directories, discard
  behaviour, leftover clearing, cancellation cleanup), the import error
  constructors, and the presentation model's phases and staged-archive
  ownership.
- Application persistence and library records: a domain `ApplicationRecord`
  value (stable record identifier, declared identity, executable name,
  source file name, artifact reference with byte count and SHA-256 content
  fingerprint, inspection summary, import and last-updated timestamps) that
  can only be created from a package that passed inspection; an
  `ApplicationRecordStore` port (insert, update, fetch by identifier, list,
  delete) implemented as an explicitly versioned JSON catalog (`schemaVersion`
  1) in the application container's Application Support directory, replaced
  atomically on every change and failing closed on catalogs it cannot read or
  that are newer than the build; a `LibraryArtifactStore` port implemented
  over application-owned artifact storage that adopts an accepted import's
  staged archive by moving it under its artifact identifier.
- Library use case that admits accepted imports artifact-first and record-
  second, removes the adopted artifact again if the record cannot be written,
  lists records with their artifact's current availability (available,
  missing, or inconsistent — never repaired or recreated), removes an entry
  record-first and artifact-second, and detects and removes orphaned
  artifacts only on request.
- Deterministic duplicate policy: identical bytes held by an existing record
  are recognised and not recorded again, whatever the package declares;
  different bytes are always a new record, with the relation to existing
  records of the same bundle identifier (other versions, or the same
  declared version with different content) reported rather than used to
  replace anything.
- The import flow now hands accepted packages to the library, so nothing
  staged survives an import: the archive is adopted into library storage or
  discarded. The Import area states the library's decision and no longer
  describes imports as temporary.
- Tests for the record model and value types, the duplicate policy, the
  catalog-file record store (CRUD, persistence across store instances,
  ordering, catalog format, damaged and newer-schema catalogs, write
  failure), the artifact store (describing, adopting, refusing overwrites,
  observing, removing, enumerating, readability after adoption), the library
  use case over in-memory stores (admission outcomes, rollback, orphans,
  availability, removal), the import flow's library integration, the
  library error constructors, and an end-to-end persistence lifecycle over
  the real platform stores in a temporary directory.
- Applications Library screen: the Applications area of the shell lists the
  persisted records with their declared metadata and current artifact
  availability, opens a detail screen per record, imports another package
  through the existing document-import workflow with the list refreshed on
  success, and deletes a record together with the package file behind it
  through the library use case's removal operation, behind an explicit
  confirmation. Explicit loading, empty, and failure states keep an empty
  library from being presented while records are still being read and keep
  persistence failures surfaced with a retry action. The import
  presentation model gained a settlement hook so a screen embedding the
  import can react to its outcome without a second import flow.
- Tests for the library screen's presentation model over in-memory stores
  and synthetic import ports: loading into loaded, empty, and failed
  phases, retry after failure, import settlement refreshing the library,
  picker cancellation as an ordinary outcome, rejected and failed imports
  surfaced without library changes, removal with its in-flight state,
  failed deletions leaving records and announcements intact, and the row
  and detail display mappings including missing and inconsistent artifacts
  and undeclared metadata.
- Bundle explorer: a read-only browser of the files and folders inside a
  library application's bundle, reached from the application detail screen
  through an "Explore Bundle" entry that is offered only while the record's
  package is available. The explorer lists each entry's name, its location
  relative to the bundle root, its kind (folder, file, symbolic link, or
  unsupported entry), the byte count the package declares for a regular
  file, and a descriptive label on conventional locations — the bundle
  information file, the declared executable, an embedded provisioning
  profile, the code signature directory and its resource record, and the
  frameworks, plug-ins, and extensions directories — with a "Notable
  Entries" shortcut at the bundle root. Folders are entered in place;
  files open a metadata screen. Explicit loading, empty, and failure states
  with a retry action; the package is read once per visit and never again
  on view recomputation or while descending into folders.
- Bundle contents domain model: `BundlePath`, a bundle-relative location
  constructed under the same safety rules as archive paths (no absolute
  locations, no `..` or `.` components, no empty components, no NUL bytes
  or backslashes, bounded length), so nothing above the bundle root is
  representable; `BundleEntry` and `BundleEntryRole`, descriptions with no
  handle to any file; and `BundleContents`, the bundle's structure derived
  from a package's entry table — only entries strictly inside the bundle,
  directories the container did not record implied from the entries beneath
  them, deterministic ordering (folders first, then by name as Unicode
  scalars) independent of container order, first-recorded entry kept for a
  duplicated location, and entries with unsafe names counted rather than
  listed.
- Bundle contents inspection use case, composed from the existing library
  use case and the existing archive boundary over library storage — no
  second archive reader and no second artifact store. It reads a package's
  entry table only: no entry content, no extraction, no hashing, no parsing
  of any file inside the bundle. Typed errors for a record that no longer
  exists, a package the library no longer holds, a package that has changed
  since import, an unreadable container, and a package with no single
  application bundle; foreign errors are normalised so no platform text
  reaches the screen.
- Tests for bundle paths (construction, refusals, containment, derivation
  from archive locations), bundle contents (empty, single-file, nested, and
  multi-level bundles; implied directories; ordering and its independence
  from table order; the bundle boundary; unsafe names; duplicates; links and
  unsupported kinds; declared sizes including very large ones without any
  content read; unusual names; label recognition and its depth, kind, and
  exact-name rules), the label vocabulary, the inspection error
  constructors, the inspection use case (success, no content read for large
  files, executable labelling from the record, empty bundles, missing
  record, missing and inconsistent artifacts, typed and foreign open
  failures, unreadable tables, packages without or with several bundles,
  cancellation, and a synthetic container read through the platform
  boundary), and the explorer presentation model and display mappings
  (loading, loaded, empty, and failed phases; retry; idempotent and
  overlapping loads; foreign-error rendering; the detail screen's entry
  point; row, listing, and entry-detail content).

### Changed

- Staged imports are no longer retained by the presentation model. An
  accepted import's archive belongs to the library once recorded; the model
  owns no storage.
- The shell's Applications tab now shows the library instead of a
  placeholder, and the Import area, Settings, and the shell's section
  descriptions state that the Applications area lists the library.
- The application detail screen receives the bundle inspection use case
  from the library screen, which receives it from the shell; the
  application environment carries it alongside the library and import use
  cases. Settings and the shell's Applications description now state that
  the Applications area shows what each application bundle contains.

### Notes

- Structural validity is not cryptographic validity. A `valid` structural outcome
  says nothing about signatures, entitlements, trust, or installability.
- Extracted metadata is a record of what a bundle's information file declares.
  It makes no claim that the application is signed, genuine, or installable.
- A library record is not a trust statement. Its fingerprint identifies bytes
  only; declared metadata remains untrusted; no record is evidence that a
  package is signed, genuine, or installable. No key material, credentials,
  certificate bodies, or profile data are persisted.
- The bundle explorer is a listing of what a package records inside its
  application bundle. It reads the container's entry table and nothing else:
  no file is opened, previewed, extracted, hashed, or parsed, and symbolic
  links are shown as links and never followed. Its labels on conventional
  locations describe what is usually found there; the presence of a code
  signature directory, a resource record, or an embedded provisioning
  profile is a filesystem observation and is not evidence that the
  application is signed, that any signature is valid, or that the
  application is trusted or installable.
- No signing, signature verification, profile parsing, Mach-O inspection,
  packaging, extraction, or installation functionality exists. The
  Applications area lists, imports, browses, and deletes library records; it
  makes no claim about signatures, trust, or installability.
