# Mach-O code-signature inspection (ZS-022)

## Boundary and evidence

This increment reads supplied bytes. It does not alter a Mach-O image, generate
code-signature data, compute code-page hashes, verify a signature, sign a bundle,
or determine whether an application can run or be installed.

**Presence of a Mach-O code-signature structure does not establish
cryptographic validity, certificate trust, provisioning authorization, or
installation eligibility.** A syntactically parseable CodeDirectory does not
establish that any digest matches the file, that CMS binds the directory to a
key, or that the OS accepts the result.

The binary layouts and interpretations below were checked against these public
sources before implementing the reader:

- **Verified (format):** Apple's [Mach-O loader header](https://github.com/apple-oss-distributions/cctools/blob/main/include/mach-o/loader.h)
  defines 28- and 32-byte thin headers, load commands, `LC_CODE_SIGNATURE`
  (`0x1d`), and the 16-byte `linkedit_data_command` containing `dataoff` and
  `datasize`.
- **Verified (format):** Apple's [fat header](https://github.com/apple-oss-distributions/cctools/blob/main/include/mach-o/fat.h)
  defines both fat record widths, relative slice offsets and sizes, alignment
  as a power-of-two exponent, and canonical on-disk big-endian fat tables.
- **Verified (format):** Apple's [code-signing structures](https://github.com/apple-oss-distributions/xnu/blob/main/osfmk/kern/cs_blobs.h)
  define the indexed SuperBlob and generic blob headers, CodeDirectory fields
  through version `0x20600`, known slot/magic and hash-type numbers, and the
  24-byte scatter record. Apple's [CodeDirectory definitions](https://github.com/apple-oss-distributions/Security/blob/main/OSX/libsecurity_codesigning/lib/codedirectory.h)
  and [structural checks](https://github.com/apple-oss-distributions/Security/blob/main/OSX/libsecurity_codesigning/lib/codedirectory.cpp)
  establish big-endian on-disk fields, optional version milestones, the
  nonzero extended-limit rule, negative-slot layout, scatter terminator, and
  the page-count/limit consistency check.
- **Verified (concepts):** Apple's [TN3126: Inside Code Signing: Hashes](https://developer.apple.com/documentation/technotes/tn3126-inside-code-signing-hashes)
  explains independently signed universal slices, alternate CodeDirectories,
  per-page and negative special slots, and the relationship of slot `-3` to
  `_CodeSignature/CodeResources`. Its examples are from macOS; the technote
  says the concepts apply to Apple platforms generally. This is not evidence
  that ZynSign-produced signatures would be accepted on iOS/iPadOS.
- **Observed (published examples):** TN3126 displays `LC_CODE_SIGNATURE`
  with file offset and size, a `v=20500` CodeDirectory, SHA-256 slots, and
  special slots containing both zero placeholders and nonzero hashes. No
  production IPA fixture was imported for this increment.

## Flow and models

```text
caller-supplied Data (bounded by caller and 256 MiB parser cap)
       ↓
MachOInspection (application; opt-in, no I/O)
       ↓
MachOParsing (domain port) → ReadOnlyMachOParser (platform-neutral Swift)
       ↓
BoundedBinaryReader → validated ranges → MachOImage / MachOParsingError
```

`MachOImage` is either thin or universal. A universal image contains all
`MachOArchitecture` records and a `MachOSlice` for each record **in table
order**; `slice(at:)` requires explicit selection. The records preserve CPU
family/subtype, alignment exponent, and file range. A slice preserves the
header's magic, byte order, file type, flags and optional 64-bit reserved word;
unknown CPU families and load-command numbers remain inspectable. A missing
code-signature command yields `embeddedSignature == nil`. Successful inspection
is a structural description, never a signing or verification result.

**Verified (format):** Thin images may be 32- or 64-bit; reversed thin magic
selects little-endian field decoding. Fat records are normally big-endian. Fat
`dataoff` values in a *slice's* `LC_CODE_SIGNATURE` are relative to that slice,
not the outer file. **Inferred (compatibility choice):** Swapped-endian fat
magic is accepted for read-only inspection, but Apple's fat header describes
big-endian tables as the on-disk format. Do not infer that Apple produces or
accepts swapped-endian fat containers on iOS. CPU subtypes (including arm64e
subtype/capability bits) are retained as integers; no architecture is picked
implicitly and no CPU/OS compatibility decision is made.

**Parser policy, not Apple acceptance rules:** Up to 64 architectures, 4,096
load commands, 1 MiB of load-command bytes, 128 SuperBlob indices, 64 special
hash slots, 4,096 scatter records, and 4,096 bytes per identifier. Fat slice
alignment exponents above 30 and page-size exponents above 30 are refused.
These are conservative resource limits, not claims about Apple's published
maximums. The 256 MiB input cap limits parsing work but does not make an
already-allocated caller input cheap to acquire. Existing `ArchiveReader`
inspection reads have a smaller independent cap (4 MiB by default): this use
case does **not** read archive entries, enlarge that limit, or alter the
bundle explorer's metadata-only behavior. A later, explicitly requested
executable-intake/streaming boundary will be needed for large compressed IPA
executables. No binary is executed or extracted here.

## Load command and embedded signature

The parser walks exactly `ncmds` commands through exactly `sizeofcmds` bytes.
Each command is at least 8 bytes and its `cmdsize` is a multiple of 4 in a
32-bit image or 8 in a 64-bit image. Unknown commands are retained as type and
file range. Duplicate `LC_CODE_SIGNATURE` commands or a command whose size is
not 16 bytes are refused. The signature region must have nonzero length, be
contained in the **same** slice, and not overlap its header/load commands.
Parsing the command only locates bytes; it cannot prove a signature exists at
those bytes, let alone that it is valid. Other load commands, including segment
layout and encryption state, are not interpreted here.

**Verified (format):** The embedded signature begins with a big-endian indexed
SuperBlob (`0xFADE0CC0`): magic, declared length, count, then `(slot, offset)`
records. The reader delimits every member with its own magic and length,
requires indices to refer beyond the index table, rejects duplicate indices
and overlapping member ranges, and rejects known slots whose blob magic does
not match the published assignment. It preserves unknown slots and magics as
numbers, without decoding their contents. An empty indexed SuperBlob is a
structural container, **not** a complete code signature. A `datasize` greater
than the declared SuperBlob length is representable; trailing region bytes are
not interpreted or asserted to be valid padding.

Known indexed components are the primary CodeDirectory (`0`), alternate
CodeDirectories (`0x1000` through `0x1004`), requirements (`2`), XML and DER
entitlements (`5`, `7`), and the CMS wrapper (`0x10000`). These are *index*
entries, not a declaration that their payloads have been decoded, validated,
or authorized. Other slot numbers stay uninterpreted. CMS, requirements, and
entitlements payload parsing remain separate responsibilities.

## CodeDirectory, hashes and resources

The reader handles version milestones explicitly:

| Version range | Minimum fixed header | Newly available fields |
| --- | ---: | --- |
| `0x20001`–`0x200ff` | 44 bytes | flags, identifier, hash table, special/code counts, 32-bit code limit, hash type/size, platform, page exponent |
| `0x20100`–`0x201ff` | 48 bytes | optional scatter table offset |
| `0x20200`–`0x202ff` | 52 bytes | optional team identifier offset |
| `0x20300`–`0x203ff` | 64 bytes | extended code limit |
| `0x20400`–`0x204ff` | 88 bytes | executable-segment base/limit/flags |
| `0x20500`–`0x205ff` | 96 bytes | runtime value and optional pre-encryption hash range |
| `0x20600` | 108 bytes | linkage metadata and optional bounded data range |

Version fields outside the implemented range fail with an explicit unsupported
version error, rather than being read as the nearest known layout. String
positions must be within the directory, before the hash table, NUL-terminated
and UTF-8 decodable within the bound; neither string is equated with a bundle
ID or a profile Team ID. Optional scatter records are delimited through a
zero-count sentinel and kept as metadata, not used to hash pages. Pre-encryption
and linkage byte ranges are likewise only delimited. Ranges for known dynamic
fields cannot overlap each other, the fixed header, or the hash slots. The
published reserved CodeDirectory words and non-sentinel scatter reserved words
must be zero.

**Verified (format):** `hashOffset` points at code slot zero. Special slots
precede it at negative indices. Their reserved positions and whether their
bytes are nonzero are modeled separately. Established labels include `-1`
Info.plist, `-2` requirements, `-3` CodeResources, `-4` application-specific,
`-5` XML entitlements, `-6` representation-specific, `-7` DER entitlements,
and `-8` through `-11` launch/library constraints (per Apple's CodeDirectory
headers); unknown indices retain their number. These are labels, not decoded
payloads. A zero-filled
slot does not mean its purported content exists. A nonzero slot does not mean
its digest is correct, its contents valid, or its claim authorized. The known
hash encodings are SHA-1 (20), SHA-256 (32), truncated SHA-256 (20), and SHA-384
(48) bytes. Unknown hash types remain recorded as unknown with a bounded size:
no caller may interpret that as permission to generate a signature. The
parser validates all declared hash table ranges and checks that the code-slot
count corresponds to the declared code limit and page exponent, with or
without scatter metadata. It computes **no** digest.

`_CodeSignature/CodeResources` is a separate bundle resource record recognized
by the existing explorer. Only a CodeDirectory *hash slot* (typically `-3`)
refers to it. This parser does not read, generate, or validate CodeResources,
CMS, requirements, or entitlements. A later construction pipeline may combine
those independently, but has no write API in this increment.

## Security, limits, and open questions

**Verified (implementation boundary):** A `Data.withUnsafeBytes` view stays
inside one parse call; the checked reader never exposes an unchecked binary
load or retains the input pointer. Fixed-width integer reads are bytewise and
endian-explicit. Conversion of attacker-controlled offsets and counts to `Int`
is checked. Bounds are checked by subtraction before adding offsets. Nested
ranges are limited to their parent slice/blob. Blob and slice overlaps are
refused, with structured reasons and boundary names, and optional fat-table
indices, without copying input values into error messages.

**Inferred (conservative parser policy):** Fat-table CPU type/subtype must
exactly match the member header, and the effective code limit must not exceed
`LC_CODE_SIGNATURE.dataoff`. These are consistency checks, not claims that all
historical Apple images obey them. **Verified (Apple's reader):** A nonzero
`codeLimit64` takes precedence over the 32-bit field, and the declared code
slot count must match the page-size/limit coverage even when scatter is present.
Validating the remaining choices against varied real fixtures is necessary
before using the model to construct anything.

**Unknown / Requires experiment:** Precise device-targeted architecture and
CodeDirectory-version matrix; whether swapped fat records, unusually aligned
signatures, scatter mappings, extended limits, or non-UTF-8 identifiers occur in
supported IPAs; encrypted executables and other load-command interactions;
`__LINKEDIT` and segment coverage checks; the meaning of extra trailing bytes;
real-world fat64 compatibility; and exact iOS/iPadOS OS acceptance behavior.
Device/OS fixture comparisons and independent signature verification (the
feasibility study's E5/E6) are required before construction work. Apple TN3126
also describes iOS 15's DER-entitlements compatibility case; this parser
records slots `-5` and `-7` but deliberately makes no compatibility decision.
No macOS-only signing service, shell utility, private API, or platform trust
mechanism is introduced.
