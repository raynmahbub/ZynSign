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

It also has tests for the package import workflow:

- the import use case: a successful import returns an examined artifact with
  declared metadata and a library admission whose record refers to the
  adopted archive; importing identical content again reports the existing
  record and discards the copy; different content of the same application
  is recorded alongside; an admission failure is typed and leaves nothing
  staged or held; packages without an application, with malformed metadata,
  or with an unenumerable container are returned as typed findings whose
  staged archives are discarded; the file-type policy refuses non-`.ipa`
  input before anything is staged; staging failures propagate as typed
  errors without cleanup; cancellation during staging and cancellation after
  staging both stop the import, and the latter discards the staged archive;
- the platform intake, against containers written into a temporary
  directory: staging under artifact identifiers, unique and contained
  staged locations, readability of a staged archive through the established
  archive boundary, refusal of missing documents and directories, discard
  behaviour including discarding unknown identifiers, clearing of a
  previous process's leftovers before the first staging, and cancellation
  leaving nothing behind;
- the import error constructors: honest categories, distinct non-empty
  user messages free of detail and cause, and preserved diagnostics;
- the import presentation model: the phase machine across success,
  rejection, staging failure, import cancellation, and picker closure;
  the success summary derived from declared metadata and the library's
  decision; the library message for each admission outcome; the rejection
  message composed from the primary finding; and that the model owns no
  archive across a replaced result or its own release.

It also has tests for application persistence and library records:

- the record model and value types: construction from an accepted artifact
  only, with warning codes kept and details dropped; refusal of rejected,
  unexamined, metadata-less, and mismatched inputs; deterministic library
  order; reference content comparison; fingerprint validation,
  normalisation, hexadecimal rendering, and agreement with an independent
  SHA-256 digest; availability derivation; identifier round-tripping; value
  equality;
- the duplicate policy: byte identity regardless of declared identity,
  earliest match, precedence over declared-version relations, records
  whose artifact is not held never producing a duplicate, other-version and
  same-declared-version relations, order independence, and exact version
  comparison including undeclared values;
- the catalog-file record store, against a temporary directory: create,
  read, update, delete, idempotent deletion, insert conflicts, updates of
  unknown records, ordering, survival across a new store instance over the
  same catalog, round-tripping of every field including undeclared values,
  the catalog document's version and field set, unreadable catalogs failing
  closed and being left in place, newer schemas refused as unsupported,
  unknown and missing versions, domain-rejected values, duplicate
  identifiers, a directory at the catalog location, and a write failure
  leaving the store unchanged;
- the artifact store, against a temporary directory: size and fingerprint
  measurement with a known digest and with small read chunks, refusal of
  unstaged artifacts, adoption by move including directory creation and
  refusal to overwrite, observation of presence, size, and changes made
  behind the store's back, idempotent removal, enumeration that ignores
  entries that are not artifacts, and readability of an adopted archive
  through the archive boundary from library storage;
- the library use case, over in-memory stores: admission with record
  creation and adoption, duplicate recognition with nothing adopted, the
  other-version and same-declared-version relations, re-recording of
  identical bytes when the earlier artifact is missing, refusal of rejected
  and unstaged artifacts, cancellation before admission, rollback of the
  adopted artifact when the record cannot be written, orphan detection when
  the rollback itself fails, adoption and description failures writing
  nothing, listing with available, missing, and inconsistent artifacts,
  removal ordering and its failure mode, and orphan detection and removal;
- the library error constructors: honest categories, distinct non-empty
  user messages free of detail, cause, and trust claims, and preserved
  diagnostics;
- the archive-reader provider's ordered search: an artifact is resolved from
  the first directory that holds it, later directories are used when earlier
  ones do not, and nothing held anywhere is a typed error;
- the persistence lifecycle end to end, over the real intake, catalog store,
  artifact store, and archive-reader provider in a temporary directory:
  import, relaunch, and read back with the artifact readable from library
  storage; duplicate recognition across a relaunch; a rebuilt package kept
  alongside the original; removal for good; a missing artifact reported
  rather than recreated; stray artifacts detected and removed on request;
  and a rejected package leaving no record and no artifact.

It also has tests for bundle inspection and the bundle explorer:

- bundle paths: the root, single and nested components, case, spaces, and
  Unicode preserved, a tolerated trailing separator, agreement between the
  component and textual constructors, refusal of absolute locations,
  traversal and dot components, empty components, separators inside
  components, backslashes, NUL bytes, and over-long paths, dot-prefixed names
  as ordinary names, strict containment, validated appending, and derivation
  of bundle-relative locations from archive locations with everything
  outside the bundle refused;
