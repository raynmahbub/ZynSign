/// Construction failures contain format metadata only, never blob contents.
/// Untrusted binary inspection continues to use MachOParsingError from the
/// existing bounded parser; CodeDirectory failures keep CodeDirectoryError.
enum SuperBlobError: Error, Equatable {
    case invalidLength
    case invalidBlobCount
    case duplicateBlobType(UInt32)
    case unsupportedBlobType
    case invalidBlobMagic(expected: UInt32, actual: UInt32)
    case codeDirectoryRequiresTypedConstruction
    case invalidOffset
    case inconsistentSerialization
    case integerOverflow
    case resourceLimitExceeded
}
