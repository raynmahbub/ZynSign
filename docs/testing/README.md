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

It also has tests for the provisioning-profile payload pipeline:

- the typed profile model: optional metadata, platform values including unknown
  values, exact full application identifiers, explicit prefix/component
  separation, wildcard components, team identifiers, flags, classifications,
  device identifiers, and certificate references;
- the property-list payload parser, over synthetic binary payloads, covering
  minimal and optional profiles, unknown fields, malformed and truncated
  payloads, non-dictionary roots, wrong types, empty-versus-missing arrays,
  strings, booleans, integer and real numbers, data, dates, nested arrays and
  dictionaries, resource bounds, date ordering, and redacted failures;
- application-identifier handling, including prefix mismatch, no-prefix
  non-inference, and wildcard preservation;
- certificate references, multiple entries, optional attachment of the
  existing certificate metadata model, and malformed certificate values;
- injected-clock validity boundaries for malformed, not-yet-valid,
  currently-valid, and expired profiles; missing required metadata; and
  conservative development, ad hoc, App Store, enterprise, and unknown
  classification;
- the application inspection use case, including the raw-input decoder seam,
  empty and oversized input rejection before decoding, foreign-error
  sanitization, explicit `notEvaluated` authenticity/authorization state, and
  deterministic synthetic payload results.

The profile parsing suite does not use device authorization APIs, inspect
embedded profile archive entries, persist profile bytes, or exercise signing.
Those tests belong to later trust, authorization, and signing increments.

It also has tests for provisioning-profile CMS verification:

- the bounded SignedData reader, over synthetic containers: content type,
  version, declared digest algorithms, encapsulated content and its exact byte
  range, certificate-bag encodings in bag order, revocation entry count, signer
  version and identifier form, signed-attribute identifiers, the message-digest
  value, and the re-encoded `SET OF` attribute bytes a signature covers;
- structural refusals: empty, oversized, PEM-armored, non-CMS, unsupported
  content type, indefinite-length, truncated, and trailing-data input, each as a
  typed CMS failure with redacted detail — and, separately, tampered containers
  that still read as structures, because detecting tampering is verification's
  job and not the reader's;
- the verification boundary with a recording signature double: signer
  certificate selection by serial, independence from bag order, unparsable bag
  entries counted rather than fatal, ambiguous and subject-key-identifier
  signers reported instead of resolved, missing embedded certificates,
  message-digest binding checked before any signature check, tampered payload
  and tampered digest rejected without reaching the mechanism, tampered
  signature rejected by it, algorithm mapping for RSA and ECDSA and preservation
  of unsupported pairs, no-signer and multiple-signer outcomes, mechanism
  unavailability reported as unavailable rather than as a mismatch, and foreign
  failures reduced to a CMS reason;
- the CMS vocabulary itself: digest recognition, algorithm-pair mapping, status
  classification into verified, rejected, and unevaluated, signer-certificate
  states, identifier redaction, signed-attribute observation defaults, every
  failure reason's category and user message, and payload authenticity per
  outcome;
- certificate relationship analysis: fingerprint matching, mismatching,
  ambiguity, incomparability when a profile carries no parseable certificate
  references, duplicate and reordered entries, the rule that a certificate
  sharing the signer's exact subject but holding a different key does not match,
  and the four local-identity outcomes including key availability reported
  separately from a match;
- the verification use case: parsing only after a verified signature, the five
  states kept apart in one result, an authentic but structurally invalid
  profile, a mismatch between signer and profile certificates that does not
  change CMS authenticity, an identity store consulted read-only so that no
  signing capability is ever requested, an unreadable store recorded as a failed
  lookup rather than propagated, foreign CMS failures sanitized, and diagnostics
  that carry states and fingerprints but no payload bytes.