- bundle contents, over synthetic entry tables and no reader at all: empty,
  single-file, nested, and multi-level bundles; directories the container
  did not record implied from the entries beneath them; empty directories
  answering empty and unknown or non-directory locations answering nothing;
  ordering with directories first and then by name, identical for forward,
  reversed, and shuffled tables; only entries strictly inside the bundle
  included, with the bundle directory itself, the payload directory, sibling
  and look-alike bundles, and package-level files excluded; every listed
  location relative, inside the root, and parented correctly; entries with
  unsafe names counted rather than listed; the first recorded entry kept for
  a duplicated location; links and unsupported entries listed with their
  kind, without a size, and not descended into; declared sizes carried for
  regular files only, including sizes near the integer maximum with a
  saturating total; unusual names carried verbatim; labels on conventional
  locations in a fixed order, absent locations simply absent, the executable
  labelled from the declared name only, and labels requiring the
  conventional depth, kind, and exact name; value equality and hashing;
- the label vocabulary: recognition rules for root-level files and
  directories and the code-signature resource record, exact-name matching,
  the required kind and depth, the executable's dependence on a declared
  name, distinct non-empty text for every label, no affirmative trust
  claims, and explicit statements of what the security-sensitive labels do
  not establish;
- the bundle inspection error constructors: honest categories, distinct
  non-empty user messages free of detail, cause, trust claims, and
  locations, and preserved diagnostics;
- the bundle inspection use case, over the real library use case with
  in-memory stores and a synthetic archive boundary: the described bundle
  with the reader closed and no content requested; no content requested
  however large the declared files; the executable labelled from the
  record's declared name; an empty bundle described as empty; a missing
  record, a missing artifact, and an inconsistent artifact each reported
  without any package being opened; a typed open failure passing through
  and a foreign one normalised without its text; an unreadable entry table
  reported with the reader closed; packages without an application bundle
  and with several reported with their categories; cancellation honoured
  before the package is opened; and a synthetic container — with a deflated
  file, nested directories, Unicode and long names, a symbolic link, an
  empty directory, an undecodable name, and a package-level file — read
  through the real artifact store and archive-reader provider in a
  temporary directory;
- the explorer presentation model and display mappings: the loading phase
  until the package is read; loaded, empty, and failed phases with the
  typed messages; retry after a failure reading the package again; loading
  again once content or an empty bundle is on screen reading nothing;
  overlapping loads reading the package once; foreign errors never rendered
  verbatim; the detail screen offering the explorer only for an available
  package; row content for directories, files, links, unsupported entries,
  and long or unusual names; root and nested listing content including
  notable entries, headers, locations, item counts, and the note on
  entries that could not be listed; and entry-detail content including the
  statements of what the explorer does not do with each kind.

It also has tests for certificate inspection:

- serial numbers, including a short value, a leading zero octet that must not
  be collapsed, and a value longer than a machine integer;
- distinguished names with several attributes, repeated organizational units,
  an unrecognised attribute, and a subject whose common name is one space;
- validity-period boundaries, including the exact start and end, against an
  injected clock rather than the system clock;
- supported and unrecognised algorithm combinations, including an EC key
  whose signature algorithm is RSA, an ECDSA signature with a P-256 key, an
  Ed25519 certificate that is parsed and not rejected, and an unknown
  signature identifier that does not hide the public-key algorithm;
- SHA-256 of the accepted certificate bytes, including known digest vectors,
  and equality of a repeated parse;
- structured failures for empty, truncated, malformed, PEM, indefinite-length,
  non-minimal, oversized, and trailing input, without echoing certificate
  bytes into the error.

It also has tests for secure identity storage:

- stable UUIDs and metadata, missing/mismatched/unsupported keys, authorization
  transitions, duplicate registration, malformed records, and removal;
- explicit message/digest algorithms, exact digest length, mock signatures,
  capability revocation, and structured failure sanitization;
- an allowlisted record schema, redacted rendering, and absence of key handles
  and raw buffers in metadata;
- pure Security error mapping tests and separate **opt-in** iOS Keychain tests
  using runtime-generated disposable keys, never stored private-key fixtures.

The [identity security design](../security/signing-identities.md) describes how
to enable the integration tests and the required physical-device experiments.
They have not been run in the Linux implementation environment. The integration
certificate helper replaces only public-key bytes in synthetic certificates;
the resulting invalid issuer signature is intentional and is not trust evidence.

Certificate fixtures are synthetic public certificates embedded as text. They
contain no private keys. Other test fixtures are generated programmatically.
No binary fixture is committed, and no real package, signing material, profile,
or production certificate appears anywhere in the suite. Filesystem-backed
tests write only into a temporary directory that the test removes.

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
