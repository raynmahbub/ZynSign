import Darwin
import Foundation
import Network

/// The network-listening implementation of local transfer.
///
/// This file owns the socket and nothing else. Framing is
/// `LocalTransferHTTP`'s job, policy is `LocalTransferService`'s job, and every
/// decision about what may be stored happens above this type. What is left
/// here is the part that cannot be pure: a TCP listener, one bounded read loop
/// per connection, a temporary file for a declared body, and the write of one
/// response.
///
/// **Bounds enforced here, before anything is asked:**
///
/// - The head buffer never exceeds the session's head bound; a client that
///   sends a longer head is answered `431` and disconnected.
/// - A body is streamed to a temporary file and never held whole; the moment
///   the received count passes the declared length (`400`) or the session's
///   upload bound (`413`), the connection is answered and closed.
/// - Every connection has a deadline; a stalled client is answered `408`.
/// - One connection carries one request. Pipelined bytes behind the declared
///   body are refused rather than interpreted.
///
/// A failure that happens *after* the listener is ready is not reported to the
/// service — there is no callback for it — so a dead listener shows up as
/// requests that stop arriving. The interface says so, and stopping and
/// starting the session is the recovery.
final class NetworkLocalTransferServer: LocalTransferTransport, @unchecked Sendable {

    private let queue = DispatchQueue(label: "com.zynsign.local-transfer")
    private var listener: NWListener?
    private var handlers: [ObjectIdentifier: ConnectionHandler] = [:]

    init() {}

    // MARK: - LocalTransferTransport

    func start(
        port: UInt16,
        limits: LocalTransferLimits,
        handling: @escaping @Sendable (LocalTransferHTTP.Request, LocalTransferIncomingBody) async -> LocalTransferHTTP.Response
    ) async throws -> LocalTransferEndpoint {
        let requestedPort: NWEndpoint.Port
        if port == 0 {
            requestedPort = .any
        } else {
            guard let chosen = NWEndpoint.Port(rawValue: port) else {
                throw ZynSignError.localTransferPortUnavailable(port: port)
            }
            requestedPort = chosen
        }

        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true

        let listener: NWListener
        do {
            listener = try NWListener(using: parameters, on: requestedPort)
        } catch {
            throw ZynSignError.localTransferListenerFailed(
                diagnosticDetail: "NWListener refused port \(port).",
                underlyingError: error
            )
        }

        let box = StartBox()
        return try await withCheckedThrowingContinuation { continuation in
            box.store(continuation)
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    let bound = listener.port?.rawValue ?? requestedPort.rawValue
                    box.resume(
                        returning: LocalTransferEndpoint(
                            port: bound,
                            addresses: LocalNetworkAddresses.ipv4Addresses()
                        )
                    )
                case .failed(let error):
                    listener.cancel()
                    box.resume(
                        throwing: ZynSignError.localTransferListenerFailed(
                            diagnosticDetail: "The listener failed before it was ready.",
                            underlyingError: error
                        )
                    )
                case .cancelled:
                    box.resume(
                        throwing: ZynSignError.localTransferListenerFailed(
                            diagnosticDetail: "The listener was cancelled before it was ready.",
                            underlyingError: nil
                        )
                    )
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else {
                    connection.cancel()
                    return
                }
                self.accept(connection, limits: limits, handling: handling)
            }
            self.listener = listener
            listener.start(queue: queue)
        }
    }

    func stop() async {
        await withCheckedContinuation { continuation in
            queue.async {
                let listener = self.listener
                self.listener = nil
                listener?.stateUpdateHandler = nil
                listener?.newConnectionHandler = nil
                listener?.cancel()
                let open = Array(self.handlers.values)
                self.handlers.removeAll()
                for handler in open {
                    handler.cancel()
                }
                continuation.resume()
            }
        }
    }

    // MARK: - Connections

    private func accept(
        _ connection: NWConnection,
        limits: LocalTransferLimits,
        handling: @escaping @Sendable (LocalTransferHTTP.Request, LocalTransferIncomingBody) async -> LocalTransferHTTP.Response
    ) {
        let handler = ConnectionHandler(
            connection: connection,
            limits: limits,
            queue: queue,
            handling: handling,
            onFinish: { [weak self] finished in
                self?.queue.async {
                    self?.handlers.removeValue(forKey: ObjectIdentifier(finished))
                }
            }
        )
        handlers[ObjectIdentifier(handler)] = handler
        handler.start()
    }
}

