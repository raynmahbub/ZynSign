import Foundation

/// Structured failures raised while constructing, hashing, serializing, or
/// validating a CodeDirectory. Numeric values in these cases are format
/// metadata only; binary contents and identifier text are never retained.
enum CodeDirectoryError: Error, Equatable {
    case unsupportedVersion(UInt32)
    case invalidMagic(UInt32)
    case invalidHashType(UInt8)
    case unsupportedDigestAlgorithm(DigestAlgorithm)
    case invalidHashSize(expected: Int, actual: Int)
    case invalidHashConfiguration
    case invalidPageSize(UInt8)
    case nonPowerOfTwoPageSize(Int)
    case invalidCodeLimit
    case codeLimitExceedsAvailableBytes
    case invalidPageCount
    case invalidSlotCount
    case invalidSlotIndex
    case invalidHashLength
    case invalidIdentifier
    case invalidTeamIdentifier
    case unsupportedFeature(CodeDirectoryFeature)
    case invalidOffset(CodeDirectoryOffset)
    case invalidLength
    case overlappingRegions
    case integerOverflow
    case resourceLimitExceeded
    case digestAlgorithmMismatch
    case malformedBinary
}

enum CodeDirectoryFeature: Equatable {
    case teamIdentifier
    case derEntitlements
    case scatter
    case extendedCodeLimit
    case executableSegment
    case runtime
    case preEncryptionHashes
    case linkage
}

enum CodeDirectoryOffset: Equatable {
    case identifier
    case teamIdentifier
    case hashOffset
    case specialHashes
    case codeHashes
    case length
}
