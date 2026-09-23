import Foundation

/// The physical code-signature region begins at a 16-byte-aligned `dataoff`
/// and contains one serialized SuperBlob followed only by deterministic zero
/// reserve bytes. It has no knowledge of an executable, load commands, a
/// signing identity, or a CodeDirectory code limit.
struct MachOCodeSignatureRegion: Equatable {
    /// Apple's `codesign_allocate` accepts a requested `datasize` only when it
    /// is a multiple of 16 and, in its normal (non-`-p`) path, rounds `dataoff`
    /// to 16 bytes. The region uses that documented-tool convention; it does
    /// not claim a target platform has accepted the resulting binary.
    static let alignment = 16

    /// Exact standalone SuperBlob bytes, without region reserve bytes.
    let serializedSuperBlob: Data
    /// Bytes written at `LC_CODE_SIGNATURE.dataoff`: SuperBlob then zero pad.
    let bytes: Data
    let trailingPaddingLength: Int

    init(serializedSuperBlob: SuperBlobSerialization) throws {
        guard serializedSuperBlob.bytes.count == serializedSuperBlob.layout.length,
              !serializedSuperBlob.bytes.isEmpty else {
            throw MachOCodeSignatureRegionError.invalidSerializedSuperBlob
        }
        do {
            try serializedSuperBlob.validate()
        } catch {
            throw MachOCodeSignatureRegionError.invalidSerializedSuperBlob
        }
        let paddedLength = try Self.roundedUp(
            serializedSuperBlob.bytes.count,
            to: Self.alignment
        )
        let paddingLength = paddedLength - serializedSuperBlob.bytes.count
        var regionBytes = Data()
        regionBytes.reserveCapacity(paddedLength)
        regionBytes.append(serializedSuperBlob.bytes)
        if paddingLength > 0 {
            regionBytes.append(Data(repeating: 0, count: paddingLength))
        }
        guard regionBytes.count == paddedLength else {
            throw MachOCodeSignatureRegionError.inconsistentRegion
        }
        self.serializedSuperBlob = serializedSuperBlob.bytes
        self.bytes = regionBytes
        self.trailingPaddingLength = paddingLength
    }

    var serializedSuperBlobLength: Int { serializedSuperBlob.count }
    var dataSize: Int { bytes.count }

    /// Binds this independently constructed region to an append-only file
    /// layout. It intentionally does not infer a CodeDirectory code limit.
    func layout(appendingToFileLength fileLength: Int) throws -> MachOCodeSignatureRegionLayout {
        let layout = try MachOCodeSignatureRegionLayout(
            appendingSerializedSuperBlobLength: serializedSuperBlobLength,
            toFileLength: fileLength
        )
        guard layout.size == dataSize,
              layout.trailingPaddingLength == trailingPaddingLength else {
            throw MachOCodeSignatureRegionError.inconsistentRegion
        }
        return layout
    }

    fileprivate static func roundedUp(_ value: Int, to alignment: Int) throws -> Int {
        guard value >= 0 else { throw MachOCodeSignatureRegionError.invalidLength }
        guard alignment > 0, alignment & (alignment - 1) == 0 else {
            throw MachOCodeSignatureRegionError.invalidAlignment
        }
        let remainder = value % alignment
        guard remainder != 0 else { return value }
        let (result, overflow) = value.addingReportingOverflow(alignment - remainder)
        guard !overflow else { throw MachOCodeSignatureRegionError.integerOverflow }
        return result
    }
}

/// The append-only relationship between a pre-mutation Mach-O file and one
/// region. All offset arithmetic lives here rather than in the writer.
struct MachOCodeSignatureRegionLayout: Equatable {
    enum Placement: Equatable {
        case append
    }

    let placement: Placement
    let originalFileLength: Int
    /// `LC_CODE_SIGNATURE.dataoff`, relative to the containing thin slice.
    let offset: Int
    /// `LC_CODE_SIGNATURE.datasize`, including only trailing zero reserve.
    let size: Int
    let endOffset: Int
    let resultingFileLength: Int
    let prefixPaddingLength: Int
    let serializedSuperBlobLength: Int
    let trailingPaddingLength: Int

    init(appendingSerializedSuperBlobLength serializedSuperBlobLength: Int, toFileLength fileLength: Int) throws {
        guard fileLength >= 0 else { throw MachOCodeSignatureRegionError.invalidFileLength }
        guard serializedSuperBlobLength > 0 else {
            throw MachOCodeSignatureRegionError.invalidLength
        }
        let offset = try MachOCodeSignatureRegion.roundedUp(
            fileLength,
            to: MachOCodeSignatureRegion.alignment
        )
        let size = try MachOCodeSignatureRegion.roundedUp(
            serializedSuperBlobLength,
            to: MachOCodeSignatureRegion.alignment
        )
        let (endOffset, overflow) = offset.addingReportingOverflow(size)
        guard !overflow else { throw MachOCodeSignatureRegionError.integerOverflow }
        self.placement = .append
        self.originalFileLength = fileLength
        self.offset = offset
        self.size = size
        self.endOffset = endOffset
        self.resultingFileLength = endOffset
        self.prefixPaddingLength = offset - fileLength
        self.serializedSuperBlobLength = serializedSuperBlobLength
        self.trailingPaddingLength = size - serializedSuperBlobLength
    }

