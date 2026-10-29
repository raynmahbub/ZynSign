import Foundation

/// The body a transport delivered for one request.
///
/// The transport writes a declared body straight to a file rather than
/// holding it in memory: an `.ipa` is hundreds of megabytes, and an upload
/// bound that cannot be enforced without buffering is not a bound. The file
/// is the transport's own temporary file, and the service either moves it
/// into the transfer workspace or leaves it for the transport to delete.
enum LocalTransferIncomingBody: Equatable, Sendable {

    /// No body was sent.
    case none

    /// `byteCount` bytes are stored at the file URL.
    case file(URL, byteCount: Int)
}

/// One listening surface for local transfer.
///
/// The platform composes this; the service never learns whether the bytes
/// crossed Wi-Fi, a simulator's loopback, or a test double. Framing lives in
/// `LocalTransferHTTP`, the decision about what may be stored lives in
/// `LocalTransferService`, and only the socket lives in `Platform`.
protocol LocalTransferTransport: AnyObject, Sendable {

    /// Opens a listener and starts answering requests through `handling`.
    ///
    /// - Parameters:
    ///   - port: The TCP port to bind. `0` lets the system choose one.
    ///   - limits: The bounds the listener enforces while framing a request,
    ///     before any handler is asked anything.
    ///   - handling: The request handler. The transport awaits its answer and
    ///     writes it back, then closes the connection.
    /// - Returns: Where the listener actually bound.
    /// - Throws: A typed `ZynSignError` when the port is taken or the network
    ///   stack refuses the listener.
    func start(
        port: UInt16,
        limits: LocalTransferLimits,
        handling: @escaping @Sendable (LocalTransferHTTP.Request, LocalTransferIncomingBody) async -> LocalTransferHTTP.Response
    ) async throws -> LocalTransferEndpoint

    /// Closes the listener and every connection it accepted. Safe to call
    /// when nothing is listening.
    func stop() async
}

