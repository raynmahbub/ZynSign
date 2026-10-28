import Foundation

/// Reads a selected `.p12` / `.pfx` through the file-provider contract instead
/// of assuming the URL is a directly readable local file. Security-scoped
/// access is acquired only for the read and is always released.
///
/// **Content decides, never the name.** The extension is not consulted: a
/// certificate that AirDrop renamed, that Files saved without one, that a
/// browser downloaded as `.download`, or that a person re-saved under a name of
/// their own is read exactly like one called `Identity.p12`, and a text file
/// that was renamed to `.p12` is refused for what it contains rather than for
/// what it is called. The rule is the same in both directions, which is the
/// only version of it that can be explained to the person holding the file.
///
/// **Coordination is an optimisation, not a permission.** The coordinated read
/// is tried first because that is the route Files and iCloud providers
/// publish, and the direct read of the same bytes follows it. A coordinator
/// that cannot run, that reports a provider error, or that hands over an
/// accessor which reads nothing is answered by reading the document directly;
/// refusing on the first attempt is how a certificate the app could plainly
/// read came back as unreadable. Only a direct read that also fails is a
/// refusal, and it carries the coordinator's own reason when that reason is
/// one a person can act on.
///
/// **An encoded container is unwrapped, not refused.** Some tools hand out a
/// certificate as Base64 — bare, or wrapped in the familiar `BEGIN`/`END`
/// lines — while the platform's importer accepts only the binary container.
/// Both are unwrapped here, so the password form is reached with the bytes the
/// importer needs, and a document that decodes to nothing recognisable is
/// still refused by content.
struct CoordinatedPKCS12DocumentReader: PKCS12DocumentReading {
    static let defaultMaximumByteCount = 10 * 1024 * 1024

    /// The first byte of every DER `SEQUENCE`, which is what a PKCS#12
    /// container is. Nothing else can begin a binary container.
    private static let derSequenceTag: UInt8 = 0x30

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

        let acquiredScope = source.startAccessingSecurityScopedResource()
        defer {
            if acquiredScope {
                source.stopAccessingSecurityScopedResource()
            }
        }

        // A `.p12` kept in iCloud Drive is often a placeholder: its name and
        // size are on the device and its bytes are not, so every read answers
        // "empty" and the user is told their certificate file is empty. Ask
        // the provider for the content and wait, bounded, before reading. The
        // caller runs this off the interface thread, which is what makes the
        // wait available; `UbiquitousContentWait` says what happens when it is
        // not.
        UbiquitousContentWait.materialize(source)

        let data = try readThroughBestRoute(at: source)
        return try Self.container(from: data, maximumByteCount: maximumByteCount)
    }

    // MARK: - Reading

    /// Reads the document through coordination when that works and directly
    /// otherwise, reporting the refusal that says the most about what was
    /// wrong.
    private func readThroughBestRoute(at source: URL) throws -> Data {
        let coordinated = coordinatedRead(at: source)
        if case .success(let data) = coordinated {
            return data
        }

        do {
            return try readBoundedFile(at: source)
        } catch let direct as PKCS12DocumentReadError {
            // Both routes failed. The coordinated answer is preferred when it
            // names something a person can act on — an oversized or empty
            // document is an observation about the bytes, not about the route
            // — and the direct failure is reported otherwise.
            if let coordinatedRefusal = coordinated.refusal,
               coordinatedRefusal != .unreadable {
                throw coordinatedRefusal
            }
            throw direct
        }
    }

    private func coordinatedRead(at source: URL) -> Result<Data, PKCS12DocumentReadError> {
        var coordinationError: NSError?
        var outcome: Result<Data, PKCS12DocumentReadError>?
        let coordinator = NSFileCoordinator(filePresenter: nil)
        coordinator.coordinate(readingItemAt: source, options: [], error: &coordinationError) { coordinatedURL in
            do {
                outcome = .success(try readBoundedFile(at: coordinatedURL))
            } catch let error as PKCS12DocumentReadError {
                outcome = .failure(error)
            } catch {
                outcome = .failure(.unreadable)
            }
        }
        if let outcome {
            return outcome
        }
        // The accessor never ran: the coordinator itself refused, and that
        // refusal is not a verdict about the document. Its own error explains
        // the attempt in the diagnostic that the direct read may replace.
        _ = coordinationError
        return .failure(.unreadable)
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

    // MARK: - Content

    /// The binary container carried by `data`, unwrapping an encoded one.
    ///
    /// The binary form is what the platform's importer accepts, so it is
    /// returned unchanged when the document already is one. Otherwise the
    /// document is read as text, its `BEGIN`/`END` lines (if any) are dropped,
    /// and the remaining Base64 is decoded: a container handed out as text is
    /// still the container the person selected. Anything else is not a
    /// PKCS#12 document, and says so.
    private static func container(from data: Data, maximumByteCount: Int) throws -> Data {
        let binary = trimmingLeadingFiller(data)
        if binary.first == derSequenceTag {
            return binary
        }
        if let encoded = decodedContainer(from: binary, maximumByteCount: maximumByteCount) {
            return encoded
        }
        throw PKCS12DocumentReadError.unsupportedFileType
    }

    /// The document with any leading whitespace, byte-order mark, or NUL
    /// padding removed, so a container behind filler is still recognised.
    private static func trimmingLeadingFiller(_ data: Data) -> Data {
        let filler: Set<UInt8> = [0x00, 0x09, 0x0A, 0x0D, 0x20]
        var start = data.startIndex
        // A UTF-8 byte-order mark is three bytes of its own.
        if data.count >= 3, data[data.startIndex] == 0xEF, data[data.startIndex + 1] == 0xBB,
           data[data.startIndex + 2] == 0xBF {
            start = data.index(start, offsetBy: 3)
        }
        while start < data.endIndex, filler.contains(data[start]) {
            start = data.index(after: start)
        }
        return data[start...]
    }

    /// The container carried as Base64 text, or `nil` when the document is not
    /// that.
    private static func decodedContainer(from data: Data, maximumByteCount: Int) -> Data? {
        // An encoded container is longer than the container it carries, and it
        // is text: anything that cannot be read as UTF-8 with printable
        // characters is binary and has already been refused.
        guard !data.isEmpty, data.count <= maximumByteCount * 2 else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        guard text.unicodeScalars.allSatisfy({ $0.isASCII && ($0.properties.isWhitespace || $0.value >= 0x20) }) else {
            return nil
        }
        let body = text
            .split(whereSeparator: \.isNewline)
            .filter { !$0.hasPrefix("-----") }
            .joined()
        if let armored = Data(base64Encoded: body) {
            // A container is a DER `SEQUENCE`; nothing else may be unwrapped,
            // or a stray Base64 text file would reach the importer as bytes.
            if armored.first == derSequenceTag, armored.count <= maximumByteCount {
                return armored
            }
            return nil
        }
        // Tolerate a body split across lines without the armor lines ever
        // being present.
        let compact = text.split(whereSeparator: \.isWhitespace).joined()
        guard let compacted = Data(base64Encoded: compact),
              compacted.first == derSequenceTag,
              compacted.count <= maximumByteCount else {
            return nil
        }
        return compacted
    }
}

private extension Result where Failure == PKCS12DocumentReadError {

    /// The refusal this result carries, when it carries one.
    var refusal: PKCS12DocumentReadError? {
        if case .failure(let error) = self { return error }
        return nil
    }
}