/// Resumes a start continuation exactly once.
///
/// The listener's state handler can be called more than once — `.ready` after
/// `.waiting`, `.failed` after a cancel — and resuming a continuation twice
/// traps. This box makes "first answer wins" explicit instead of relying on
/// the platform's callback order.
private final class StartBox {

    private let lock = NSLock()
    private var continuation: CheckedContinuation<LocalTransferEndpoint, any Error>?

    func store(_ continuation: CheckedContinuation<LocalTransferEndpoint, any Error>) {
        lock.lock()
        self.continuation = continuation
        lock.unlock()
    }

    func resume(returning endpoint: LocalTransferEndpoint) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: endpoint)
    }

    func resume(throwing error: any Error) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(throwing: error)
    }
}

/// One HTTP connection: read a bounded head, stream a bounded body, ask the
/// service, write one response, close.
private final class ConnectionHandler: @unchecked Sendable {

    private let connection: NWConnection
    private let limits: LocalTransferLimits
    private let queue: DispatchQueue
    private let handling: @Sendable (LocalTransferHTTP.Request, LocalTransferIncomingBody) async -> LocalTransferHTTP.Response
    private let onFinish: @Sendable (ConnectionHandler) -> Void

    private var headBuffer = Data()
    private var request: LocalTransferHTTP.Request?
    private var bodyFileURL: URL?
    private var bodyHandle: FileHandle?
    private var receivedBytes = 0
    private var isFinished = false
    private var deadline: DispatchWorkItem?