Signature mathematics over real fixture bytes lives in a separate iOS-gated
suite, because the primitives it uses do not exist on other platforms: accepted
RSA and ECDSA signatures, tampered signatures and wrong certificates rejected
as `false` rather than as errors, unsupported algorithm pairs and key/algorithm
mismatches reported as unsupported, empty message, signature, and certificate
encodings reported as typed failures, platform status mapping that separates a
mismatch from an unavailable mechanism, and the composed boundary over the same
fixtures. That suite needs no signed host, no keychain, and no private key.

It also has tests for provisioning-profile policy validation (ZS-019):

- the identifier rule, in isolation: exact scope, wildcard scope at a component
  boundary, an identifier that is outside it, a bare wildcard, the scope a
  wildcard declares, full values without a declared prefix where only text
  equality is decisive, claims carrying a different prefix, claims that cannot
  widen the scope by carrying structure of their own, and the application
  identifier a bundle identifier would take under a declared prefix;
- the typed entitlement comparator: matching and conflicting strings, booleans,
  integers, and reals; integers and reals not coerced into each other; identical,
  superset, and reordered sequences; nested dictionaries compared for the keys
  the request claims; unsupported data and date values; a bounded nesting depth;
  missing claims and missing allowlists; the special keys refused by the generic
  rules; and deterministic key order;
- the validator over synthetic domain values: a fully satisfied configuration,
  declaration order of categories, the authenticity gate for unevaluated and
  rejected containers, validity states and inclusive boundaries against the
  injected clock, established, unknown, and unintended profile classes, exact
  and wildcard bundle-identifier outcomes including an unsplittable identifier,
  team matching from structured organizational units, certificate match, identity
  certificate mismatch, a container signer outside the profile's certificates,
  unavailable keys and unready capabilities, entitlement matches, conflicts,
  unsupported values, absent and contradicted `get-task-allow`, platform support
  and non-support, device provisioning with and without a trustworthy identifier,
  an inconsistent all-devices declaration, several failures in one result,
  determinism, non-mutation of the inputs, redacted diagnostics, and the rule that
  trust stays `notPerformed` and authorization stays `notEvaluated` while policy
  compatibility is decided;
- the application-layer use case: a compatible request reported as such, identity
  metadata resolved without ever requesting a signing capability, an identity the
  store does not list, an unreadable store recorded as a failed lookup rather than
  as a profile defect, a request that names no identity, a request that names one
  with no store available, an unauthenticated container reported as indeterminate
  instead of throwing, a rejected container reported as incompatible, a policy
  failure on an authenticated profile, platform and device context passed through,
  and a presentation-safe summary that carries only non-satisfied categories and
  no identifiers, fingerprints, or values.

These suites use synthetic profiles, certificates, identity metadata, and
configuration values; they touch no device authorization API, no keychain, no
network, and no real signing material, and they assert that no signing capability
is requested on the policy path. Like the rest of the target, they were written
but not executed in the environment where they were produced.

It also has tests for the integrated provisioning-profile pipeline (ZS-020):

- the successful run, over the committed synthetic CMS containers with the real
  container boundary, parser, structural validator, relationship analyzer, and
  policy validator and only the signature mechanism doubled: every stage reported
  `passed`, no finding at all, the parsed profile's own metadata reachable through
  the result, the signer fingerprint and correspondence, the evaluation instant
  from the injected clock, and the presentation summary stating discovery,
  authentication, parsing, structural validity, validity, correspondence, and
  policy compatibility separately;
- the security order: an authenticated but structurally invalid profile stays
  authenticated and becomes invalid; a rejected signature leaves the payload
  unparsed, makes the policy stage report its authenticity gate rather than any
  authorization, and is never a `valid` result; a tampered payload is refused before
  the signature mechanism is consulted; a missing verification mechanism stays
  `indeterminate` and never becomes a defect in the user's profile; a container that
  cannot be decoded at all stops at the container stage with no policy evaluation;
  an unsupported algorithm is reported `unsupported`, and armored input is
  unsupported rather than invalid;
- the certificate boundary: a signer outside the profile's own certificate set
  leaves the relationship stage reporting its answer while the integrated status
  stays `indeterminate`, an unrelated signing identity is reported as a policy
  violation rather than as compatible, an unreadable identity store leaves the
  identity question open without damaging the profile, and no signing capability is
  requested on any path;
