import Foundation

/// Reads a selected `.p12` / `.pfx` through the file-provider contract instead
/// of assuming the URL is a directly readable local file. Security-scoped
/// access is acquired only for the coordinated read and is always released.
struct CoordinatedPKCS12DocumentReader: PKCS12DocumentReading {
    static let defaultMaximumByteCount = 10 * 1024 * 1024

    private let maximumByteCount: Int
    private let chunkSize: Int

    init(
        maximumByteCount: Int = CoordinatedPKCS12DocumentReader.defaultMaximumByteCount,
        chunkSize: Int = 64 * 1024
    ) {
        self.maximumByteCount = max(1, maximumByteCount)
        self.chunkSize = max(1, chunkSize)
    }

    func readPKCS12(at source: URL) throws -> Data {
        guard source.isFileURL else { throw PKCS12DocumentReadError.unreadable }
        // The extension decides nothing on its own. A matching name is enough
        // to read; a missing or foreign one is refused only after the
        // content — a PKCS#12 file is a DER `SEQUENCE`, so it begins with
        // 0x30 — says the document cannot be one. AirDrop renames, Files
        // strips extensions, and users re-save certificates under names of
        // their own; none of that can make a valid container unreadable.
        let extensionMatches = ["p12", "pfx"].contains(source.pathExtension.lowercased())
        if !extensionMatches, Self.knownNonCertificateExtensions.contains(source.pathExtension.lowercased()) {
            throw PKCS12DocumentReadError.unsupportedFileType
        }

        let acquiredScope = source.startAccessingSecurityScopedResource()
        defer {
            if acquiredScope {
                source.stopAccessingSecurityScopedResource()
            }
        }

        // A `.p12` kept in iCloud Drive is often a placeholder: its name and
        // size are on the device and its bytes are not, so every read answers
        // "empty" and the user is told their certificate file is empty. Ask
        // the provider for the content and wait, bounded, before coordinating
        // the read. The caller runs this off the interface thread, which is
        // what makes the wait available; `UbiquitousContentWait` says what
        // happens when it is not.
        UbiquitousContentWait.materialize(source)

        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var result: Result<Data, PKCS12DocumentReadError>?
        coordinator.coordinate(readingItemAt: source, options: [], error: &coordinationError) { coordinatedURL in
            do {
                let data = try readBoundedFile(at: coordinatedURL)
                if !extensionMatches, data.first != 0x30 {
                    result = .failure(.unsupportedFileType)
                } else {
                    result = .success(data)
                }
            } catch let error as PKCS12DocumentReadError {
                result = .failure(error)
            } catch {
                result = .failure(.unreadable)
            }
        }

        if let result {
            return try result.get()
        }
        if coordinationError != nil {
            throw PKCS12DocumentReadError.unreadable
        }
        throw PKCS12DocumentReadError.unreadable
    }

    /// Extensions that name a format ZynSign never reads as a certificate,
    /// refused by name alone. Anything else — an extension the reader does
    /// not know, or none at all — is decided by content.
    private static let knownNonCertificateExtensions: Set<String> = [
        "txt", "md", "rtf", "pdf", "doc", "docx", "json", "plist", "xml",
        "csv", "html", "png", "jpg", "jpeg", "heic", "gif", "tiff", "svg",
        "mp3", "m4a", "wav", "mp4", "mov", "zip", "rar", "7z", "tar", "gz",
        "ipa", "tipa", "mobileprovision", "provisionprofile", "app", "framework",
        "dylib", "pem", "key", "crt", "cer", "der",
    ]

    private func readBoundedFile(at url: URL) throws -> Data {
        let values: URLResourceValues
        do {
            values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey])
        } catch {
            throw PKCS12DocumentReadError.unreadable
        }
        guard values.isDirectory != true, values.isRegularFile != false else {
            throw PKCS12DocumentReadError.unreadable
        }
        if let size = values.fileSize, size > maximumByteCount {
            throw PKCS12DocumentReadError.fileTooLarge
        }

        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw PKCS12DocumentReadError.unreadable
        }
        defer { try? handle.close() }

        var data = Data()
        while true {
            let bytesUntilLimit = maximumByteCount - data.count + 1
            let readCount = min(chunkSize, bytesUntilLimit)
            let chunk: Data
            do {
                chunk = try handle.read(upToCount: readCount) ?? Data()
            } catch {
                throw PKCS12DocumentReadError.unreadable
            }
            if chunk.isEmpty { break }
            guard chunk.count <= maximumByteCount - data.count else {
                throw PKCS12DocumentReadError.fileTooLarge
            }
            data.append(chunk)
        }

        guard !data.isEmpty else { throw PKCS12DocumentReadError.emptyFile }
        return data
    }
}
