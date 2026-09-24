# Signing metadata: entitlements, requirements, and CodeResources (ZS-029)

## Status and evidence

This increment adds the signing-metadata layer that sits between the
provisioning and Mach-O layers already in place and the signing pipeline of
ZS-026/ZS-028: a typed entitlement model with a deterministic canonical
serialization, a typed requirements model with framing-level binary
serialization, a resource-sealing boundary that produces the CodeResources
document, the derivation of CodeDirectory special slots 2, 3, and 5 from those
three components, and their integration into single-image and nested-code
signing.

Release verification remains bounded by the development environment: no Swift
toolchain was available where this increment was written, so the new suites were
authored against independently computed byte and digest vectors but could not be
executed locally. They must be run before any release claim. No physical iOS
device is available here either. Nothing in this increment is a claim that iOS
accepts anything ZynSign constructs.

Evidence reviewed on 2026-09-23, using the classification vocabulary of the
architecture document:

- **Verified — binary framing:** the blob magic numbers (`0xFADE0C00`
  requirement, `0xFADE0C01` requirement set, `0xFADE0C02` CodeDirectory,
  `0xFADE0B01` blob wrapper, `0xFADE7171` entitlements, `0xFADE0CC0`
  embedded-signature SuperBlob), the generic blob header (magic, big-endian
  total length including the eight-byte header), the SuperBlob index layout,
  and the requirement-set entry kinds 1–5 (host, guest, designated, library,
  plugin) are stated in Apple's published open-source headers.
- **Verified — slot assignment:** special slots 2 (requirements blob),
  3 (resource directory / CodeResources file), and 5 (entitlements blob) are
  stated in the same headers and match the parser's own slot model.
- **Observed — digest inputs:** across consistent independent reimplementations
  of the format, the slot-2 and slot-5 digests cover the complete embedded blob
  including its eight-byte header, and the slot-3 digest covers the
  CodeResources file bytes, which are not part of the SuperBlob at all.
- **Observed — CodeResources shape:** the document is a property list whose
  `files2` dictionary carries per-file `hash2` (SHA-256) entries and nested-code
  `cdhash` entries; the v1 `files`/`rules` dictionaries are the legacy SHA-1
  form. Apple's published guidance states `files2` is the operative dictionary.
- **Observed — entitlement encodings:** entitlements blobs produced by other
  toolchains have been observed with both XML and binary property-list payloads,
  so reading accepts both and writing uses one canonical XML form.
- **Inferred — cdhash derivation:** the nested-code `cdhash` is the first 20
  bytes of the SHA-256 digest of the nested binary's SHA-256 CodeDirectory blob,
  consistent across independent reimplementations. ZynSign derives it exactly
  that way; byte-for-byte agreement with Apple's own seal **requires
  experiment**.
- **Inferred — canonical serialization:** the canonical XML property-list form
  (header lines, ascending UTF-8 key bytes, tab indentation, one element per
  line, base64 data wrapped at 76 columns) is ZynSign's own determinism rule.
  It follows the shape Apple's tooling writes, but byte-for-byte agreement with
  Apple's serializer is **not claimed** and requires experiment.
- **Unknown — platform policy:** parsing, embedding, and local verification say
  nothing about AMFI, CoreTrust, or entitlement enforcement on a device.
- **Requires experiment:** device execution of binaries signed with these
  blobs; comparison of ZynSign's serialized bytes against Apple tooling output
  over the same inputs.

## Entitlements

`CodeSigningEntitlements` is a typed claim set over the existing
`ProvisioningProfileValue` tree: strings, booleans, integers, finite reals,
data, arrays, and dictionaries. The design positions:

- **Unknown keys stay representable.** There is no enumerated vocabulary of
  Apple entitlement names; a key the model has never seen is stored, serialized,
  and digested exactly like any other key. The model validates structure
  (non-empty, bounded, control-character-free keys; bounded depth, node count,
  string, data, and collection sizes), not meaning.
- **Dates are excluded on purpose.** No deterministic canonical serialization
  for property-list dates is established, and a silent format choice here would
  become a hashing boundary by accident. A date value fails closed with
  `unsupportedValueType`; nothing is coerced to a string or timestamp.
- **States stay distinct.** "Decoded" (the bytes parsed into a typed tree),
  "structurally valid" (the model accepted it), "provisioning-compatible"
  (`EntitlementsProvisioningValidation` bridged the claim set into the existing
  ZS-020 policy validator, which alone owns every rule and may answer
  `indeterminate`), "embedded" (`EmbeddedEntitlementsRecord` carries the exact
  blob bytes, the slot-5 digest, and `platformAuthorization: .notEvaluated`),
  and "platform-authorized" (never claimed by any local operation) are five
  separate statements. The signing result carries `platformAuthorization` and
  `provisioningValidation` as explicit `.notPerformed` markers.