- policy propagation: a bundle-identifier mismatch, an unapproved entitlement, an
  expired profile, and several simultaneous failures each arrive with the code the
  policy stage used, and a requested value never reaches a finding, a diagnostic, or
  a summary reason;
- input states: an absent profile, an unreadable entry, an empty file, and an
  oversized input are four distinct results with four distinct codes, none of them an
  "invalid application" catch-all, and an absent or unreadable profile never
  reaches the policy stage;
- orchestration guarantees: one container verification and one identity lookup of
  each kind per request, two runs with the same request and clock equal, no
  mutation of the profile bytes, the entitlement tree, the application metadata, or
  the identity listing, and a diagnostic rendering that carries stages, outcomes,
  codes, and fingerprints but no identifier, value, or byte;
- the embedded-profile intake: the profile entry read exactly once with the reader
  closed, no content request at all when the bundle records no such entry, links
  and directories at that location refused, an entry too large for the read bound
  reported as unreadable rather than truncated, a missing or inconsistent artifact
  refused before the container is opened, a container that cannot be opened or
  enumerated reported as unusable input, a package with two application bundles not
  resolved by choosing one, and the bytes read back from a bundle driven through the
  whole pipeline.

These suites use the repository's synthetic fixtures only; they touch no device
authorization API, no keychain, no network, no real provisioning profile, and no
signing material. A `.verified` status in them means "the composed double accepted
the signature", never "the platform accepts this profile". Like the rest of the
target, they were written but not executed in the environment where they were
produced.

It also has tests for the generic cryptographic signing and verification
foundation (ZS-021):

- digests, against known vectors for SHA-1, SHA-256, SHA-384, and SHA-512
  (including the empty message and the one-million-byte multi-block vector),
  binary input, determinism across all supported algorithms, agreement with
  the certificate fingerprint's own SHA-256 implementation, and the digest
  value's exact-length enforcement and equality rules;
- signing requests: coherent message and digest operations accepted, a
  message on a digest operation and a digest on a message operation
  rejected, a digest of a different algorithm rejected rather than
  substituted, and the bounded operation-context rules;
- the signing engine: message and digest signing through a recording
  capability that proves exactly what crosses the boundary; RSA versus EC
  and unknown key families reported incompatible; an unsupported operation
  rejected with no substitution; an unavailable capability rejected without
  asking for a signature; structured capability failures keeping the
  identity boundary's own reason; foreign failures reduced without
  retaining their text; and an empty signature reported malformed;
- the signing use case: the store consulted for the capability and the
  certificate reference once each on success, validation before the store
  is touched, identity-boundary failures keeping their reasons, an
  unreadable identity not failing an already-produced signature, and engine
  substitution through the port;
- verification: the four outcomes kept as four distinct facts, the
  unavailable fallback reporting unavailable for every operation, and the
  port's substitutability;
- the iOS-gated platform verifier, over the committed synthetic CMS
  fixtures with their real RSA and ECDSA signatures: the accepted
  message- and digest-based signatures for both key families, a tampered
  signature and changed bytes as a conclusion (`.invalid`) rather than an
  error, a signature checked against a different same-family certificate,
  a cross-family certificate as `.unsupported(.incompatibleKey)`, a digest
  of the wrong algorithm as invalid input, an empty signature as
  malformed, and certificate encodings the platform refuses as
  unavailable. No key generation, keychain, or private key appears in any
  of these tests; the fixtures are public test material;
- the error domain: every reason structured with its category and a safe
  per-reason message, categories honest, diagnostic detail accepted but
  never reaching user-facing text, and sanitization preserving known
  reasons while dropping foreign error text;
- the security boundary: the request and the result carrying no key
  material by construction (checked field-by-field), the result's
  diagnostics carrying facts and byte counts but never the signature bytes
  or the signed data, and the verification boundary taking public material
  only.

