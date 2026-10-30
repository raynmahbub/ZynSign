import Foundation
import Network

/// `NWListener`-backed foreground server for `LANWebWorkspaceService`,
/// streaming request bodies to bounded temporary files so large `.ipa` uploads
/// never sit in RAM whole.
///
/// Two bounds keep a hostile or merely broken client from holding the listener:
/// a connection that makes no progress for `idleTimeoutSeconds` is closed, and at
/// most `maximumConcurrentConnections` connections are served at once. Both are
/// counted on the same serial queue the listener runs on, so the budget cannot
/// be observed half-updated.
final class NetworkLANWebWorkspaceServer: LANWebWorkspaceTransport, @unchecked Sendable {

    /// How long a connection may go without a byte before it is closed.
    static let idleTimeoutSeconds: TimeInterval = 30

    /// How many connections this server serves at once.
    static let maximumConcurrentConnections = 8

    private let queue = DispatchQueue(label: "com.zynsign.lan-web-workspace")
    private var listener: NWListener?
    private var activeConnectionCount = 0

    init() {}

    func start(
        port: UInt16,
        maximumUploadBytes: Int,
        handling: @escaping @Sendable (WebDAVProtocol.HTTPRequestHead, URL?) async -> WebDAVProtocol.HTTPResponseMessage
    ) async throws -> LocalTransferEndpoint {
        let nwPort: NWEndpoint.Port
        if port == 0 {
            nwPort = .any
        } else {
            guard let resolved = NWEndpoint.Port(rawValue: port) else {
                throw ZynSignError.localTransferPortUnavailable(port: port)
            }
            nwPort = resolved
        }

        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let newListener = try NWListener(using: params, on: nwPort)
        let startGate = ListenerGate()

        return try await withCheckedThrowingContinuation { continuation in
            startGate.store(continuation)
            newListener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    let actualPort = newListener.port?.rawValue ?? port
                    startGate.resume(returning: LocalTransferEndpoint(
                        port: actualPort,
                        addresses: Self.discoverIPv4Addresses()
                    ))
                case .failed(let error):
                    newListener.cancel()
                    startGate.resume(throwing: ZynSignError.localTransferListenerFailed(
                        diagnosticDetail: "LAN Web Workspace listener failed.",
                        underlyingError: error
                    ))
                case .cancelled:
                    startGate.resume(throwing: ZynSignError.localTransferListenerFailed(
                        diagnosticDetail: "LAN Web Workspace listener cancelled."
                    ))
                default:
                    break
                }
            }
            newListener.newConnectionHandler = { [weak self] connection in
                guard let self else {
                    connection.cancel()
                    return
                }
                self.serveConnection(
                    connection,
                    maximumUploadBytes: maximumUploadBytes,
                    handling: handling
                )
            }
            self.queue.async {
                self.listener = newListener
                newListener.start(queue: self.queue)
            }
        }
    }

    func stop() async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            queue.async {
                self.listener?.cancel()
                self.listener = nil
                done.resume()
            }
        }
    }

    // MARK: - Bounded Connection Reader

    private func serveConnection(
        _ connection: NWConnection,
        maximumUploadBytes: Int,
        handling: @escaping @Sendable (WebDAVProtocol.HTTPRequestHead, URL?) async -> WebDAVProtocol.HTTPResponseMessage
    ) {
        guard activeConnectionCount < Self.maximumConcurrentConnections else {
            connection.start(queue: queue)
            sendAndClose(
                WebDAVProtocol.HTTPResponseMessage(
                    status: 503,
                    reason: "Service Unavailable",
                    headers: [("Retry-After", "1")],
                    body: Data("This workspace is serving the maximum number of connections.\n".utf8)
                ),
                on: connection
            )
            return
        }
        activeConnectionCount += 1
        let ticket = ConnectionTicket { [weak self] in
            guard let self else { return }
            self.activeConnectionCount = max(0, self.activeConnectionCount - 1)
        }
        // The handler is installed before the connection starts, so a connection
        // that ends immediately still returns its seat.
        connection.stateUpdateHandler = { state in
            switch state {
            case .failed, .cancelled: ticket.release()
            default: break
            }
        }
        connection.start(queue: queue)
        let watchdog = IdleWatchdog(queue: queue, seconds: Self.idleTimeoutSeconds) {
            connection.cancel()
        }
        watchdog.touch()
        readHead(
            connection: connection,
            accumulated: Data(),
            maximumUploadBytes: maximumUploadBytes,
            watchdog: watchdog,
            handling: handling
        )
    }

    private func readHead(
        connection: NWConnection,
        accumulated: Data,
        maximumUploadBytes: Int,
        watchdog: IdleWatchdog,
        handling: @escaping @Sendable (WebDAVProtocol.HTTPRequestHead, URL?) async -> WebDAVProtocol.HTTPResponseMessage
    ) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] chunk, _, isComplete, error in
            guard let self else { connection.cancel(); return }
            watchdog.touch()
            if error != nil { connection.cancel(); return }
            var buffer = accumulated
            if let chunk { buffer.append(chunk) }
            if buffer.count > 32_768, buffer.range(of: Data("\r\n\r\n".utf8)) == nil {
                self.sendAndClose(
                    WebDAVProtocol.HTTPResponseMessage(status: 431, reason: "Request Header Fields Too Large", headers: [], body: Data()),
                    on: connection
                )
                return
            }
            if let marker = buffer.range(of: Data("\r\n\r\n".utf8)) {
                guard marker.lowerBound <= 32_768 else {
                    self.sendAndClose(
                        WebDAVProtocol.HTTPResponseMessage(status: 431, reason: "Request Header Fields Too Large", headers: [], body: Data()),
                        on: connection
                    )
                    return
                }
                let headBytes = buffer.subdata(in: 0..<marker.lowerBound)
                let initialBody = buffer.subdata(in: marker.upperBound..<buffer.count)
                guard let head = WebDAVProtocol.parseHead(headBytes) else {
                    self.sendAndClose(
                        WebDAVProtocol.HTTPResponseMessage(status: 400, reason: "Bad Request", headers: [], body: Data()),
                        on: connection
                    )
                    return
                }
                if head.contentLength > maximumUploadBytes {
                    self.sendAndClose(
                        WebDAVProtocol.HTTPResponseMessage(status: 413, reason: "Content Too Large", headers: [], body: Data()),
                        on: connection
                    )
                    return
                }
                self.streamBodyAndDispatch(
                    connection: connection,
                    head: head,
                    initialBody: initialBody,
                    watchdog: watchdog,
                    handling: handling
                )
            } else if isComplete {
                connection.cancel()
            } else {
                self.readHead(
                    connection: connection,
                    accumulated: buffer,
                    maximumUploadBytes: maximumUploadBytes,
                    watchdog: watchdog,
                    handling: handling
                )
            }
        }
    }

    private func streamBodyAndDispatch(
        connection: NWConnection,
        head: WebDAVProtocol.HTTPRequestHead,
        initialBody: Data,
        watchdog: IdleWatchdog,
        handling: @escaping @Sendable (WebDAVProtocol.HTTPRequestHead, URL?) async -> WebDAVProtocol.HTTPResponseMessage
    ) {
        guard initialBody.count <= head.contentLength else {
            sendAndClose(
                WebDAVProtocol.HTTPResponseMessage(status: 400, reason: "Bad Request", headers: [], body: Data()),
                on: connection
            )
            return
        }
        if head.contentLength == 0 {
            // The request is complete; the clock that guards a stalled client no
            // longer applies while the handler does its work.
            watchdog.disarm()
            Task {
                let response = await handling(head, nil)
                self.sendAndClose(response, on: connection)
            }
            return
        }

        let tempFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZynWebBody-\(UUID().uuidString).part")
        FileManager.default.createFile(atPath: tempFile.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: tempFile) else {
            sendAndClose(
                WebDAVProtocol.HTTPResponseMessage(status: 507, reason: "Insufficient Storage", headers: [], body: Data()),
                on: connection
            )
            return
        }
        let initialSlice = initialBody.prefix(head.contentLength)
        do {
            try handle.write(contentsOf: initialSlice)
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: tempFile)
            sendAndClose(
                WebDAVProtocol.HTTPResponseMessage(status: 507, reason: "Insufficient Storage", headers: [], body: Data()),
                on: connection
            )
            return
        }
        let remaining = head.contentLength - initialSlice.count
        if remaining <= 0 {
            try? handle.close()
            watchdog.disarm()
            Task {
                let response = await handling(head, tempFile)
                try? FileManager.default.removeItem(at: tempFile)
                self.sendAndClose(response, on: connection)
            }
            return
        }
        receiveRemainingBody(
            connection: connection,
            head: head,
            fileHandle: handle,
            tempFile: tempFile,
            remaining: remaining,
            watchdog: watchdog,
            handling: handling
        )
    }

    private func receiveRemainingBody(
        connection: NWConnection,
        head: WebDAVProtocol.HTTPRequestHead,
        fileHandle: FileHandle,
        tempFile: URL,
        remaining: Int,
        watchdog: IdleWatchdog,
        handling: @escaping @Sendable (WebDAVProtocol.HTTPRequestHead, URL?) async -> WebDAVProtocol.HTTPResponseMessage
    ) {
        let chunkLimit = min(262_144, remaining)
        connection.receive(minimumIncompleteLength: 1, maximumLength: chunkLimit) { [weak self] chunk, _, isComplete, error in
            guard let self else {
                try? fileHandle.close()
                try? FileManager.default.removeItem(at: tempFile)
                connection.cancel()
                return
            }
            watchdog.touch()
            if error != nil || (chunk == nil && isComplete) {
                try? fileHandle.close()
                try? FileManager.default.removeItem(at: tempFile)
                connection.cancel()
                return
            }
            let written = chunk ?? Data()
            guard !written.isEmpty, written.count <= remaining else {
                try? fileHandle.close()
                try? FileManager.default.removeItem(at: tempFile)
                connection.cancel()
                return
            }
            do {
                try fileHandle.write(contentsOf: written)
            } catch {
                try? fileHandle.close()
                try? FileManager.default.removeItem(at: tempFile)
                self.sendAndClose(
                    WebDAVProtocol.HTTPResponseMessage(status: 507, reason: "Insufficient Storage", headers: [], body: Data()),
                    on: connection
                )
                return
            }
            let nextRemaining = remaining - written.count
            if nextRemaining <= 0 {
                try? fileHandle.close()
                watchdog.disarm()
                Task {
                    let response = await handling(head, tempFile)
                    try? FileManager.default.removeItem(at: tempFile)
                    self.sendAndClose(response, on: connection)
                }
            } else {
                self.receiveRemainingBody(
                    connection: connection,
                    head: head,
                    fileHandle: fileHandle,
                    tempFile: tempFile,
                    remaining: nextRemaining,
                    watchdog: watchdog,
                    handling: handling
                )
            }
        }
    }

    private func sendAndClose(_ response: WebDAVProtocol.HTTPResponseMessage, on connection: NWConnection) {
        let bytes = response.serialized()
        connection.send(content: bytes, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private static func discoverIPv4Addresses() -> [String] {
        var addresses: [String] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
        defer { freeifaddrs(first) }
        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let current = pointer {
            let flags = Int32(current.pointee.ifa_flags)
            let isUp = (flags & (IFF_UP | IFF_RUNNING)) == (IFF_UP | IFF_RUNNING)
            let isLoopback = (flags & IFF_LOOPBACK) != 0
            if isUp, !isLoopback, let addr = current.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) {
                var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST) == 0 {
                    let text = String(cString: hostname)
                    if !text.hasPrefix("169.254."), !addresses.contains(text) {
                        addresses.append(text)
                    }
                }
            }
            pointer = current.pointee.ifa_next
        }
        return addresses.sorted()
    }
}

