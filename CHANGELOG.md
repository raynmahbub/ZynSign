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

### Notes

- Structural validity is not cryptographic validity. A `valid` structural outcome
  says nothing about signatures, entitlements, trust, or installability.
- No signing, bundle-metadata inspection, signature verification, packaging,
  extraction, or installation functionality exists.