These suites touch no device, no keychain, and no network; the
iOS-gated suite's signature mathematics run only where the platform
primitives exist. Like the rest of the target, they were written but not
executed in the environment where they were produced.

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

It also has tests for the advanced library (Step 12):

- the organization domain (`LibraryOrganizationTests`): collection names
  trimmed, collapsed, stripped of control characters with emoji sequences
  intact, bounded, and compared ignoring case, diacritics, and width;
  collection values adding idempotently in order and removing only what is
  named; creating, renaming (including to another spelling of its own
  name), and deleting collections; names unique within one kind; a record
  in several collections; removing from one collection leaving the others;
  moving as add-then-remove and moving into the same collection changing
  nothing; refusals leaving the value unchanged; forgetting records pruning
  memberships and usage but never collections; scopes and queries
  round-tripping through their stored and codable forms; the original Name
  order's stored value still reading as Name A–Z;
- the organizer and its file store (`LibraryOrganizerTests`): a change saved
  before it becomes current; a failed save and a refused change neither
  saved nor applied; an unchanged organization not saved again; a move as
  one save; a read failure thrown and retried, with nothing written over an
  unreadable organization; usage recorded and records forgotten; the
  document round-tripping collections, member order, unknown kinds, and
  usage through a temporary directory; a missing document read as empty; a
  newer schema reported and left untouched; and damaged documents —
  undecodable, version 0, a bad identifier, duplicate identifiers or names,
  an unnormalised name, a bad usage identifier, a record listed twice —
  failing closed;
- the library index (`LibraryIndexTests`): search across name, bundle
  identifier, version, file name, declared developer and team, and
  collection names, with every term required and case, diacritics, and
  width ignored; highlight runs that reassemble the displayed text and merge
  overlaps; filters AND-ed across facets and OR-ed within one; latest and
  older versions; the team filter and team list; the seven-day recency
  windows; recently signed and unsigned following the journal, a failed
  signing leaving an app unsigned; Expiring Soon holding expiring and
  expired apps but not valid or unknown ones; collection scopes ignoring
  memberships of removed records; scope and filters combining; all seven
  orders; statistics including stored bytes for missing and inconsistent
  files; incremental updates matching a full rebuild; a renamed collection
  updating collection search; a thousand-entry library answering queries
  correctly; and a 2,000-entry query measurement (`measure`, informative
  only);
- signing facts (`LibrarySigningFactsTests`): a signing naming a record
  belonging to it alone; a legacy signing belonging only to records that
  existed when it ran; only successful signings counting, the latest
  winning; the earlier of profile and certificate expiry deciding; expiry
  status at the window boundaries; journals without the new fields
  decoding;
- declared provenance (`ApplicationProvenanceExtractionTests`): the team
  from the embedded profile and the developer from store metadata; a decoded
  payload preferred over scanning; a package declaring nothing reading as
  unknown; an oversized profile not read; sanitising; results cached for the
  launch and across launches; an unopenable archive not cached; forgetting;
  a damaged cache ignored and rebuilt;
- verification (`LibraryArtifactVerificationTests`): intact packages;
  changed bytes of the same size caught where availability would not;
  truncated and missing packages reported without recreating anything;
  unknown records and read failures as typed errors; and the file store
  measuring a held artifact exactly as import described it;
- export preparation (`LibraryExportPreparationTests`): file names from
  name, version, and build; bundle-identifier fallback; unsafe characters,
  leading dots, empty names, and length bounds; case-insensitive
  uniqueness; prepared files carrying the library's bytes; unavailable
  packages skipped and counted; nothing to export as a typed failure; and
  discarding removing only the prepared names;
