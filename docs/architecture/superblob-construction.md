# Embedded-signature SuperBlob construction (ZS-024)

## Boundary

`SignatureSuperBlob` constructs an independent embedded-signature container.
It has no executable, file URL, signing identity, key, or application UI state.
Its output is `Data` plus calculated placements, not a modified Mach-O image.
It cannot update `LC_CODE_SIGNATURE`, insert a signature region, generate CMS,
sign anything, or package/install an application. No application use case is
needed for this pure value construction boundary, and none is composed into
the interface.

**Structural validity is not authenticity, authorization, or Apple platform
acceptance.** An empty container is representable but not a complete signature.

## Format evidence

The following public Apple definitions were reviewed on 2026-09-23 before
implementing serialization. They establish format facts, not device behavior:

- **Verified — field layout and constants:** XNU
  [`cs_blobs.h`](https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/osfmk/kern/cs_blobs.h).
- **Verified — generic frame and byte order:** Security
  [`blob.h`](https://github.com/apple-oss-distributions/Security/blob/db15acbe6a7f257a859ad9a3bb86097bfe0679d9/OSX/libsecurity_utilities/lib/blob.h).
- **Verified — offset base, packing, and structural relationships:** Security
  [`superblob.h`](https://github.com/apple-oss-distributions/Security/blob/db15acbe6a7f257a859ad9a3bb86097bfe0679d9/OSX/libsecurity_utilities/lib/superblob.h).

| Structure | Byte offset | Field | Representation |
| --- | ---: | --- | --- |
| Container | 0 | magic | UInt32, `0xFADE0CC0` |
| Container | 4 | length | UInt32, includes header, index, and member bytes |
| Container | 8 | count | UInt32, number of index records |
| Index record | 0 | type | UInt32, slot number, **not** blob magic |
| Index record | 4 | offset | UInt32, relative to the first SuperBlob byte |
| Individual blob | 0 | magic | UInt32, identifies the member format |
| Individual blob | 4 | length | UInt32, includes its own 8-byte generic frame |

**Verified:** All these words are big-endian. The container header is 12 bytes,
the index is `count * 8` bytes, and each indexed member includes at least its
8-byte generic frame. Member offsets must be beyond the entire index and each
complete member must fit within the declared container length.

**Verified:** The published format does not prescribe a semantic order for
members. **Observed (Apple implementation):** its container builder orders by
numeric type, packs members consecutively, and adds no alignment padding; its
strict validator requires complete contiguous coverage following the index.
The published XNU structures are byte-aligned. ZynSign therefore emits no
padding and permits odd member lengths and odd subsequent offsets. Mach-O
file/segment/signature-region alignment is a different boundary, not decided
by this task.

## Domain model and supported types

The existing parser's slot vocabulary is now `CodeSignatureBlobType`, shared
by construction and inspection rather than duplicated in a Mach-O-specific
enumeration. It distinguishes an index type from both blob magic and a
CodeDirectory's negative special hash slots.

| Index type | Magic | Construction support |
| --- | --- | --- |
| Primary CodeDirectory, `0` | `0xFADE0C02` | Typed, through ZS-023 |
| Alternate CodeDirectory, `0x1000...0x1004` | `0xFADE0C02` | Placement of separately supplied typed directories only |
| Requirements, `2` | `0xFADE0C01` | Opaque complete bytes only |
| XML entitlements, `5` | `0xFADE7171` | Opaque complete bytes only |
| DER entitlements, `7` | `0xFADE7172` | Opaque complete bytes only |
| CMS wrapper, `0x10000` | `0xFADE0B01` | Opaque complete bytes only |
| Other UInt32 types | Uninterpreted | Explicit `.other`, opaque complete bytes only |

`CodeSignatureBlob` privately controls creation of its immutable, header-inclusive
bytes. Its `Content` distinguishes a ZS-023 CodeDirectory serialization from
opaque data. `payload` exposes the bytes after the generic frame; it does not
imply that those bytes have been decoded. `CodeSignatureBlobEntry` pairs the
blob with a validated index type. Unsupported alternate ordinals and `.other`
values that disguise a named type are refused. Unknown types/magics are not
invented assignments: they are retained numeric values with no semantics.
There is no universal rejection rule for an unknown magic whose meaning is
unknown; known slot/magic mismatches are rejected.

Opaque intake accepts an **existing complete blob**, not a payload-only
requirements/entitlements/CMS generation request. Its outer length must be at
least eight, exactly equal to the supplied byte count, and within policy.
Internal requirements expressions, nested requirements indices, XML, DER,
CMS, and other opaque payload semantics are **not** validated. Their complete
semantic validation remains unsupported. Opaque data is not trusted, executed,
logged, or used to authorize anything. A CodeDirectory magic is refused at
opaque intake even under an unknown index type, preventing bypass of the
supported typed construction path.

## CodeDirectory integration

```text
CodeDirectoryConstructor / validated CodeDirectory
    → CodeSignatureBlob.codeDirectory(directory)
    → existing CodeDirectorySerializer (once)
    → immutable CodeDirectorySerialization bytes
    → CodeSignatureBlobEntry(type: ..., blob: ...)
    → SignatureSuperBlob(entries: ...)
    → serialize() → SuperBlobSerialization
```

The container does not reinterpret or modify CodeDirectory fields or hashes.
It uses the cached byte count for layout rather than serializing again.
`Data` value ownership allows the typed metadata and blob to share backing
storage until mutation. Primary and multiple alternate slots are kept
independently; they are never merged. ZS-023's supported construction versions
and hash configurations remain unchanged. Selecting, generating, or binding
alternate hashes is unsupported; this task only permits caller-supplied typed
directories in the documented alternate slots.

## Determinism, layout, and validation

**Project policy:** entries are sorted by ascending encoded UInt32 type, in
both the index and physical payload order. Duplicate types are errors, not
replacement requests. Offsets are derived from the final layout:
`12 + 8 * count`, followed by the exact complete lengths of prior members.
The empty layout is exactly twelve bytes. No reserve bytes or padding are
emitted.

`SuperBlobLayout` is a size-only planner, so integer-width, machine-overflow,
and resource boundaries can be exercised without allocating giant blobs.
Count is capped before multiplication or index allocation. Every member length
is checked before addition, every end must fit UInt32 and policy, and sequential
placements prevent overlap. Offset checks during emission and an exact final
length check protect consistency with the plan. The existing
`CheckedBinaryWriter` supplies bounded big-endian output; no second writer or
binary reader was introduced.

The concepts stay distinct:

1. **Construct:** validated, immutable typed/opaque values and canonical ordering.
2. **Validate model:** uniqueness and representable complete layout.
3. **Serialize:** emit header, index, and already-framed members through the writer.
4. **Parse untrusted bytes:** `ReadOnlyMachOParser.parseSuperBlob` reuses the
   ZS-022 parser without manufacturing a Mach-O wrapper.
5. **Validate serialization:** `SuperBlobSerialization.validate()` parses bytes
   independently, then compares count, lengths, offsets, and canonical order
   against the supplied layout. It is explicit, not repeated on every emission.

The standalone parser returns the existing `MachOSuperBlob` inspection value;
its ranges are relative to the supplied standalone buffer. The historical
inspection type name does not require a Mach-O file. Parsing necessarily
checks bounds before it can expose any range. It preserves input index order
and existing permissive treatment of interior gaps; canonical construction
validation is stricter. Standalone input must contain exactly one declared
SuperBlob, with no trailing region reserve. The Mach-O path still permits a
larger reserved signature region and still checks CodeDirectory code limits
against the containing signature offset. Standalone inspection cannot perform
that executable-relative check, but retains all other CodeDirectory checks.

Construction failures use `SuperBlobError`; CodeDirectory validation keeps
`CodeDirectoryError`; binary inspection retains ZS-022's structured
`MachOParsingError` with a reason and boundary. The existing writer's defensive
capacity errors remain structured `CodeDirectoryError` values; the checked
layout ensures valid SuperBlob writes fit its capacity. No error retains
payload bytes, identities, paths, or untrusted strings.

## Security and resource policy

**Project limits, not Apple maximums:** 128 entries and 256 MiB total serialized
length, consistent with the inspection foundation. These are hard ceilings,
not allocation targets. Opaque intake checks size before inspecting its frame
or creating a value. Construction checks total size before output allocation.
Inspection validates the count before reserving arrays, uses the existing
bounded byte reader before slicing, and rejects truncated headers/indexes,
known magic mismatches, invalid lengths/offsets, duplicate slots and overlapping
member ranges. The bounded entry count also bounds overlap-comparison work.
Callers still own the cost of acquiring their original input buffers.

Structural validation cannot detect an arbitrary changed opaque payload or a
well-sized but incorrect page hash. Tests intentionally demonstrate that
limit, rather than claiming a structural parser authenticates content.

## Platform findings and checks

- **Verified (repository settings):** Xcode 16+ synchronized groups, Swift 5
  language mode, provisional iOS/iPadOS 17.0 deployment target; no product
  dependency, project setting, UI, or private API change.
- **Verified (format):** header/index/frame widths, big-endian words, relative
  offsets, named slots, packed placement, and minimum empty representation as
  described above.
- **Inferred (conservative project policy):** unique slot types, count/size
  ceilings, ascending order, and exact standalone-buffer consumption are the
  supported construction contract, not a complete statement of every historical
  Apple validator's behavior. Apple's generic container reader also exposes
  null-offset behavior; ZynSign deliberately retains ZS-022's refusal of such
  entries and emits only present members.
- **Unknown:** semantics/validity of opaque future types, all historical padding
  tolerances, and target-platform acceptance of any complete constructed
  signature.
- **Requires experiment:** device/OS acceptance, signature-region alignment and
  placement in real executables, alternate-hash policy, and end-to-end CMS/hash
  verification. None was performed or is claimed here.

`SuperBlobConstructionTests` contains 24 XCTest cases: four independent literal
vectors, parser comparisons, deterministic permutations, multiple directories,
opaque byte/subsequence preservation, unaligned offsets, malformed headers and
indices, overlap, wrong known magics, corrupted CodeDirectory structure,
unsupported representations, bounded large payloads, count limits, size-only
overflow tests, and explicit serialization-metadata validation.

The implementation environment has neither Swift nor Xcode. Attempts to obtain
a temporary Swift toolchain failed at download. The XCTest suite and existing
ZS-022/ZS-023 regression suites **have not been executed** for this change.
Swift grammar checks passed for all seven changed/new Swift files; the four
literal expected-byte vectors were independently checked with Python's
big-endian `struct` decoder and frame/offset assertions. These are syntax and
fixture checks, not Swift type-checking, XCTest, device, simulator, or platform
acceptance results. Run the shared Xcode `ZynSign` scheme's unit tests, including
`SuperBlobConstructionTests`, `ReadOnlyMachOParserTests`, and
`CodeDirectoryConstructionTests`, before relying on the implementation.
