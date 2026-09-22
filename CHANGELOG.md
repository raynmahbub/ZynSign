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

### Notes

- Structural validity is not cryptographic validity. A `valid` structural outcome
  says nothing about signatures, entitlements, trust, or installability.
- Extracted metadata is a record of what a bundle's information file declares.
  It makes no claim that the application is signed, genuine, or installable.
- No signing, signature verification, profile parsing, Mach-O inspection,
  packaging, extraction, or installation functionality exists.