private final class ListenerGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<LocalTransferEndpoint, Error>?

    func store(_ cont: CheckedContinuation<LocalTransferEndpoint, Error>) {
        lock.lock()
        continuation = cont
        lock.unlock()
    }

    func resume(returning endpoint: LocalTransferEndpoint) {
        lock.lock()
        let cont = continuation
        continuation = nil
        lock.unlock()
        cont?.resume(returning: endpoint)
    }

    func resume(throwing error: Error) {
        lock.lock()
        let cont = continuation
        continuation = nil
        lock.unlock()
        cont?.resume(throwing: error)
    }
}

/// A per-connection clock that closes a connection making no progress.
///
/// `touch()` is called from every receive completion and must run on the queue
/// the server was started with; the type holds no lock because it is never
/// touched from another one.
private final class IdleWatchdog: @unchecked Sendable {
    private let queue: DispatchQueue
    private let seconds: TimeInterval
    private let onExpiry: @Sendable () -> Void
    private var pending: DispatchWorkItem?

    init(queue: DispatchQueue, seconds: TimeInterval, onExpiry: @escaping @Sendable () -> Void) {
        self.queue = queue
        self.seconds = seconds
        self.onExpiry = onExpiry
    }

    /// Starts or restarts the clock.
    func touch() {
        pending?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.pending?.isCancelled == false else { return }
            self.onExpiry()
        }
        pending = item
        queue.asyncAfter(deadline: .now() + seconds, execute: item)
    }

    /// Stops the clock once the request is complete and the handler is working.
    func disarm() {
        pending?.cancel()
        pending = nil
    }
}

/// One seat in the connection budget, released exactly once however the
/// connection ends.
private final class ConnectionTicket: @unchecked Sendable {
    private var released = false
    private let releaseSeat: () -> Void

    init(_ releaseSeat: @escaping () -> Void) {
        self.releaseSeat = releaseSeat
    }

    func release() {
        guard !released else { return }
        released = true
        releaseSeat()
    }
}