    init(
        connection: NWConnection,
        limits: LocalTransferLimits,
        queue: DispatchQueue,
        handling: @escaping @Sendable (LocalTransferHTTP.Request, LocalTransferIncomingBody) async -> LocalTransferHTTP.Response,
        onFinish: @escaping @Sendable (ConnectionHandler) -> Void
    ) {
        self.connection = connection
        self.limits = limits
        self.queue = queue
        self.handling = handling
        self.onFinish = onFinish
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            if case .failed = state {
                self?.cancel()
            }
        }
        connection.start(queue: queue)
        scheduleDeadline()
        receiveHead()
    }

    /// Closes this connection. Safe to call from any of its own callbacks.
    func cancel() {
        finish(response: nil)
    }

    // MARK: - Reading

    private func receiveHead() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1_024) { [weak self] data, _, isComplete, error in
            guard let self, !self.isFinished else { return }
            if let data, !data.isEmpty {
                self.headBuffer.append(data)
            }
            if self.headBuffer.count > self.limits.maximumHeadBytes {
                self.finish(response: .rejection(.headTooLarge))
                return
            }
            switch LocalTransferHTTP.parseHead(self.headBuffer, limits: self.limits) {
            case .incomplete:
                if isComplete || error != nil {
                    self.finish(response: nil)
                } else {
                    self.receiveHead()
                }
            case .rejected(let rejection):
                self.finish(response: .rejection(rejection))
            case .requested(let request, let consumed):
                let bytes = [UInt8](self.headBuffer)
                let leftover: Data
                if consumed < bytes.count {
                    leftover = Data(bytes[consumed...])
                } else {
                    leftover = Data()
                }
                self.headBuffer = Data()
                self.beginBody(for: request, leftover: leftover)
            }
        }
    }

    private func beginBody(for request: LocalTransferHTTP.Request, leftover: Data) {
        self.request = request
        if request.contentLength == 0 {
            // Bytes behind a body-less request are a second request this
            // surface will not answer, so the connection is refused rather
            // than left open to be read as one.
            guard leftover.isEmpty else {
                finish(response: .rejection(.unexpectedBodyBytes))
                return
            }
            deliver(request, body: .none)
            return
        }
        guard leftover.count <= request.contentLength else {
            finish(response: .rejection(.unexpectedBodyBytes))
            return
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZynSignTransfer-\(UUID().uuidString).upload", isDirectory: false)
        guard FileManager.default.createFile(atPath: url.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: url) else {
            finish(response: .rejection(.storageFailure))
            return
        }
        bodyFileURL = url
        bodyHandle = handle
        if !leftover.isEmpty {
            guard write(leftover) else {
                finish(response: .rejection(.storageFailure))
                return
            }
        }
        if receivedBytes == request.contentLength {
            completeBody(request)
        } else {
            receiveBody(request)
        }
    }

    private func receiveBody(_ request: LocalTransferHTTP.Request) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1_024) { [weak self] data, _, isComplete, error in
            guard let self, !self.isFinished else { return }
            if let data, !data.isEmpty {
                guard self.write(data) else {
                    self.finish(response: .rejection(.storageFailure))
                    return
                }
            }
            if self.receivedBytes > request.contentLength {
                self.finish(response: .rejection(.unexpectedBodyBytes))
                return
            }
            if self.receivedBytes > self.limits.maximumUploadBytes {
                self.finish(response: .rejection(.payloadTooLarge(limit: self.limits.maximumUploadBytes)))
                return
            }
            if self.receivedBytes == request.contentLength {
                self.completeBody(request)
                return
            }
            if isComplete || error != nil {
                // The client stopped short of the length it declared. A
                // partial body is never handed on as if it were whole.
                self.finish(response: nil)
                return
            }
            self.receiveBody(request)
        }
    }

    /// Appends `data` to the body file, enforcing both bounds.
    private func write(_ data: Data) -> Bool {
        guard let handle = bodyHandle, let declared = self.request else { return false }
        let projected = receivedBytes + data.count
        guard projected <= declared.contentLength else { return false }
        guard projected <= limits.maximumUploadBytes else { return false }
        do {
            try handle.write(contentsOf: data)
        } catch {
            return false
        }
        receivedBytes = projected
        return true
    }

    private func completeBody(_ request: LocalTransferHTTP.Request) {
        closeBodyFile()
        guard let url = bodyFileURL, receivedBytes > 0 else {
            finish(response: .rejection(.emptyPayload))
            return
        }
        deliver(request, body: .file(url, byteCount: receivedBytes))
    }

    // MARK: - Answering

    private func deliver(_ request: LocalTransferHTTP.Request, body: LocalTransferIncomingBody) {
        let handling = self.handling
        Task { [weak self] in
            let response = await handling(request, body)
            guard let self else { return }
            self.queue.async {
                self.finish(response: response)
            }
        }
    }

    /// Writes `response` (when there is one) and closes the connection.
    private func finish(response: LocalTransferHTTP.Response?) {
        guard !isFinished else { return }
        isFinished = true
        deadline?.cancel()
        deadline = nil
        closeBodyFile()
        let unclaimedBody = bodyFileURL
        bodyFileURL = nil
        if let unclaimedBody {
            // The service moves the file it accepts; anything still here was
            // refused, or never arrived whole, and does not outlive the
            // connection.
            try? FileManager.default.removeItem(at: unclaimedBody)
        }
        guard let response else {
            connection.cancel()
            onFinish(self)
            return
        }
        connection.send(
            content: response.serialized,
            contentContext: .finalMessage,
            isComplete: true,
            completion: .contentProcessed { [weak self] _ in
                guard let self else { return }
                self.connection.cancel()
                self.onFinish(self)
            }
        )
    }

    private func closeBodyFile() {
        if let handle = bodyHandle {
            try? handle.close()
        }
        bodyHandle = nil
    }

    private func scheduleDeadline() {
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.isFinished else { return }
            self.finish(response: .rejection(.requestTimedOut))
        }
        deadline = work
        queue.asyncAfter(deadline: .now() + limits.requestTimeout, execute: work)
    }
}

/// The device's own IPv4 addresses, for the address the interface shows.
///
/// The enumeration is best-effort and returns an empty array rather than a
/// guess: an interface with no address is a session that can still listen on
/// its port, and the app says the address is unavailable instead of printing
/// one that does not work.
enum LocalNetworkAddresses {

    /// Up, non-loopback IPv4 addresses, sorted for a stable display.
    static func ipv4Addresses() -> [String] {
        var found: [String] = []
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0, let start = first else { return [] }
        defer { freeifaddrs(first) }

        var cursor: UnsafeMutablePointer<ifaddrs>? = start
        while let entry = cursor {
            let interface = entry.pointee
            cursor = interface.ifa_next
            let flags = interface.ifa_flags
            guard flags & UInt32(IFF_UP) != 0, flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            guard let address = interface.ifa_addr else { continue }
            guard address.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let status = getnameinfo(
                address,
                socklen_t(address.pointee.sa_len),
                &host,
                socklen_t(host.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            guard status == 0 else { continue }
            let text = String(cString: host)
            guard !text.isEmpty, !found.contains(text) else { continue }
            found.append(text)
        }
        return found.sorted()
    }
}
