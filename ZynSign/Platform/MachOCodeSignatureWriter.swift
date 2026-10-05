import Foundation

/// Result of one deliberately narrow append mutation. `modifiedByteRanges`
/// identifies the only pre-existing bytes the writer changes; the final range
/// is the newly appended data and is outside the source file.
struct MachOCodeSignatureMutationResult: Equatable {
    let bytes: Data
    let layout: MachOCodeSignatureRegionLayout
    let loadCommandFields: MachOCodeSignatureLoadCommandFields
    let signedCodeLimit: UInt64
    let modifiedByteRanges: [Range<Int>]
}

/// Immutable finalized hashed prefix. Only the writer can create this token.
struct MachOCodeSignaturePreparation {
    let prefix: Data
    let layout: MachOCodeSignatureRegionLayout
    let loadCommandFields: MachOCodeSignatureLoadCommandFields
    let signedCodeLimit: UInt64
    let modifiedByteRanges: [Range<Int>]

    fileprivate init(prefix: Data, layout: MachOCodeSignatureRegionLayout,
                     loadCommandFields: MachOCodeSignatureLoadCommandFields,
                     signedCodeLimit: UInt64, modifiedByteRanges: [Range<Int>]) {
        self.prefix = prefix
        self.layout = layout
        self.loadCommandFields = loadCommandFields
        self.signedCodeLimit = signedCodeLimit
        self.modifiedByteRanges = modifiedByteRanges
    }
}

/// Appends a structurally valid SuperBlob region to one thin Mach-O image only.
/// Construction (`SignatureSuperBlob` -> `MachOCodeSignatureRegion`) is kept
/// separate from this mutation boundary. This type neither constructs a
/// CodeDirectory nor signs, verifies, or evaluates any cryptographic data.
struct MachOCodeSignatureWriter {
    /// The parser bounds input at 256 MiB. The append path currently owns an
    /// in-memory source and destination, so its output bound is explicit
    /// instead of allowing a hostile request to force an uncontrolled copy.
    static let maximumResultingFileBytes = 512 * 1_024 * 1_024

    private let parser: any MachOParsing

    init(parser: any MachOParsing = ReadOnlyMachOParser()) {
        self.parser = parser
    }

    /// Appends a new region when the image has no code-signature command.
    /// Existing valid signatures are rejected by the default policy; explicit
    /// replacement remains unsupported. `signedCodeLimit` is supplied rather
    /// than inferred from the file length so the signature bytes cannot become
    /// accidental CodeDirectory page-hash input.
    func append(
        _ region: MachOCodeSignatureRegion,
        to bytes: Data,
        signedCodeLimit: UInt64,
        existingSignaturePolicy: MachOExistingCodeSignaturePolicy = .rejectExistingSignature
    ) throws -> MachOCodeSignatureMutationResult {
        let preparation = try prepare(
            bytes, serializedSuperBlobLength: region.serializedSuperBlobLength,
            signedCodeLimit: signedCodeLimit, existingSignaturePolicy: existingSignaturePolicy)
        return try finalize(preparation, region: region)
    }

    /// Resolves every hashed field before a private signing operation. No
    /// placeholder signature is emitted and no file is persisted.
    func prepare(
        _ bytes: Data,
        serializedSuperBlobLength: Int,
        signedCodeLimit: UInt64,
        existingSignaturePolicy: MachOExistingCodeSignaturePolicy
    ) throws -> MachOCodeSignaturePreparation {
        let slice = try validatedSlice(
            bytes,
            serializedSuperBlobLength: serializedSuperBlobLength,
            existingSignaturePolicy: existingSignaturePolicy
        )
        let appendLayout = try preparedAppendLayout(
            serializedLength: serializedSuperBlobLength,
            fileLength: bytes.count,
            signedCodeLimit: signedCodeLimit
        )
        let requiredCommandEnd = try validatedLoadCommandPadding(in: slice, source: bytes)
        let linkEdit = try validatedLinkEditSegment(
            in: slice,
            sourceFileLength: bytes.count,
            resultingFileLength: appendLayout.layout.resultingFileLength
        )
        let updatedFields = try updatedLoadCommandFields(for: slice)
        let prefix = try makePreparedPrefix(
            bytes,
            slice: slice,
            layout: appendLayout.layout,
            fields: appendLayout.fields,
            requiredCommandEnd: requiredCommandEnd,
            linkEdit: linkEdit,
            updatedFields: updatedFields
        )
        let modifiedRanges = [
            16..<20,
            20..<24,
            slice.loadCommandsEndOffset..<requiredCommandEnd,
            linkEdit.segment.fileSizeFieldRange,
            bytes.count..<appendLayout.layout.resultingFileLength
        ]
        return MachOCodeSignaturePreparation(
            prefix: prefix,
            layout: appendLayout.layout,
            loadCommandFields: appendLayout.fields,
            signedCodeLimit: signedCodeLimit,
            modifiedByteRanges: modifiedRanges
        )
    }