    /// Converts only after every native-width computation completed. The Mach-O
    /// `linkedit_data_command` carries two 32-bit unsigned fields.
    func loadCommandFields() throws -> MachOCodeSignatureLoadCommandFields {
        guard let dataOffset = UInt32(exactly: offset) else {
            throw MachOCodeSignatureRegionError.unrepresentableDataOffset(offset)
        }
        guard let dataSize = UInt32(exactly: size), dataSize > 0 else {
            throw MachOCodeSignatureRegionError.unrepresentableDataSize(size)
        }
        return MachOCodeSignatureLoadCommandFields(dataOffset: dataOffset, dataSize: dataSize)
    }

    /// The code limit is supplied by the CodeDirectory construction boundary.
    /// It may include deterministic prefix padding, but it must never reach the
    /// signature region itself. It is intentionally not equated with file size.
    func validate(signedCodeLimit: UInt64) throws {
        guard signedCodeLimit <= UInt64(offset) else {
            throw MachOCodeSignatureRegionError.codeLimitOverlapsSignatureRegion(
                codeLimit: signedCodeLimit,
                signatureOffset: offset
            )
        }
    }
}

/// Exact fields to be encoded in a 16-byte `linkedit_data_command`. Keeping
/// this type UInt32-based makes narrowing deliberate and testable.
struct MachOCodeSignatureLoadCommandFields: Equatable {
    let dataOffset: UInt32
    let dataSize: UInt32
}

/// The state of an existing code-signature command as observed through the
/// established ZS-022 parser. A valid structure is not cryptographic evidence.
enum MachOExistingCodeSignatureState: Equatable {
    case absent
    case valid(MachOEmbeddedSignature)
    case malformedCommand(MachOParsingError)
    case invalidRegionOffset(MachOParsingError)
    case invalidRegionSize(MachOParsingError)
    case malformedRegion(MachOParsingError)

    static func classify(_ error: MachOParsingError) -> MachOExistingCodeSignatureState? {
        switch error.boundary {
        case .codeSignatureCommand:
            return .malformedCommand(error)
        case .signatureRegion:
            switch error.reason {
            case .invalidOffset:
                return .invalidRegionOffset(error)
            default:
                return .invalidRegionSize(error)
            }
        case .superBlob, .signatureBlob, .codeDirectory, .identifier,
             .teamIdentifier, .hashSlots, .scatter, .preEncryptHashes, .linkage:
            return .malformedRegion(error)
        default:
            return nil
        }
    }
}

/// One successfully parsed slice and its code-signature state. Universal
/// inspection supplies a non-nil architecture index; thin inspection does not.
struct MachOCodeSignatureSliceInspection: Equatable {
    let architectureIndex: Int?
    let slice: MachOSlice
    let existingSignature: MachOExistingCodeSignatureState
}

/// The code-signature-specific interpretation of an inspection result. This is
/// diagnostic structure, not a mutation request and not a verification result.
enum MachOCodeSignatureInspection: Equatable {
    case thin(MachOCodeSignatureSliceInspection)
    case universal([MachOCodeSignatureSliceInspection])
    case malformedSignature(architectureIndex: Int?, state: MachOExistingCodeSignatureState)
    case malformedMachO(MachOParsingError)
}

/// Replacement is deliberately a caller-visible choice. The writer implements
/// only append-if-absent today; an explicit replacement request is rejected,
/// never silently treated as permission to overwrite existing bytes.
enum MachOExistingCodeSignaturePolicy: Equatable {
    case rejectExistingSignature
    case replaceExistingSignature
}

/// Format and safety failures for region layout and the narrow append writer.
/// Cases retain only numeric layout facts and parser metadata, never artifact
/// payloads, paths, signing keys, certificates, or CMS data.
enum MachOCodeSignatureRegionError: Error, Equatable {
    case invalidSerializedSuperBlob
    case invalidFileLength
    case invalidLength
    case invalidAlignment
    case integerOverflow
    case resourceLimitExceeded
    case unrepresentableDataOffset(Int)
    case unrepresentableDataSize(Int)
    case codeLimitOverlapsSignatureRegion(codeLimit: UInt64, signatureOffset: Int)
    case inconsistentRegion
    case malformedMachO(MachOParsingError)
    case malformedExistingSignature(MachOExistingCodeSignatureState)
    case existingSignatureRejected
    case replacementUnsupported
    case universalImageUnsupported
    case missingLinkEditSegment
    case ambiguousLinkEditSegment
    case unsafeLinkEditLayout
    case missingLoadCommandCapacityBoundary
    case insufficientLoadCommandCapacity(requiredEndOffset: Int, firstFileBackedContentOffset: Int)
    case nonZeroLoadCommandPadding
    case outputValidationFailed(MachOParsingError)
    case inconsistentMutation
}
