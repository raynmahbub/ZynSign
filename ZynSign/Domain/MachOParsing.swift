import Foundation

/// Only structural parsing failures. The boundary identifies the part that
/// could not be read; no input bytes, paths, or untrusted strings are retained.
struct MachOParsingError: Error, Equatable {
    enum Reason: Equatable {
        case unsupportedFormat
        case malformedHeader
        case truncatedInput
        case invalidOffset
        case invalidLength
        case invalidLoadCommand
        case malformedSignatureBlob
        case malformedSuperBlob
        case malformedCodeDirectory
        case unsupportedCodeDirectoryVersion
        case resourceLimitExceeded
    }

    enum Boundary: Equatable {
        case input
        case magic
        case header
        case architectureTable
        case architectureSlice
        case loadCommands
        case codeSignatureCommand
        case signatureRegion
        case superBlob
        case signatureBlob
        case codeDirectory
        case identifier
        case teamIdentifier
        case hashSlots
        case scatter
        case preEncryptHashes
        case linkage
    }

    let reason: Reason
    let boundary: Boundary
    /// The fat-table index, when the failure belongs to a particular slice.
    let architectureIndex: Int?
    /// Populated only for an unsupported CodeDirectory version.
    let version: UInt32?

    init(
        _ reason: Reason,
        at boundary: Boundary,
        architectureIndex: Int? = nil,
        version: UInt32? = nil
    ) {
        self.reason = reason
        self.boundary = boundary
        self.architectureIndex = architectureIndex
        self.version = version
    }

    func inArchitecture(_ index: Int) -> MachOParsingError {
        MachOParsingError(reason, at: boundary, architectureIndex: index, version: version)
    }
}

/// Pure read-only inspection of already supplied binary bytes. This port has
/// no filesystem, archive, platform, signing, or verification capability.
protocol MachOParsing {
    func parse(_ bytes: Data) throws -> MachOImage
}