/// The local transfer service: one short-lived, token-gated way to put a file
/// on this device from another machine on the same network.
///
/// **What it is.** A foreground listener on a single port that answers three
/// things — a session page, and a raw-byte upload to a named destination —
/// and refuses everything else by name. It is not WebDAV, it does not browse
/// this device's file system, and it stops when the user stops it, when the
/// session's window closes, or when the app leaves the foreground (the
/// composition stops it there, because iOS does not keep this kind of
/// listener alive reliably in the background).
///
/// **What it refuses.** Every route requires the session token. Names are
/// reduced to one safe component or refused. Bodies are bounded before they
/// are read and never buffered whole. Requests are answered once and the
/// connection closed, so nothing here holds a conversation a client can
/// smuggle a second request into.
///
/// **What it never claims.** A received file is bytes in a workspace. It is
/// not imported, not inspected, and not signed; the Import Hub does that, and
/// says what it found.
actor LocalTransferService {

    /// The port a session binds unless the caller chooses another.
    static let defaultPort: UInt16 = 8_080

    /// A consistent view of the service for the interface.
    struct Snapshot: Equatable, Sendable {
        let state: LocalTransferState
        let limits: LocalTransferLimits
        let receipts: [LocalTransferReceipt]
        let requestCount: Int
        let rejectionCount: Int

        /// The token, when a session is open. The interface shows it, because
        /// the person who started the session is the person it is for.
        let token: String?

        /// The endpoint, when listening.
        var endpoint: LocalTransferEndpoint? {
            if case .listening(let endpoint, _) = state { return endpoint }
            return nil
        }

        var isListening: Bool { endpoint != nil }
    }

    private let stagingDirectory: URL
    private let limits: LocalTransferLimits
    private let random: any SecureRandomSource
    private let makeTransport: @Sendable () -> any LocalTransferTransport
    private let now: @Sendable () -> Date

    private var session: LocalTransferSession?
    private var transport: (any LocalTransferTransport)?
    private var state: LocalTransferState = .stopped
    private var receipts: [LocalTransferReceipt] = []
    private var requestCount = 0
    private var rejectionCount = 0

    /// Creates the service. Nothing listens until `start` is called, and no
    /// directory is created until then either.
    init(
        stagingDirectory: URL,
        limits: LocalTransferLimits = .standard,
        random: any SecureRandomSource,
        makeTransport: @escaping @Sendable () -> any LocalTransferTransport,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.stagingDirectory = stagingDirectory
        self.limits = limits
        self.random = random
        self.makeTransport = makeTransport
        self.now = now
    }

    // MARK: - Lifecycle

    /// Opens a session and starts listening.
    ///
    /// Starting an already-listening service does nothing and returns the
    /// current snapshot: a second tap does not open a second listener or mint
    /// a second token.
    func start(port: UInt16 = LocalTransferService.defaultPort) async -> Snapshot {
        if case .starting = state { return snapshot() }
        if case .listening(_, let expiresAt) = state {
            // A session whose window has closed is not "already listening":
            // it is stopped, and starting again opens a new one with a new
            // token rather than returning a snapshot that offers nothing.
            guard now() >= expiresAt else { return snapshot() }
            await stop()
        }

        state = .starting
        requestCount = 0
        rejectionCount = 0
        receipts = workspaceReceipts()

        let opened: LocalTransferSession
        do {
            opened = try LocalTransferSession.open(limits: limits, now: now(), random: random)
        } catch {
            state = .failed("ZynSign could not draw a session token, so nothing is listening.")
            return snapshot()
        }
        session = opened

        let transport = makeTransport()
        self.transport = transport
        do {
            let endpoint = try await transport.start(
                port: port,
                limits: limits,
                handling: { [weak self] request, body in
                    guard let self else {
                        return LocalTransferHTTP.Response.rejection(.notListening)
                    }
                    return await self.handle(request, body: body)
                }
            )
            state = .listening(endpoint, expiresAt: opened.expiresAt)
        } catch {
            self.transport = nil
            session = nil
            state = .failed(Self.message(for: error))
        }
        return snapshot()
    }

    /// Stops listening and discards the token. Received files stay in the
    /// workspace until the user removes them, so stopping the listener does
    /// not delete what already arrived.
    func stop() async {
        let transport = self.transport
        self.transport = nil
        session = nil
        state = .stopped
        await transport?.stop()
    }

    /// The current view, with an expired session reported as stopped without
    /// mutating anything.
    func snapshot() -> Snapshot {
        let current: LocalTransferState
        if case .listening(let endpoint, let expiresAt) = state, now() >= expiresAt {
            current = .stopped
        } else {
            current = state
        }
        return Snapshot(
            state: current,
            limits: limits,
            receipts: receipts,
            requestCount: requestCount,
            rejectionCount: rejectionCount,
            token: session?.token.value
        )
    }

    // MARK: - Received files

    /// Removes one received file from the workspace.
    ///
    /// - Returns: The new snapshot. A file that is already gone is not an
    ///   error: the record is dropped either way.
    func discard(_ id: UUID) -> Snapshot {
        guard let index = receipts.firstIndex(where: { $0.id == id }) else { return snapshot() }
        let receipt = receipts[index]
        let url = stagingDirectory.appendingPathComponent(receipt.fileName, isDirectory: false)
        try? FileManager.default.removeItem(at: url)
        receipts.remove(at: index)
        return snapshot()
    }

    /// Removes every received file from the workspace.
    func discardAll() -> Snapshot {
        for receipt in receipts {
            let url = stagingDirectory.appendingPathComponent(receipt.fileName, isDirectory: false)
            try? FileManager.default.removeItem(at: url)
        }
        receipts.removeAll()
        return snapshot()
    }

    /// The file URL of a received file, for the hand-off to the Import Hub.
    func fileURL(for id: UUID) -> URL? {
        guard let receipt = receipts.first(where: { $0.id == id }) else { return nil }
        return stagingDirectory.appendingPathComponent(receipt.fileName, isDirectory: false)
    }

    // MARK: - Handling

    /// Answers one request.
    ///
    /// Everything a request may cause is decided here: whether the session is
    /// still open, whether the token matches, whether the destination name is
    /// acceptable, and whether the bytes can be stored.
    func handle(
        _ request: LocalTransferHTTP.Request,
        body: LocalTransferIncomingBody
    ) async -> LocalTransferHTTP.Response {
        guard let session, case .listening = state else {
            return rejected(.notListening)
        }
        if session.isExpired(at: now()) {
            await stop()
            return rejected(.notListening)
        }
        requestCount += 1
        guard requestCount <= limits.maximumRequests else {
            return rejected(.requestBudgetExhausted)
        }

        guard let matched = route(of: request, session: session) else {
            return rejected(.unauthorized)
        }

        switch matched {
        case .statusPage:
            guard request.isReadOnly else { return rejected(.notFound) }
            return LocalTransferHTTP.Response.html(
                200,
                "OK",
                body: statusPage(session: session)
            )
        case .upload(let fileName):
            guard request.method == .put || request.method == .post else {
                return rejected(.notFound)
            }
            return store(body: body, as: fileName)
        case .unknown:
            return rejected(.notFound)
        }
    }

    /// What the request asked for, once the token is established.
    private enum Route: Equatable {
        case statusPage
        case upload(String)
        case unknown
    }

    /// The route `request` names, or `nil` when it did not carry the token.
    ///
    /// The token is accepted in the path (so a person can paste one URL) or as
    /// a bearer credential (so a script can keep it out of a URL). The path
    /// form is checked first because it is what the session page prints.
    private func route(
        of request: LocalTransferHTTP.Request,
        session: LocalTransferSession
    ) -> Route? {
        var components: [String] = request.path
            .split(separator: "/", omittingEmptySubsequences: true)
            .map { String($0) }
        if let first = components.first,
           let decoded = LocalTransferPercentDecoding.decode(first),
           session.token.matches(decoded) {
            components.removeFirst()
        } else if let bearer = Self.bearerToken(of: request), session.token.matches(bearer) {
            // Authenticated by header; the path carries no token.
        } else {
            return nil
        }

        guard let first = components.first else { return .statusPage }
        if first == "upload" {
            guard components.count == 2 else { return .unknown }
            let raw = components[1]
            guard let decoded = LocalTransferPercentDecoding.decode(raw) else { return .unknown }
            return .upload(decoded)
        }
        return .unknown
    }

    /// The bearer credential on `request`, when it carries one.
    private static func bearerToken(of request: LocalTransferHTTP.Request) -> String? {
        guard let header = request.header("authorization") else { return nil }
        let prefix = "Bearer "
        guard header.hasPrefix(prefix) else { return nil }
        let value = String(header.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }

    /// Stores the body of an upload, or says why it will not.
    private func store(body: LocalTransferIncomingBody, as fileName: String) -> LocalTransferHTTP.Response {
        guard case .file(let source, let byteCount) = body else { return rejected(.emptyPayload) }
        guard byteCount > 0 else {
            try? FileManager.default.removeItem(at: source)
            return rejected(.emptyPayload)
        }
        guard byteCount <= limits.maximumUploadBytes else {
            try? FileManager.default.removeItem(at: source)
            return rejected(.payloadTooLarge(limit: limits.maximumUploadBytes))
        }
        // The name is re-checked here even when the route already produced an
        // accepted one: this is the only function that writes, and it does not
        // depend on its caller having validated anything.
        guard let name = LocalTransferFileName.accepted(fileName) else {
            try? FileManager.default.removeItem(at: source)
            return rejected(.filenameRejected(fileName))
        }

        let fileManager = FileManager.default
        do {
            try prepareWorkspace(fileManager: fileManager)
            let destination = uniqueDestination(for: name, fileManager: fileManager)
            try fileManager.moveItem(at: source, to: destination)
            let receipt = LocalTransferReceipt(
                id: UUID(),
                fileName: destination.lastPathComponent,
                byteCount: byteCount,
                receivedAt: now()
            )
            receipts.append(receipt)
            return LocalTransferHTTP.Response.json(
                201,
                "Created",
                body: Self.receiptJSON(receipt)
            )
        } catch {
            try? fileManager.removeItem(at: source)
            rejectionCount += 1
            return rejected(.storageFailure)
        }
    }

    /// Creates the transfer workspace if it is not there yet.
    private func prepareWorkspace(fileManager: FileManager) throws {
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: stagingDirectory.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                throw LocalTransferRejection.storageFailure
            }
            return
        }
        try fileManager.createDirectory(
            at: stagingDirectory,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        )
    }

    /// A destination that does not overwrite an earlier arrival.
    private func uniqueDestination(for name: String, fileManager: FileManager) -> URL {
        let base = stagingDirectory.appendingPathComponent(name, isDirectory: false)
        guard fileManager.fileExists(atPath: base.path) else { return base }
        let stem = (name as NSString).deletingPathExtension
        let extensionName = (name as NSString).pathExtension
        var attempt = 2
        while attempt < 1_000 {
            let candidate = stagingDirectory
                .appendingPathComponent("\(stem)-\(attempt)", isDirectory: false)
                .appendingPathExtension(extensionName)
            if !fileManager.fileExists(atPath: candidate.path) { return candidate }
            attempt += 1
        }
        return stagingDirectory
            .appendingPathComponent("\(stem)-\(UUID().uuidString)", isDirectory: false)
            .appendingPathExtension(extensionName)
    }

    /// The files already in the workspace, so a restart does not hide what an
    /// earlier session received.
    private func workspaceReceipts() -> [LocalTransferReceipt] {
        let fileManager = FileManager.default
        guard let names = try? fileManager.contentsOfDirectory(atPath: stagingDirectory.path) else {
            return []
        }
        var found: [LocalTransferReceipt] = []
        for name in names.sorted() {
            guard let accepted = LocalTransferFileName.accepted(name) else { continue }
            let url = stagingDirectory.appendingPathComponent(accepted, isDirectory: false)
            let attributes = try? fileManager.attributesOfItem(atPath: url.path)
            let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0
            let date = attributes?[.modificationDate] as? Date ?? now()
            found.append(
                LocalTransferReceipt(
                    id: UUID(),
                    fileName: accepted,
                    byteCount: size,
                    receivedAt: date
                )
            )
        }
        return found
    }

    // MARK: - Responses

    /// Counts a refusal for the session report and answers with it.
    private func rejected(_ rejection: LocalTransferRejection) -> LocalTransferHTTP.Response {
        rejectionCount += 1
        return LocalTransferHTTP.Response.rejection(rejection)
    }

    /// The acknowledgement body for a stored file.
    private static func receiptJSON(_ receipt: LocalTransferReceipt) -> Data {
        let payload: [String: Any] = [
            "received": receipt.fileName,
            "bytes": receipt.byteCount,
        ]
        return (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]))
            ?? Data("{}".utf8)
    }

    /// The page a browser shows for the session.
    ///
    /// It is a set of instructions, not a control panel: there is no upload
    /// form because this surface takes raw bytes, and offering a form would
    /// promise a multipart endpoint that does not exist.
    private func statusPage(session: LocalTransferSession) -> String {
        let endpoint = snapshot().endpoint
        let address = endpoint?.displayAddress ?? "http://<this device's address>:\(endpoint?.port ?? LocalTransferService.defaultPort)"
        let uploadURL = "\(address)/\(session.token.value)/upload/App.ipa"
        let list = receipts.isEmpty
            ? "<p>No files received in this session.</p>"
            : "<ul>" + receipts.map {
                "<li>\(LocalTransferStatusPage.escaped($0.fileName)) — \($0.formattedByteCount)</li>"
            }.joined() + "</ul>"
        return """
        <!doctype html>
        <html lang="en"><head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>ZynSign local transfer</title>
        </head><body>
        <h1>ZynSign local transfer</h1>
        <p>This session is open until \(LocalTransferStatusPage.escaped(LocalTransferStatusPage.timestamp(session.expiresAt))).
        It accepts raw uploads only, requires this session's token, and stops when ZynSign leaves the foreground.</p>
        <h2>Send a file</h2>
        <pre>curl --data-binary @App.ipa \(LocalTransferStatusPage.escaped(uploadURL))</pre>
        <p>Accepted extensions: \(LocalTransferStatusPage.escaped(LocalTransferFileName.acceptedExtensions.joined(separator: ", "))).</p>
        <h2>Received</h2>
        \(list)
        <p>A received file is bytes on this device. It is not imported, inspected, or signed.</p>
        </body></html>
        """
    }

    /// The sentence a person can act on for a failure the platform reported.
    private static func message(for error: any Error) -> String {
        if let error = error as? ZynSignError {
            return error.userMessage
        }
        return "ZynSign could not open a listening port. Another app may be using it, or this network does not allow it."
    }
}

/// Small pure helpers the status page and the interface share.
enum LocalTransferStatusPage {

    /// Escapes text for HTML text and attribute positions.
    static func escaped(_ text: String) -> String {
        var output = ""
        output.reserveCapacity(text.count)
        for character in text {
            switch character {
            case "&": output += "&amp;"
            case "<": output += "&lt;"
            case ">": output += "&gt;"
            case "\"": output += "&quot;"
            case "'": output += "&#39;"
            default: output.append(character)
            }
        }
        return output
    }

    /// A short local rendering of `date`, for the page's own prose.
    static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    /// The command a person runs on another machine, printed in the app and
    /// on the page so both say the same thing.
    static func uploadCommand(address: String, token: String, fileName: String) -> String {
        let name = LocalTransferFileName.accepted(fileName) ?? "App.ipa"
        return "curl --data-binary @\(name) \(address)/\(token)/upload/\(name)"
    }
}