Serialization is one function: `EntitlementsCanonicalSerializer` emits the
canonical property-list form documented on `CanonicalPropertyListXMLSerializer`
— fixed header lines, keys in ascending UTF-8 byte order, tab indentation, one
element per line, no value transformation of any kind, and a typed error for
anything the form cannot represent. Two claim sets that differ in any byte are
different digests; two sets that differ only in dictionary insertion order are
identical bytes. The entitlements blob is that payload framed by the generic
eight-byte blob header (`0xFADE7171`, total length). Reading goes through the
existing Foundation property-list boundary with bounded conversion, accepts XML
and binary payloads, and refuses the OpenStep format.

## Requirements

`RequirementsSet` models the requirement-set blob at the framing level only:
a SuperBlob-shaped set whose entries each carry a kind (the five documented
kinds plus `other`, preserved numerically) and one nested requirement blob
(`0xFADE0C00`) whose expression bytes are carried verbatim. The design
positions:

- **The expression language is not interpreted.** No requirement is evaluated,
  generated, translated into text, or silently replaced. Framing is parsed and
  serialized exactly; expression bytes round-trip byte-for-byte, and
  `expressionInterpretation` stays `.notImplemented`.
- **Dispositions are explicit.** A requirements value is `absent`,
  `presentAndParsed`, `presentButUnsupported` (an entry kind outside the
  documented five — still embeddable, since the set's own framing is valid),
  `malformed`, `generated`, or `verified`; the last two exist in the vocabulary
  so no future caller can fabricate them silently, and no code path produces
  them today. A `malformed` value is refused at the embedding boundary
  (`validateForEmbedding`) before any cryptographic operation.
- **Serialization is checked, not best-effort.** The set serializer enforces
  the magic, the declared total length, entry-kind uniqueness, ascending index
  order, offsets inside the set with no overlaps, a bounded entry count, and
  width-safe arithmetic through the checked writer and reader. Parsing refuses
  every violation with a typed `RequirementsError` naming the violated rule.

The binary requirement-expression encoding (the opcode language inside
`0xFADE0C00` blobs) is deliberately **not** implemented: ZynSign's evidence
covers the framing and the entry kinds, not the expression semantics. The
boundary records this explicitly instead of guessing an encoding.

## Resource sealing and CodeResources

`ResourceContentStore` is a read-only port over one signing target's resources:
it can list entries and read one file's exact bytes, nothing else. Two
implementations exist — an in-memory store for tests and staged sealing, and a
directory store that walks a bundle directory without ever resolving a symbolic
link. `CodeResourcesGenerator` seals one set:

- **Deterministic order.** Entries are emitted in ascending UTF-8 byte order of
  bundle-relative path, regardless of the store's listing order; the same tree
  yields the same document bytes.
- **Exact bytes only.** Each file is hashed exactly as stored (SHA-256, the
  `hash2` form). Nothing is normalized, decompressed, or re-encoded.
- **Bounded work.** Resource count, per-resource size, and cumulative size are
  enforced; checked arithmetic guards the cumulative counter.
- **No invention.** Directories are structural and produce no entries.
  Exclusions come only from the caller's configuration and are recorded as
  omissions, never silently dropped. Symbolic links are never followed; the
  policy either fails the walk (the default) or records the link as an omitted
  resource. Nested code appears only as caller-supplied `NestedCodeResourceSeal`
  values carrying the final signed state's cdhash — the generator neither signs
  nor re-derives nested code.

`CodeResourcesDocument` is the typed form of the subset ZynSign uses:
`files2` (file `hash2` entries and nested-code `cdhash` entries) and optional
caller-supplied `rules2`. Rules are represented and round-tripped but never
generated: which exclusion rules the platform expects is outside established
knowledge and requires experiment. The legacy v1 `files` (SHA-1) and `rules`
dictionaries are an explicit unsupported subset — parsing one fails with
`unsupportedTopLevelKey` rather than silently dropping content. Recorded
omissions are provenance on the document and are deliberately not serialized:
the property-list format defines no such field. The 20-byte cdhash carries no
beside-it requirement-language string, because generating that text is outside
the implemented subset; the omission is recorded here rather than hidden.

## Special slots and the signing pipeline

`SigningMetadataSlotDigests` derives the three metadata digests and
`specialSlots(hashSize:)` turns them into CodeDirectory construction order:
contiguous indices from 1 to the highest occupied slot, with unoccupied
reserved slots represented as zero-hash placeholders — the format's absence
representation, not invented digests. Slot 1 (the bundle's Info.plist digest)
is deliberately never produced by this layer; it belongs to bundle-level
signing, which is out of scope.

The pipeline order is fixed in `SigningMetadataPreparation.prepare` and in
`SignMachOUseCase`: serialize and frame the entitlements payload; serialize the
requirements set; digest each component's exact bytes under the directory's own
hash configuration; finalize the special slots; and only then construct the
CodeDirectory over complete slot contents, hash it, and sign that digest. The
CodeDirectory is never signed before every special-slot input is final. The
SuperBlob order is CodeDirectory (slot 0), requirements (slot 2), entitlements
(slot 5), CMS (slot 0x10000); CodeResources contributes no SuperBlob blob
because slot 3 digests a bundle file, not an embedded blob.

Verification holds the signed artifact to the request's metadata, not to
whatever happens to be embedded: the embedded requirements and entitlements
blobs are compared byte-for-byte against re-derived preparations, and the
declared special-slot digests for slots 2, 3, and 5 are compared against the
re-derived digests before the CodeDirectory reconstruction and CMS check run.

## Nested code interaction

Nested code stays independently signed; the resource seal consumes the nested
code's *final* signed state. The intended order for the complete application
pipeline (of which only the nested half exists today) is: discover nested code,
plan, sign nested code, prepare the parent's metadata (including the resource
seal over the final nested state), sign the parent, then verify.

Metadata is per target by construction. `NestedCodeSigningConfiguration`
carries `targetMetadata` keyed by item identity; a target with no entry signs
with no metadata, exactly as ZS-026/028 did. Nothing copies a parent's
entitlements, requirements, or resource seal into a child, or a child's into
its parent: the application executable, a framework, and an extension each
state their own metadata, and the pipeline derives every special-slot digest
from that statement alone. A metadata component that fails its own boundary
surfaces as `signingMetadataFailure` at the metadata stage — not as a Mach-O,
layout, or cryptographic failure — and under the staged mutation strategy
leaves the artifact untouched.

## Read-only inspection

`EmbeddedSigningMetadataInspector` extends the ZS-022 parsing surface with a
total, read-only classification of an existing signature's metadata: the
entitlements slot is `absent`, `present` (decoded, explicitly not an
authorization), or `malformed`; the requirements slot carries its disposition
with expressions still uninterpreted; and the CodeResources seal reports the
declared slot-3 digest, where nonzero bytes establish only that a digest is
present, never that it is correct for any resource tree. Inspection mutates
nothing and verifies nothing.

## Security

- All parsing treats input as untrusted: bounded blob and document sizes,
  bounded collection counts, nesting-depth limits, string and data bounds, and
  checked offset/length arithmetic with explicit overflow failures.
- Resource paths are `BundlePath` values — bundle-relative and
  traversal-free by construction; the directory store composes reads from
  validated components under its root and never resolves a symbolic link, so
  no link can redirect the walk outside the bundle. Parser-side file paths
  that are not valid bundle-relative paths are refused, never laundered into
  path values.
- Symbolic links fail closed unless the caller explicitly configures
  exclusion; exclusion records the link without following or hashing it.
- Requirements framing is validated against overlaps, duplicates,
  out-of-range offsets, and count bounds before any byte of it is embedded.
- Errors are structured per stage and carry paths and counts, never resource
  contents, blob payloads, or key material. No secrets exist in any fixture.
- No third-party dependency was added: everything uses Foundation, the
  existing digest port, and the existing checked reader/writer.

## Testing

The suites are `EntitlementsTests`, `CodeSignatureRequirementsTests`,
`CodeResourcesTests`, and `SigningMetadataIntegrationTests`. Digest and byte
expectations are literals computed independently of the Swift implementation
(host-side script over the documented framing and canonical form), so a
regression in the serializer cannot silently redefine a digest boundary. The
integration suite pins the metadata-free path to the existing golden artifact
byte-for-byte, covers full/entitlements-only/CodeResources-only metadata,
tamper detection over the embedded blobs, the declared slot digests, and the
nested per-target flow, using the always-valid verifier pattern for
metadata-bearing signatures (the golden-digest verifier pins a
metadata-free CodeDirectory by construction).

As stated under Status, no Swift toolchain was available in this environment;
the suites are authored but were not executed locally, and running them is a
prerequisite to any release claim.

## Non-goals

- No application signing workflow, IPA packaging, installation, OTA, or
  release automation (later increments).
- No interpretation, evaluation, or generation of requirement expressions.
- No DER-entitlements slot (7), app-specific slot (4), disk-image slot (6), or
  launch-constraint slots (8–11); no slot-1 Info.plist digest.
- No CodeResources v1 (`files`/`rules`) generation or acceptance.
- No claim of platform authorization, device acceptance, or byte-exact
  agreement with Apple's serializers.