    private struct PreparedAppendLayout {
        let layout: MachOCodeSignatureRegionLayout
        let fields: MachOCodeSignatureLoadCommandFields
    }

    private struct UpdatedLoadCommandFields {
        let count: UInt32
        let byteCount: UInt32
    }

    private func validatedSlice(
        _ bytes: Data,
        serializedSuperBlobLength: Int,
        existingSignaturePolicy: MachOExistingCodeSignaturePolicy
    ) throws -> MachOSlice {
        guard bytes.startIndex == 0 else { throw MachOCodeSignatureRegionError.invalidFileLength }
        guard serializedSuperBlobLength > 0 else { throw MachOCodeSignatureRegionError.invalidLength }
        guard serializedSuperBlobLength <= SignatureSuperBlob.maximumSerializedLength else {
            throw MachOCodeSignatureRegionError.resourceLimitExceeded
        }
        let image = try parseForMutation(bytes)
        guard case .thin(let slice) = image.container else {
            throw MachOCodeSignatureRegionError.universalImageUnsupported
        }
        guard slice.fileRange == 0..<bytes.count else {
            throw MachOCodeSignatureRegionError.inconsistentMutation
        }
        guard slice.embeddedSignature == nil else {
            switch existingSignaturePolicy {
            case .rejectExistingSignature:
                throw MachOCodeSignatureRegionError.existingSignatureRejected
            case .replaceExistingSignature:
                throw MachOCodeSignatureRegionError.replacementUnsupported
            }
        }
        return slice
    }

    private func preparedAppendLayout(
        serializedLength: Int,
        fileLength: Int,
        signedCodeLimit: UInt64
    ) throws -> PreparedAppendLayout {
        let layout = try MachOCodeSignatureRegionLayout(
            appendingSerializedSuperBlobLength: serializedLength,
            toFileLength: fileLength
        )
        try layout.validate(signedCodeLimit: signedCodeLimit)
        guard layout.resultingFileLength <= Self.maximumResultingFileBytes else {
            throw MachOCodeSignatureRegionError.resourceLimitExceeded
        }
        return PreparedAppendLayout(layout: layout, fields: try layout.loadCommandFields())
    }

    private func validatedLoadCommandPadding(
        in slice: MachOSlice,
        source bytes: Data
    ) throws -> Int {
        let (requiredEnd, overflow) = slice.loadCommandsEndOffset.addingReportingOverflow(16)
        guard !overflow else { throw MachOCodeSignatureRegionError.integerOverflow }
        guard let firstFileBackedContentOffset = slice.firstFileBackedContentOffset else {
            throw MachOCodeSignatureRegionError.missingLoadCommandCapacityBoundary
        }
        guard requiredEnd <= firstFileBackedContentOffset else {
            throw MachOCodeSignatureRegionError.insufficientLoadCommandCapacity(
                requiredEndOffset: requiredEnd,
                firstFileBackedContentOffset: firstFileBackedContentOffset
            )
        }
        let padding = slice.loadCommandsEndOffset..<requiredEnd
        guard padding.upperBound <= bytes.count,
              bytes[padding].allSatisfy({ $0 == 0 }) else {
            throw MachOCodeSignatureRegionError.nonZeroLoadCommandPadding
        }
        return requiredEnd
    }

    private func updatedLoadCommandFields(for slice: MachOSlice) throws -> UpdatedLoadCommandFields {
        UpdatedLoadCommandFields(
            count: try checkedUInt32(slice.header.loadCommandCount + 1, narrowingError: .inconsistentMutation),
            byteCount: try checkedUInt32(slice.header.loadCommandsSize + 16, narrowingError: .inconsistentMutation)
        )
    }

