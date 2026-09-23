/// The *index* slot is distinct from a CodeDirectory's negative hash slots.
/// Only slots whose structural assignment is established are named here.
/// Slots 1 and 3, for example, normally describe CodeDirectory hashes for
/// Info.plist and CodeResources, not embedded bytes in the SuperBlob.
enum CodeSignatureBlobType: Equatable, Hashable {
    case codeDirectory
    case alternateCodeDirectory(Int)
    case requirements
    case entitlements
    case derEntitlements
    case cms
    case other(UInt32)

    init(rawValue: UInt32) {
        switch rawValue {
        case 0: self = .codeDirectory
        case 2: self = .requirements
        case 5: self = .entitlements
        case 7: self = .derEntitlements
        case 0x1000..<0x1005: self = .alternateCodeDirectory(Int(rawValue - 0x1000))
        case 0x10000: self = .cms
        default: self = .other(rawValue)
        }
    }

    /// Canonical on-disk index value. Associated values are checked before
    /// narrowing; `.other` cannot disguise a known type.
    func encodedValue() throws -> UInt32 {
        switch self {
        case .codeDirectory: return 0
        case .requirements: return 2
        case .entitlements: return 5
        case .derEntitlements: return 7
        case .cms: return 0x10000
        case .alternateCodeDirectory(let index):
            guard (0..<5).contains(index) else {
                throw SuperBlobError.unsupportedBlobType
            }
            return 0x1000 + UInt32(index)
        case .other(let value):
            guard CodeSignatureBlobType(rawValue: value) == self else {
                throw SuperBlobError.unsupportedBlobType
            }
            return value
        }
    }

    var expectedMagic: UInt32? {
        switch self {
        case .codeDirectory, .alternateCodeDirectory: return CodeDirectory.magic
        case .requirements: return 0xFADE0C01
        case .entitlements: return 0xFADE7171
        case .derEntitlements: return 0xFADE7172
        case .cms: return 0xFADE0B01
        case .other: return nil
        }
    }

    var isCodeDirectory: Bool {
        switch self {
        case .codeDirectory, .alternateCodeDirectory: return true
        default: return false
        }
    }
}
