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
        guard ["p12", "pfx"].contains(source.pathExtension.lowercased()) else {
            throw PKCS12DocumentReadError.unsupportedFileType
        }

        let acquiredScope = source.startAccessingSecurityScopedResource()
        defer {
            if acquiredScope {
                source.stopAccessingSecurityScopedResource()
            }
        }

        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var result: Result<Data, PKCS12DocumentReadError>?
        coordinator.coordinate(readingItemAt: source, options: [], error: &coordinationError) { coordinatedURL in
            do {
                result = .success(try readBoundedFile(at: coordinatedURL))
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
