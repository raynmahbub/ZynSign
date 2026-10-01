import Foundation

/// Application port for reading a user-selected PKCS#12 document. The
/// platform adapter owns security-scoped access and file-provider coordination.
protocol PKCS12DocumentReading: Sendable {
    func readPKCS12(at url: URL) throws -> Data
}

enum PKCS12DocumentReadError: Error, Equatable, Sendable {
    case unsupportedFileType
    case emptyFile
    case fileTooLarge
    case unreadable
}