- the library screen model (`ApplicationLibraryAdvancedModelTests`): scopes,
  filters, and search stacking on the visible list; orders applied;
  collections created, filled, moved between, and emptied with every change
  persisted; creating from inside a collection moving the apps; name
  problems reported while typing; a deleted collection's scope and filters
  falling back; deleting an app removing it from its collections; the
  selection only ever holding visible entries; bulk favourite; bulk
  deletion; statistics following the library and the journal; a signing
  elsewhere refreshing signed state, Recently Signed, and Expiring Soon
  without a reload; a journal read failure keeping signed state; verification
  reports; export bundles prepared and discarded, and nothing to export
  announced; the Last Opened order; empty-state reasons; and row states
  carrying highlight terms and explaining hidden matches.

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
contain no private keys. The CMS fixtures are synthetic SignedData containers,
also embedded as base64 text: test-only RSA and EC keys and certificates
generated for this repository with OpenSSL, property-list payloads with
placeholder identifiers, and byte ranges recorded so tampered variants can be
derived deterministically. Each container whose name says it is valid was
cross-checked with `openssl cms -verify -noverify`, and the tampered variants
were confirmed to fail it. The private keys existed only while those bytes were
produced and are not committed. Other test fixtures are generated
programmatically. No binary fixture file is committed, and no real package,
signing material, provisioning profile, or production certificate appears
anywhere in the suite. Filesystem-backed
tests write only into a temporary directory that the test removes.

It also has read-only Mach-O parsing tests (ZS-022):

- tiny synthetic thin 32/64-bit and fat32/fat64 byte arrays, reversed-endian
  detection, all architecture records and explicit slice selection;
- load-command counts, sizes and alignment, unknown commands, missing/valid/
  duplicate `LC_CODE_SIGNATURE`, and offsets relative to the selected slice;
- SuperBlob magic, table and member bounds, empty/unknown entries, known blob
  magics, overlap and duplicate refusal;
- versioned CodeDirectory fields, primary and alternate directories, identifier
  and team bounds/encoding, known and unknown hash types, special slots and zero
  placeholders, scatter, extended limits, pre-encryption and linkage ranges;
- hostile values, truncation at each byte of a small signed-layout fixture,
  structured errors, Data subsequences, and opt-in use-case delegation.

These bytes contain no real executable, digest, certificate, or signature. They
are format fixtures only. The Mach-O tests require the Xcode unit-test runner;
syntax-only checks on another platform are not executed XCTest results.

The ZS-023 construction suite independently checks SHA-256, truncated
SHA-256, and SHA-384 page vectors; empty, complete, boundary, partial, and
bounded code regions; unsupported configurations; explicit special-slot
ordering; deterministic big-endian serialization; parser comparison of
value-owned hash bytes; malformed serialized input; and checked-writer length
handling. These tests are also XCTest cases and require the Xcode unit-test
runner.

The tests are written to run inside the unit-test target with Xcode's test
runner (Product ▸ Test, or `xcodebuild test` against the shared `ZynSign`
scheme). **They have not been executed yet.** The checks that have actually been
run against this code are recorded with the work that produced it, and none of
them constitutes an executed test run.

## ZS-024 checks

`SuperBlobConstructionTests` adds 24 XCTest cases for independent expected
bytes, deterministic packed serialization, CodeDirectory integration, opaque
frames, standalone parser round trips, malformed input, and resource/overflow
boundaries. Run it together with `ReadOnlyMachOParserTests` and
`CodeDirectoryConstructionTests` in the existing Xcode unit-test target.

For this change, the Linux environment had no Swift compiler or Xcode, and
toolchain downloads failed. Those XCTest cases **were not executed**. A Swift
grammar check passed for all seven changed/new Swift files, and Python
`struct` checks confirmed the four literal expected-byte vectors. Neither
check compiles or executes the production Swift code. No simulator, device,
or Apple signature-acceptance validation was performed. Details and remaining
checks are in [SuperBlob construction](../architecture/superblob-construction.md).

## ZS-025 checks

`MachOCodeSignatureRegionTests` adds XCTest cases covering:

- 16-byte alignment, SuperBlob framing, deterministic trailing zero reserve,
  and layout padding separation;
- native-width arithmetic, 32-bit `linkedit_data_command` field narrowing, and
  integer overflow protection without payload allocation;