    private func makePreparedPrefix(
        _ bytes: Data,
        slice: MachOSlice,
        layout: MachOCodeSignatureRegionLayout,
        fields: MachOCodeSignatureLoadCommandFields,
        requiredCommandEnd: Int,
        linkEdit: ValidatedLinkEdit,
        updatedFields: UpdatedLoadCommandFields
    ) throws -> Data {
        var output = Data()
        output.reserveCapacity(layout.offset)
        output.append(bytes)
        if layout.prefixPaddingLength > 0 {
            output.append(Data(repeating: 0, count: layout.prefixPaddingLength))
        }
        guard output.count == layout.offset else {
            throw MachOCodeSignatureRegionError.inconsistentMutation
        }
        try writeLoadCommandFields(updatedFields, at: slice.loadCommandsEndOffset, fields: fields, order: slice.header.byteOrder, into: &output)
        try writeLinkEditFileSize(linkEdit, order: slice.header.byteOrder, into: &output)
        guard requiredCommandEnd <= output.count else {
            throw MachOCodeSignatureRegionError.inconsistentMutation
        }
        return output
    }

    private func writeLoadCommandFields(
        _ updated: UpdatedLoadCommandFields,
        at commandOffset: Int,
        fields: MachOCodeSignatureLoadCommandFields,
        order: MachOByteOrder,
        into output: inout Data
    ) throws {
        try replaceUInt32(updated.count, at: 16, order: order, in: &output)
        try replaceUInt32(updated.byteCount, at: 20, order: order, in: &output)
        try replaceUInt32(MachOLoadCommandType.codeSignature, at: commandOffset, order: order, in: &output)
        try replaceUInt32(16, at: commandOffset + 4, order: order, in: &output)
        try replaceUInt32(fields.dataOffset, at: commandOffset + 8, order: order, in: &output)
        try replaceUInt32(fields.dataSize, at: commandOffset + 12, order: order, in: &output)
    }

    private func writeLinkEditFileSize(
        _ linkEdit: ValidatedLinkEdit,
        order: MachOByteOrder,
        into output: inout Data
    ) throws {
        switch linkEdit.wordSize {
        case .bits32:
            guard let fileSize = UInt32(exactly: linkEdit.newFileSize) else {
                throw MachOCodeSignatureRegionError.unsafeLinkEditLayout
            }
            try replaceUInt32(fileSize, at: linkEdit.segment.fileSizeFieldRange.lowerBound, order: order, in: &output)
        case .bits64:
            try replaceUInt64(
                UInt64(linkEdit.newFileSize),
                at: linkEdit.segment.fileSizeFieldRange.lowerBound,
                order: order,
                in: &output
            )
        }
    }

    /// Finishing cannot resize or rewrite the prepared prefix. A size mismatch
    /// fails, rather than retrying the private signing operation.
    func finalize(_ preparation: MachOCodeSignaturePreparation,
                  region: MachOCodeSignatureRegion) throws -> MachOCodeSignatureMutationResult {
        let layout = preparation.layout
        guard preparation.prefix.count == layout.offset,
              region.serializedSuperBlobLength == layout.serializedSuperBlobLength,
              region.dataSize == layout.size else {
            throw MachOCodeSignatureRegionError.inconsistentRegion
        }
        var output = preparation.prefix
        output.append(region.bytes)
        try validateWrittenOutput(output, expectedLayout: layout,
                                  expectedFields: preparation.loadCommandFields,
                                  expectedSerializedSuperBlob: region.serializedSuperBlob)
        return MachOCodeSignatureMutationResult(
            bytes: output, layout: layout, loadCommandFields: preparation.loadCommandFields,
            signedCodeLimit: preparation.signedCodeLimit,
            modifiedByteRanges: preparation.modifiedByteRanges)
    }

    private func parseForMutation(_ bytes: Data) throws -> MachOImage {
        do {
            return try parser.parse(bytes)
        } catch let error as MachOParsingError {
            if let state = MachOExistingCodeSignatureState.classify(error) {
                throw MachOCodeSignatureRegionError.malformedExistingSignature(state)
            }
            throw MachOCodeSignatureRegionError.malformedMachO(error)
        } catch {
            throw MachOCodeSignatureRegionError.inconsistentMutation
        }
    }

    private struct ValidatedLinkEdit {
        let segment: MachOSegment
        let wordSize: MachOWordSize
        let newFileSize: Int
    }

