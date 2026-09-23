# Mach-O code-signature region construction (ZS-025)

## Boundary and purpose

This increment establishes the domain and infrastructure required to construct
the embedded code-signature region of a Mach-O image and to bind it to a
deterministic, append-only file layout.

It preserves strict separation between:

1. **Mach-O parsing:** read-only structural inspection through the existing
   `ReadOnlyMachOParser` (ZS-022);
2. **Signature-region construction:** taking a validated, serialized SuperBlob
   (ZS-024) and framing it into an aligned `MachOCodeSignatureRegion` with
   explicit padding;
3. **Mach-O layout and mutation:** calculating offsets and resulting lengths in
   `MachOCodeSignatureRegionLayout` and performing append-only modification in
   `MachOCodeSignatureWriter`;
4. **Cryptographic signing:** deferred to later tasks (no private key, CMS
   generation, or digital signatures);
5. **Final verification:** separate future evaluation.

```text
CodeDirectory (ZS-023)
      ↓
SignatureSuperBlob (ZS-024)
      ↓
SuperBlobSerialization (ZS-024)
      ↓
MachOCodeSignatureRegion (ZS-025 construction)
      ↓
MachOCodeSignatureRegionLayout (ZS-025 layout)
      ↓
MachOCodeSignatureWriter (ZS-025 narrow append mutation)
```

**Presence or construction of a signature region does not establish
authenticity, certificate trust, authorization, or device acceptance.**

## Format evidence and alignment requirements

Public Apple tools and Darwin source distributions were analyzed before
designing the region layout:

- **Verified (format & alignment):** Apple's
  [`cctools/misc/codesign_allocate.c`](https://github.com/apple-oss-distributions/cctools/blob/main/misc/codesign_allocate.c)
  enforces that `datasize` for an architecture is a multiple of 16
  (`datasize % 16 == 0`), and in its standard allocation path calculates
  `dataoff` by rounding up the preceding linkedit end to a 16-byte boundary
  (`rnd32(linkedit_end, 16)`). It also contains a page-alignment mode (`-p`)
  for specific segment-aligned binaries.
- **Verified (format):** Apple's
  [`mach-o/loader.h`](https://github.com/apple-oss-distributions/cctools/blob/main/include/mach-o/loader.h)
  defines `LC_CODE_SIGNATURE` (`0x1D`) and the 16-byte `linkedit_data_command`
  containing 32-bit unsigned `dataoff` and `datasize`.
- **Verified (slice scope):** In universal/fat binaries, `dataoff` is relative
  to the start of the specific thin slice, not the outer fat file container.
- **Observed (Apple linkers and signers):** Trailing region bytes beyond the
  SuperBlob length (`datasize - SuperBlob.length`) are filled with zero bytes.
- **Inferred (conservative project policy):** Aligning `dataoff` to a 16-byte
  boundary and zero-padding `datasize` to a multiple of 16 satisfies the tool
  contract without manufacturing unwarranted page-padding slack.

Evidence classifications used:

- **Verified:** Checked against Apple's open-source implementations (`cctools`,
  `xnu`, `Security`) and published developer documentation.
- **Observed:** Checked against published tool output and binary inspection.
- **Inferred:** Conservative architectural rule chosen to avoid undefined
  platform behavior.
- **Unknown:** Target-device kernel acceptance criteria across iOS releases.
- **Requires experiment:** Physical device execution of locally mutated
  executables.

## Domain model and architecture

### Signature region construction

`MachOCodeSignatureRegion` accepts an independently validated
`SuperBlobSerialization`. It encapsulates:

- `serializedSuperBlob`: the exact byte sequence of the SuperBlob;
- `bytes`: the complete region data starting at `dataoff`, consisting of the
  serialized SuperBlob followed by deterministic zero padding to a 16-byte
  boundary;
- `trailingPaddingLength`: the count of trailing zero reserve bytes.

The region has no knowledge of the containing Mach-O executable, segments, or
signing identities.

### File layout model

`MachOCodeSignatureRegionLayout` models the arithmetic relationship between the
source file length and the appended region:

- `placement`: `.append`;
- `originalFileLength`: source byte count;
- `offset`: 16-byte-aligned `dataoff`;
- `size`: 16-byte-aligned `datasize`;
- `endOffset`: `offset + size`;
- `resultingFileLength`: total output size (`endOffset`);
- `prefixPaddingLength`: zero bytes inserted between the source file end and
  `offset` (if any);
- `trailingPaddingLength`: zero bytes appended after the SuperBlob;
- `loadCommandFields`: converts native integers into verified 32-bit unsigned
  `MachOCodeSignatureLoadCommandFields` (`dataOffset`, `dataSize`), rejecting
  overflow.

### Code limit relationship

The architecture strictly distinguishes:

- `CodeDirectory.codeLimit`: the byte range covered by the page-hash engine;
- `MachOFileLength`: the byte length of the binary.

The code limit represents executable code and data up to the signature offset.
`MachOCodeSignatureRegionLayout.validate(signedCodeLimit:)` verifies that
`signedCodeLimit <= UInt64(offset)`. The signature region itself must never be
included in the CodeDirectory's page-hash calculations.

## Existing signature analysis and policy

`MachOCodeSignatureInspector` uses `ReadOnlyMachOParser` to classify the
existing state of an image into explicit states:

1. `absent`: no `LC_CODE_SIGNATURE` command is present;
2. `valid`: an `LC_CODE_SIGNATURE` command references a structurally parseable
   SuperBlob within the slice;
3. `malformedCommand`: `cmdsize` != 16 or duplicate commands;
4. `invalidRegionOffset`: `dataoff` points before load commands or beyond the
   slice boundary;
5. `invalidRegionSize`: `datasize` is zero, out of range, or exceeds the slice;
6. `malformedRegion`: the SuperBlob header, table, or embedded blob frames are
   corrupted.

### Policy rules

- **Reject existing signature:** Default policy. If an existing valid signature
  is detected, mutation is rejected (`.existingSignatureRejected`).
- **Replace existing signature:** Unsupported in this increment. An explicit
  request for replacement returns `.replacementUnsupported`. Existing signatures
  are never silently overwritten or destroyed.
- **Malformed signatures:** A binary with a malformed existing signature is
  rejected (`.malformedExistingSignature`), not treated as an absent signature
  or an invitation to overwrite.

## Load command mutation boundary

Appending a signature region requires adding one 16-byte `LC_CODE_SIGNATURE`
command. Adding a load command expands the load-command array by 16 bytes.

To guarantee that existing code and data segments are never shifted, the writer
enforces:

1. The slice must contain verified zero padding between the end of existing
   load commands and the first file-backed segment/section content
   (`firstFileBackedContentOffset`);
2. The expanded load-command area (`sizeofcmds + 16`) must not exceed
   `firstFileBackedContentOffset`;
3. The 16 padding bytes to be overwritten must currently be all zero
   (`.nonZeroLoadCommandPadding`);
4. If capacity is insufficient, mutation fails with
   `.insufficientLoadCommandCapacity` rather than performing unsafe file-wide
   relocation.

Additionally, the writer verifies the presence of an existing `__LINKEDIT`
segment whose file extent covers the end of the input file, and ensures its
virtual-memory reservation (`vmsize`) can accommodate the extended file size
without segment remapping.

## Universal / Fat Mach-O policy

Universal Mach-O containers are parsed and inspected per-slice by
`MachOCodeSignatureInspector`.

However, universal binary mutation involves adjusting fat architecture table
offsets, slice alignments, and multiple slice payloads simultaneously. Because
universal container rebuilding is not part of this increment,
`MachOCodeSignatureWriter` explicitly returns:

`.universalImageUnsupported`

Thin binaries are fully supported for safe append mutation. Universal binaries
must not be silently treated as thin images.

## Byte preservation

When `MachOCodeSignatureWriter` appends a signature region, only five specific
byte ranges are modified:

1. `mach_header.ncmds` (incremented by 1);
2. `mach_header.sizeofcmds` (incremented by 16);
3. the 16 bytes immediately following existing load commands (populated with
   `LC_CODE_SIGNATURE`);
4. the `__LINKEDIT` segment command's `filesize` field;
5. the newly appended region bytes at the end of the file.

All other bytes—including executable code, data segments, symbol tables, and
unrelated load commands—are preserved byte-for-byte. Tests verify this invariant.

## Independent verification

Tests verify output through two independent paths:

1. **Independent structural assertions:** Byte offsets, endianness, load command
   fields, and zero padding are compared against literal bit-level expectations;
2. **Parser round-trip:** The mutated binary is re-parsed through the
   ZS-022 `ReadOnlyMachOParser` to verify that the slice, load commands, and
   embedded signature SuperBlob are recognized as structurally valid.