- `CodeDirectory.codeLimit` vs `MachOFileLength` separation and overlap
  rejection;
- `MachOCodeSignatureInspector` classification of absent, valid, malformed
  command, invalid offset, invalid size, and malformed region states;
- universal/fat binary inspection and refusal of universal binary mutation;
- `MachOCodeSignatureWriter` append mutation, load-command header padding
  verification, `__LINKEDIT` virtual slack gating, big-endian thin support,
  and byte-for-byte preservation outside modified ranges;
- default rejection of existing signatures and unsupported explicit replacement;
- structured failure on malformed existing signatures, missing `__LINKEDIT`,
  and insufficient load-command space.

`ReadOnlyMachOParserTests` was also extended to test segment command decoding,
zero-fill section handling, and boundary enforcement.

The implementation environment has neither Swift nor Xcode. Those XCTest cases
**have not been executed** inside Xcode. Swift lexical bracket and grammar
checks passed for all new and modified Swift files; independent layout,
rounding, and field calculations were verified with Python structural test
scripts. These checks are structural and lexical verification, not compiled
Swift execution or platform acceptance. Run `MachOCodeSignatureRegionTests`
and the full suite in the Xcode unit-test target before relying on this code.

## ZS-028 checks

`NestedCodeSigningTests` adds XCTest cases covering:

- signing-plan validation: valid plan, duplicate target, duplicate executable path,
  missing dependency endpoint, dependency cycle, invalid ordering, path traversal,
  unsupported code kinds, universal binaries, and root application preservation;
- nested Mach-O signing: unsigned nested binary, existing signature rejection policy,
  unsupported existing signature replacement, and malformed signature handling;
- independent structural and cryptographic verification: page hashes, CodeDirectory
  digest matching, CMS detached signature verification, tampering detection, and
  clean failure on wrong signing key or unsupported algorithm;
- dependency-aware execution order: deep multi-level hierarchies (nested framework inside
  framework inside app), independent frameworks with deterministic tie-breaking,
  and plug-in/extension targets;
- failure handling and atomicity: artifact read failure, artifact write failure,
  signing capability failure, post-sign verification failure, staged working copy
  rollback (no targets modified), and direct mutation partial completion
  (some targets modified);
- binary preservation: unrelated Mach-O bytes, headers, and text section bytes remain
  strictly identical before and after signing.

Host verification script `Tests/Host/verify_nested_code_signing_vector.py` passed
independent topological dependency ordering, cycle refusal, nested Mach-O byte preservation,
and OpenSSL CMS verification. Swift balanced-delimiter and lexical checks passed for
all new and modified files.

## ZS-030 checks

The final-integration review fixed two defects and added regression coverage:

- `SignNestedCodeUseCase` verification now honors per-target metadata. The
  pre-existing `testNestedTargetsCarryTheirOwnMetadataOnly` in
  `SigningMetadataIntegrationTests` is the regression suite: it asserts a
  succeeding run with a four-slot SuperBlob on the metadata-bearing target,
  which the hardcoded two-slot check rejected.
- `NestedSigningArtifactStoreTests` is new: sibling-prefix symlink escape
  refused for reads and writes, plain outside-the-bundle escape refused,
  and a legitimate nested read succeeding.

The review environment had no Swift toolchain and no Xcode, so no XCTest
suite was executed there — including the suites above. Balanced-delimiter
checks passed for all new and modified Swift files, and the changed
verification code was reviewed line by line against the
`SignMachOUseCase.verify` implementation it mirrors. Both host vector
scripts were executed and passed:

- `Tests/Host/verify_macho_signing_vector.py` — Mach-O layout,
  CodeDirectory fields and page hashes, CMS binding and signature, and
  OpenSSL rejection of tampered variants;
- `Tests/Host/verify_nested_code_signing_vector.py` — deterministic
  dependency ordering and tie-breaking, byte preservation, OpenSSL CMS
  verification, and cycle detection.