    /// No segment is relocated or resized in virtual memory. The narrow writer
    /// proceeds only when an existing `__LINKEDIT` mapping already has enough
    /// virtual-memory capacity for the extended file range.
    private func validatedLinkEditSegment(
        in slice: MachOSlice,
        sourceFileLength: Int,
        resultingFileLength: Int
    ) throws -> ValidatedLinkEdit {
        let linkEditSegments = slice.segments.filter(\.isLinkEdit)
        guard !linkEditSegments.isEmpty else {
            throw MachOCodeSignatureRegionError.missingLinkEditSegment
        }
        guard linkEditSegments.count == 1, let segment = linkEditSegments.first else {
            throw MachOCodeSignatureRegionError.ambiguousLinkEditSegment
        }
        guard let fileOffset = Int(exactly: segment.fileOffset),
              let fileSize = Int(exactly: segment.fileSize),
              fileOffset >= 0,
              fileOffset <= sourceFileLength,
              fileSize <= sourceFileLength - fileOffset else {
            throw MachOCodeSignatureRegionError.unsafeLinkEditLayout
        }
        let (currentEnd, currentEndOverflow) = fileOffset.addingReportingOverflow(fileSize)
        guard !currentEndOverflow, currentEnd == sourceFileLength else {
            throw MachOCodeSignatureRegionError.unsafeLinkEditLayout
        }
        guard segment.fileSize <= segment.virtualMemorySize,
              resultingFileLength >= fileOffset else {
            throw MachOCodeSignatureRegionError.unsafeLinkEditLayout
        }
        let newFileSize = resultingFileLength - fileOffset
        guard UInt64(newFileSize) <= segment.virtualMemorySize else {
            throw MachOCodeSignatureRegionError.unsafeLinkEditLayout
        }
        return ValidatedLinkEdit(
            segment: segment,
            wordSize: segment.wordSize,
            newFileSize: newFileSize
        )
    }

    private func validateWrittenOutput(
        _ bytes: Data,
        expectedLayout: MachOCodeSignatureRegionLayout,
        expectedFields: MachOCodeSignatureLoadCommandFields,
        expectedSerializedSuperBlob: Data
    ) throws {
        let image: MachOImage
        do {
            image = try parser.parse(bytes)
        } catch let error as MachOParsingError {
            throw MachOCodeSignatureRegionError.outputValidationFailed(error)
        } catch {
            throw MachOCodeSignatureRegionError.inconsistentMutation
        }
        guard case .thin(let slice) = image.container,
              let signature = slice.embeddedSignature,
              signature.command.dataOffset == Int(expectedFields.dataOffset),
              signature.command.dataSize == Int(expectedFields.dataSize),
              signature.command.fileRange == expectedLayout.offset..<expectedLayout.endOffset,
              signature.superBlob.length == expectedSerializedSuperBlob.count,
              expectedLayout.offset <= bytes.count,
              expectedSerializedSuperBlob.count <= bytes.count - expectedLayout.offset,
              bytes.subdata(in: expectedLayout.offset..<(expectedLayout.offset + expectedSerializedSuperBlob.count))
                == expectedSerializedSuperBlob else {
            throw MachOCodeSignatureRegionError.inconsistentMutation
        }
    }

    private func checkedUInt32(
        _ value: Int,
        narrowingError: MachOCodeSignatureRegionError
    ) throws -> UInt32 {
        guard value >= 0, let result = UInt32(exactly: value) else {
            throw narrowingError
        }
        return result
    }

    /// Fixed-field mutation after parser validation. This is intentionally not
    /// a second general-purpose binary writer: each offset comes from a parsed
    /// Mach-O model or from the checked append layout above.
    private func replaceUInt32(
        _ value: UInt32,
        at offset: Int,
        order: MachOByteOrder,
        in bytes: inout Data
    ) throws {
        try replace(
            encodedBytes(of: UInt64(value), width: 4, order: order),
            at: offset,
            in: &bytes
        )
    }

    private func replaceUInt64(
        _ value: UInt64,
        at offset: Int,
        order: MachOByteOrder,
        in bytes: inout Data
    ) throws {
        try replace(encodedBytes(of: value, width: 8, order: order), at: offset, in: &bytes)
    }

    private func replace(_ replacement: [UInt8], at offset: Int, in bytes: inout Data) throws {
        guard offset >= 0, offset <= bytes.count,
              replacement.count <= bytes.count - offset else {
            throw MachOCodeSignatureRegionError.inconsistentMutation
        }
        bytes.replaceSubrange(offset..<(offset + replacement.count), with: replacement)
    }

    private func encodedBytes(of value: UInt64, width: Int, order: MachOByteOrder) -> [UInt8] {
        var result: [UInt8] = []
        result.reserveCapacity(width)
        for index in 0..<width {
            let shift = order == .bigEndian ? (width - 1 - index) * 8 : index * 8
            result.append(UInt8(truncatingIfNeeded: value >> shift))
        }
        return result
    }
}
