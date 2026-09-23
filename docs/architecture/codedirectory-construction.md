# CodeDirectory construction (ZS-023)

## Boundary

This increment constructs a value-owned CodeDirectory blob and computes its
ordinary code-page hashes. It does not construct a SuperBlob, write an
`LC_CODE_SIGNATURE` command, modify a Mach-O image, generate CMS, or create
requirements, entitlements, or CodeResources. A constructed blob is format
output only; it is not evidence of Apple acceptance, authorization, or a valid
complete code signature.

## Format evidence

The field layout and constants were checked against the following public Apple
sources before implementation:

- **Verified — format:** [XNU `cs_blobs.h`](https://github.com/apple-oss-distributions/xnu/blob/main/osfmk/kern/cs_blobs.h)
  defines the CodeDirectory magic, big-endian field vocabulary, version
  milestones, hash-type values, slot numbers, and fixed-width fields.
- **Verified — structural rules:** [Security `codedirectory.h`](https://github.com/apple-oss-distributions/Security/blob/main/OSX/libsecurity_codesigning/lib/codedirectory.h)
  describes the negative special-slot region and the hash array beginning at
  slot zero.
- **Verified — validation behavior:** [Security `codedirectory.cpp`](https://github.com/apple-oss-distributions/Security/blob/main/OSX/libsecurity_codesigning/lib/codedirectory.cpp)
  checks version support, interior offsets, special/code hash bounds, and the
  relationship between `codeLimit`, `pageSize`, and `nCodeSlots`.
- **Verified — concepts:** [TN3126: Inside Code Signing: Hashes](https://developer.apple.com/documentation/technotes/tn3126-inside-code-signing-hashes)
  describes per-page hashes, negative special slots, independently signed
  architectures, and CodeDirectory hashes. Its examples are macOS examples;
  it does not demonstrate ZynSign output on iOS or iPadOS.

## Supported construction subset

The constructor deliberately supports the smallest versions needed by the
current boundary:

- `0x20001` with its 44-byte fixed header and no team-identifier field;
- `0x20200` with its 52-byte fixed header and an optional team-identifier
  field. The scatter offset in this version is emitted as zero.

The parser can describe later versions, but construction of `0x20100`,
`0x20300` through `0x20600`, and any unknown version is unsupported here. The
constructor does not guess values for scatter vectors, extended code limits,
executable-segment metadata, runtime values, pre-encryption hashes, or linkage
metadata.

The supported CodeDirectory hash types are:

| CodeDirectory hash type | Digest algorithm | Stored bytes |
| --- | --- | ---: |
| SHA-1 (`1`) | SHA-1 | 20 |
| SHA-256 (`2`) | SHA-256 | 32 |
| truncated SHA-256 (`3`) | SHA-256 | 20 |
| SHA-384 (`4`) | SHA-384 | 48 |

SHA-512 is available through the generic ZS-021 digest foundation but has no
supported CodeDirectory hash type in this increment. Unsupported combinations
are errors, never substitutions.

`pageSize` is encoded as a log2 exponent. Exponent zero is the format's
unpaged single-range form; an empty code region therefore uses that form and
has zero code slots. Paged construction accepts exponents 1 through 30 and
requires a nonzero code limit, so page sizes are powers of two and a
non-power-of-two byte size is rejected.
The implementation's resource policy bounds code slots at 65,536 and a
serialized CodeDirectory at 256 MiB. These are implementation limits, not
claims about Apple's maximums.

## Model and hash flow

`CodeDirectory` is separate from `MachOCodeDirectory`, the parser's structural
inspection model. The construction model explicitly carries version, flags,
identifier, team identifier, platform, hash configuration, page size, code
limit, special slots, and code slots. Special slots are represented by their
positive ordinal (`1` means serialized slot `-1`) and must be supplied
contiguously. An absent special hash is serialized as a zero placeholder; no
special-data blob is generated.

`CodeDirectoryConstructor` receives an explicit `codeLimit`, page size, hash
configuration, and code `Data`. `CodePageHasher` hashes only
`0..<codeLimit`, in ascending page order, and hashes a final partial page as
provided. A limit beyond the supplied bytes fails; bytes after the limit are
never read. The existing `MessageDigest` boundary from ZS-021 supplies the
actual digest implementation.

## Serialization and parsing relationship

`CodeDirectorySerializer` writes big-endian fields, NUL-terminated UTF-8
identifier strings, special hashes in serialized order `-n ... -1`, and then
ordinary code hashes `0 ... n-1`. It calculates and validates the blob length,
identifier/team offsets, special-hash start, and `hashOffset` before writing.
The result includes a `CodeDirectoryLayout` for later SuperBlob work, but no
SuperBlob is built here.

[ZS-024](superblob-construction.md) now consumes this serialization through
`CodeSignatureBlob.codeDirectory`, retains its bytes unchanged, and calculates
container placement without repeating CodeDirectory serialization. This does
not extend the construction versions or add alternate-hash generation.

The existing read-only parser remains responsible for interpreting supplied
bytes. It now preserves value-owned special and code hash bytes in addition to
its prior structural ranges, which permits an independently visible
constructor → serialization → parser comparison without making construction
reuse parser internals. The parser's existing malformed-input and bounds
checks remain separate from construction validation.

## Platform status

**Verified:** the project deployment setting is iOS/iPadOS 17.0 and the digest
implementation uses the existing CryptoKit boundary. **Unknown / requires
experiment:** whether any particular CodeDirectory version, flag set, special
slot population, or constructed signature is accepted by a target iOS or
iPadOS release. No platform acceptance or signing result is claimed by this
increment.