The first executed run of the full XCTest suite, on hosted CI or a local
Xcode installation, remains a prerequisite to any Alpha claim.

## Packaging and pipeline checks

The packaging and application-pipeline increment adds XCTest suites and
one host vector script:

- `ZipArchiveWriterTests` — independent golden vectors (byte sequences
  assembled outside the implementation), determinism over shuffled
  input, plan ordering, nine plan refusals, reader round-trip through
  the production reader, tampered-content checksum failure, and sink
  behavior;
- `DirectoryArchiveExtractorTests` — files, directories, implied
  directories, executable-bit restoration, contained link recreation
  under policy, and refusal of unsafe names, duplicates,
  file-directory conflicts, links by default, absolute and escaping
  targets, unsupported kinds, and byte-bound overflow;
- `PackageSignedApplicationTests` — bundle packaging with content,
  executable-bit, and link preservation, determinism, refusal of
  non-bundle names, missing information files, and absolute links, and
  output removal when reopen validation fails;
- `SignApplicationPipelineTests` — end-to-end signing of synthetic
  containers (flat and nested) with every stage's evidence asserted,
  and refusal of structurally invalid sources, incompatible profiles,
  and already-signed executables, delivering nothing on every failure;
- `VerifySignedApplicationTests` — independent verification passing a
  signed container and detecting profile, seal, and metadata mismatch;
- `InstallationCapabilityTests` — the exact limitation set for each
  evidence combination.

The review environment had no Swift toolchain and no Xcode, so no XCTest
suite was executed there — including the suites above. Tree-sitter parse
checks passed for all new and modified Swift files, and the new code was
reviewed line by line against the contracts it consumes. The new host
vector script was executed and passed:

- `Tests/Host/verify_zip_writer_vectors.py` — golden-vector structure,
  fixed fields, modes, CRC-32, ordering, offsets, and `zipfile`
  acceptance of every committed vector.

## First hosted run

The workflow first passed on hosted infrastructure on 2026-09-24: run
35992989870 on `main` built the application and passed the full unit-test
target on an iPhone simulator, including every suite listed above as
written but not executed. The records above describe the environments the
suites were written in and are left as written. A simulator pass is not a
device result, and the opt-in Keychain integration suite skipped there by
design.

## ZS-031 checks

The external validation increment adds one opt-in XCTest suite, one host
harness, and one CI job
([external-validation.md](../architecture/external-validation.md)):

- `ExternalValidationExportTests` — skipped unless `ZYNSIGN_EXPORT_DIR` is
  set, so the ordinary test run is unchanged. With it set, it signs the
  synthetic executable twice (no metadata; XML entitlements) and the
  nested-framework container through `SignApplicationPipeline`, with a
  throwaway in-process RSA key and the production `AppleSignatureVerifier`,
  writes damaged copies of each single image with ZynSign's own verdict,
  and records everything in manifests;
- `Tests/Host/external_validation.py` — `self-test` checks the signature
  parser against the committed ZS-026 vector, the Apple-documented iOS
  format rules, the `otool`, `codesign`, and `xcodebuild` output parsers,
  the reference comparison, and the whole analysis and rendering path over
  synthetic exports with every tool unavailable; `run` is the macOS
  harness.

Executed:

- `python3 Tests/Host/external_validation.py self-test` in the Linux
  development environment — passes. The other host vector scripts still
  pass.
- Hosted runs 36010725148 and 36011553668 of the `external-validation` job
  on the ZS-031 branch — the export test ran and the harness completed on
  macOS 15.7.9 with Xcode 26.3 and OpenSSL 3.6.4. `codesign` accepted both
  single-image signatures and rejected the pipeline's bundle and its nested
  framework; the signature format failed Apple's documented iOS 15+ rules;
  OpenSSL verified every CMS; the layout checks passed; ZynSign and
  `codesign` agreed on all nine damaged images. The build-and-test and
  hygiene jobs stayed green on the same runs.

Not executed: anything on a device. No verdict here is iOS acceptance,
trust, or installability.

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
