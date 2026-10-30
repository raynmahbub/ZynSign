import Foundation
#if canImport(Network)
import Network
#endif

/// Experimental usbmux tunnel transport. Device sessions are blocked: the
/// current TCP implementation does not authenticate with the pairing identity
/// or establish the TLS required by `DeviceTransport`.
final class NetworkDeviceBridgeTransport: DeviceTransport, @unchecked Sendable {

    /// This must remain false until TLS, framed reads, cancellation, and real
    /// device interoperability have been implemented and independently verified.
    static let supportsAuthenticatedSessions = false

    private let endpointConfig: DeviceBridgeEndpointConfig
    private let queue = DispatchQueue(label: "io.zynsign.device-bridge.transport")
    #if canImport(Network)
    private var connection: NWConnection?
    #endif

    init(endpointConfig: DeviceBridgeEndpointConfig) {
        self.endpointConfig = endpointConfig
    }

    func connect(pairing: DevicePairingRecord, port: Int) async throws {
        guard Self.supportsAuthenticatedSessions else {
            throw DeviceProtocolError.authenticatedTransportUnavailable
        }
        guard (1...65_535).contains(port) else {
            throw DeviceProtocolError.invalidPort(port)
        }
        guard !pairing.hostCertificate.isEmpty, !pairing.hostPrivateKey.isEmpty else {
            throw DeviceProtocolError.notPaired
        }
        #if canImport(Network)
        await close()
        let snap = endpointConfig.snapshot
        guard let muxPort = NWEndpoint.Port(rawValue: snap.port) else {
            throw DeviceProtocolError.invalidPort(Int(snap.port))
        }

        // Step 1: Discover active DeviceID via short-lived ListDevices request.
        let deviceID = try await queryFirstDeviceID(host: snap.host, muxPort: muxPort)

        // Step 2: Open mux connection and bind to target device port.
        let conn = NWConnection(host: NWEndpoint.Host(snap.host), port: muxPort, using: .tcp)
        try await waitReady(conn)
        self.connection = conn

        let connectPayload = try PropertyListSerialization.data(
            fromPropertyList: try USBMuxProtocol.Request.connect(deviceID: deviceID, port: port).payload(),
            format: .xml,
            options: 0
        )
        let connectFrame = try USBMuxProtocol.Frame(type: .plist, tag: 2, payload: connectPayload).serialized()
        try await sendRaw(connectFrame, over: conn)

        let replyDict = try await readUSBMuxPlistReply(from: conn)
        let resultNum = (replyDict["Number"] as? Int) ?? -1
        guard resultNum == 0 else {
            await close()
            throw DeviceProtocolError.deviceRefused(code: "USBMuxConnect(\(resultNum))")
        }
        #else
        throw DeviceProtocolError.deviceUnavailable
        #endif
    }

    func send(_ data: Data) async throws {
        #if canImport(Network)
        guard let conn = connection else {
            throw DeviceProtocolError.sessionNotStarted
        }
        try await sendRaw(data, over: conn)
        #else
        throw DeviceProtocolError.deviceUnavailable
        #endif
    }

    func receive(maximumBytes: Int) async throws -> Data {
        #if canImport(Network)
        guard let conn = connection else {
            throw DeviceProtocolError.sessionNotStarted
        }
        return try await receiveRaw(minimumBytes: 1, maximumBytes: max(1, maximumBytes), from: conn)
        #else
        throw DeviceProtocolError.deviceUnavailable
        #endif
    }

    func close() async {
        #if canImport(Network)
        let active = connection
        connection = nil
        active?.cancel()
        #endif
    }

    // MARK: - Internal Network Helpers

    #if canImport(Network)
    private func queryFirstDeviceID(host: String, muxPort: NWEndpoint.Port) async throws -> Int {
        let probe = NWConnection(host: NWEndpoint.Host(host), port: muxPort, using: .tcp)
        defer { probe.cancel() }
        try await waitReady(probe)

        let listPayload = try PropertyListSerialization.data(
            fromPropertyList: try USBMuxProtocol.Request.listDevices.payload(),
            format: .xml,
            options: 0
        )
        let frame = try USBMuxProtocol.Frame(type: .plist, tag: 1, payload: listPayload).serialized()
        try await sendRaw(frame, over: probe)
        let dict = try await readUSBMuxPlistReply(from: probe)
        guard let deviceList = dict["DeviceList"] as? [[String: Any]],
              let first = deviceList.first else {
            throw DeviceProtocolError.deviceUnavailable
        }
        if let topID = first["DeviceID"] as? Int {
            return topID
        }
        if let props = first["Properties"] as? [String: Any],
           let propID = props["DeviceID"] as? Int {
            return propID
        }
        throw DeviceProtocolError.deviceUnavailable
    }

    private func readUSBMuxPlistReply(from conn: NWConnection) async throws -> [String: Any] {
        let headerBytes = try await receiveExact(count: USBMuxProtocol.headerLength, from: conn)
        let (_, totalLength) = try USBMuxProtocol.decodeHeader(headerBytes)
        let bodyLength = totalLength - USBMuxProtocol.headerLength
        guard bodyLength > 0 else {
            throw DeviceProtocolError.emptyMessage
        }
        let bodyBytes = try await receiveExact(count: bodyLength, from: conn)
        guard let dict = try? PropertyListSerialization.propertyList(from: bodyBytes, options: [], format: nil) as? [String: Any] else {
            throw DeviceProtocolError.messageIsNotADictionary
        }
        return dict
    }

    private func waitReady(_ conn: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let stateBox = ContinuationGate()
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if stateBox.claim() { cont.resume() }
                case .failed:
                    if stateBox.claim() { cont.resume(throwing: DeviceProtocolError.deviceUnavailable) }
                case .cancelled:
                    if stateBox.claim() { cont.resume(throwing: DeviceProtocolError.deviceUnavailable) }
                default:
                    break
                }
            }
            conn.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 6.0) {
                if stateBox.claim() {
                    conn.cancel()
                    cont.resume(throwing: DeviceProtocolError.deviceUnavailable)
                }
            }
        }
    }

    private func sendRaw(_ data: Data, over conn: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            conn.send(content: data, completion: .contentProcessed { error in
                if error != nil {
                    cont.resume(throwing: DeviceProtocolError.deviceUnavailable)
                } else {
                    cont.resume()
                }
            })
        }
    }

    private func receiveRaw(minimumBytes: Int, maximumBytes: Int, from conn: NWConnection) async throws -> Data {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            conn.receive(minimumIncompleteLength: minimumBytes, maximumLength: maximumBytes) { content, _, _, error in
                if error != nil {
                    cont.resume(throwing: DeviceProtocolError.deviceUnavailable)
                } else if let content, !content.isEmpty {
                    cont.resume(returning: content)
                } else {
                    cont.resume(throwing: DeviceProtocolError.emptyMessage)
                }
            }
        }
    }

    private func receiveExact(count: Int, from conn: NWConnection) async throws -> Data {
        var buffer = Data()
        buffer.reserveCapacity(count)
        while buffer.count < count {
            let chunk = try await receiveRaw(
                minimumBytes: 1,
                maximumBytes: count - buffer.count,
                from: conn
            )
            buffer.append(chunk)
        }
        return buffer
    }
    #endif
}

private final class ContinuationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}
