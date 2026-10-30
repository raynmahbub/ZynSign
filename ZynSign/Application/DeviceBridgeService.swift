import Foundation

/// A byte channel to a device port. The platform composes this; the bridge
/// never learns whether the bytes crossed a tunnel, a cable or a simulator.
protocol DeviceTransport: AnyObject, Sendable {
    /// Asks usbmux for ``port`` and completes the TLS handshake with the
    /// pairing record's host identity. The device's certificate must chain to
    /// the record's root, or this throws.
    func connect(pairing: DevicePairingRecord, port: Int) async throws
    func send(_ data: Data) async throws
    func receive(maximumBytes: Int) async throws -> Data
    func close() async
}

extension DeviceTransport {
    /// Network receives may return any non-empty prefix, not a complete frame.
    /// The caller supplies a protocol-specific maximum before allocating.
    func receiveExactly(_ count: Int, maximum: Int) async throws -> Data {
        guard count >= 0, maximum >= 0, count <= maximum else {
            throw DeviceProtocolError.invalidFrameLength(count)
        }
        var result = Data()
        result.reserveCapacity(count)
        while result.count < count {
            try Task.checkCancellation()
            let remaining = count - result.count
            let chunk = try await receive(maximumBytes: remaining)
            guard !chunk.isEmpty else {
                throw DeviceProtocolError.truncatedFrame(needed: count, received: result.count)
            }
            guard chunk.count <= remaining else {
                throw DeviceProtocolError.invalidFrameLength(chunk.count)
            }
            result.append(chunk)
        }
        return result
    }
}

/// What the bridge can report about one device.
struct PairedDevice: Equatable, Sendable {
    let hostIdentifier: String
    let uniqueDeviceID: String
    let name: String
    let productVersion: String
    let buildVersion: String
    let productType: String
    let connectedAt: Date
}

/// The outcome of one installation attempt, as the device reported it.
struct DeviceInstallOutcome: Equatable, Sendable {
    let bundleIdentifier: String
    let remotePath: String
    let uploadedBytes: Int
    let progress: [InstallationProxyProtocol.Progress]

    /// `true` only when the device's last message was `Complete`. Every other
    /// status — including an interrupted stream — reads as not installed.
    var isInstalled: Bool {
        progress.last?.status == .complete
    }

    var finalStatus: String {
        progress.last?.status.label ?? "No status received"
    }
}

/// The device bridge: pair, start a session, upload, install.
///
/// This type owns the conversation order and nothing else. Framing lives in
/// `DeviceBridgeProtocols`, the socket lives in `Platform`, and the decision
/// to start an installation lives in the presentation layer behind the
/// readiness gate. That split is what lets the whole conversation be replayed
/// against a recorded transport in a test.
final class DeviceBridgeService: @unchecked Sendable {

    /// The label every request carries; a device logs it.
    static let clientLabel = "ZynSign"

    private let makeTransport: @Sendable () -> any DeviceTransport
    private let recordStore: any PairingRecordStoring

    init(
        recordStore: any PairingRecordStoring,
        makeTransport: @escaping @Sendable () -> any DeviceTransport
    ) {
        self.recordStore = recordStore
        self.makeTransport = makeTransport
    }

    // MARK: - Pairing records

    func importPairingRecord(data: Data, digest: any MessageDigest) throws -> DevicePairingRecord {
        let record = try PairingRecordCoding.decode(data, digest: digest)
        try recordStore.save(record)
        return record
    }

    func pairingRecords() throws -> [DevicePairingRecord] {
        try recordStore.all()
    }

    // MARK: - Conversation

    /// Query the device and start a session. The returned device is what the
    /// device said about itself, not what the app assumed.
    func connect(record: DevicePairingRecord) async throws -> PairedDevice {
        let values = try await withLockdown(record) { stream in
            let query = try await stream.request(.queryType)
            guard case .success(let answer) = query,
                  (answer["Type"] as? String) == LockdownProtocol.service else {
                throw DeviceProtocolError.deviceRefused(code: "NotLockdownd")
            }
            let all = try await stream.request(.allValues)
            guard case .success(let message) = all else {
                throw DeviceProtocolError.deviceRefused(code: "ValuesUnavailable")
            }
            let deviceValues = LockdownProtocol.DeviceValues(
                values: message["Value"] as? [String: Any] ?? [:])
            return deviceValues
        }
        return PairedDevice(
            hostIdentifier: record.hostIdentifier,
            uniqueDeviceID: values.uniqueDeviceID,
            name: values.deviceName,
            productVersion: values.productVersion,
            buildVersion: values.buildVersion,
            productType: values.productType,
            connectedAt: Date()
        )
    }

    /// Upload a signed package with AFC and install it with
    /// installation_proxy. The device's answers are the only evidence of what
    /// happened; a stream that ends early is an interrupted attempt.
    func install(
        package: Data,
        bundleIdentifier: String,
        fileName: String,
        record: DevicePairingRecord
    ) async throws -> DeviceInstallOutcome {
        guard BundleIdentifier(rawValue: bundleIdentifier) != nil,
              let safeName = ArchivePath(rawValue: fileName),
              safeName.rawValue == fileName, safeName.components.count == 1 else {
            throw DeviceProtocolError.deviceRefused(code: "InvalidPackageMetadata")
        }
        let remotePath = "/PublicStaging/\(fileName)"
        try await upload(package: package, to: remotePath, record: record)
        let progress = try await installStagedPackage(
            remotePath: remotePath, bundleIdentifier: bundleIdentifier, record: record)
        return DeviceInstallOutcome(
            bundleIdentifier: bundleIdentifier,
            remotePath: remotePath,
            uploadedBytes: package.count,
            progress: progress
        )
    }

    private func upload(package: Data, to remotePath: String,
                        record: DevicePairingRecord) async throws {
        let port = try await servicePort(LockdownProtocol.afcService, record: record)
        try await withDeviceTransport(record: record, port: port) { transport in
            var transaction: UInt64 = 0
            func exchange(_ operation: AFCProtocol.Operation, arguments: Data, body: Data = Data()) async throws
                -> (operation: AFCProtocol.Operation, body: Data) {
                transaction += 1
                let argumentLength = AFCProtocol.headerLength + arguments.count
                let totalLength = argumentLength + body.count
                guard totalLength <= AFCProtocol.headerLength + PropertyListFraming.maximumMessageBytes else {
                    throw DeviceProtocolError.invalidFrameLength(totalLength)
                }
                let header = AFCProtocol.Header(entireLength: UInt64(totalLength), thisLength: UInt64(argumentLength),
                                                transaction: transaction, operationRaw: operation.rawValue)
                try await transport.send(header.serialized() + arguments + body)
                let headerBytes = try await transport.receiveExactly(AFCProtocol.headerLength, maximum: AFCProtocol.headerLength)
                let response = try AFCProtocol.Header.decode(headerBytes)
                guard response.transaction == transaction, let responseOperation = response.operation,
                      let size = Int(exactly: response.payloadSize) else {
                    throw DeviceProtocolError.deviceRefused(code: "InvalidAFCResponse")
                }
                let responseBody = try await transport.receiveExactly(size, maximum: PropertyListFraming.maximumMessageBytes)
                return (responseOperation, responseBody)
            }
            func status(_ response: (operation: AFCProtocol.Operation, body: Data)) throws -> UInt64 {
                guard response.operation == .status, response.body.count == 8 else {
                    throw DeviceProtocolError.deviceRefused(code: "InvalidAFCStatus")
                }
                return response.body.littleEndianUInt64(at: 0)
            }

            let directoryReply = try await exchange(.makeDirectory, arguments: Data("/PublicStaging".utf8) + Data([0]))
            let directoryStatus = try status(directoryReply)
            guard directoryStatus == 0 || directoryStatus == AFCProtocol.alreadyExistsStatus else {
                throw DeviceProtocolError.deviceRefused(code: "AFCMakeDirectory(\(directoryStatus))")
            }
            var openArguments = Data()
            openArguments.appendLittleEndian(UInt64(3)) // write-only, create and truncate
            openArguments.append(Data(remotePath.utf8))
            openArguments.append(0)
            let opened = try await exchange(.fileOpen, arguments: openArguments)
            guard opened.operation == .fileOpenResult, opened.body.count == 8 else {
                throw DeviceProtocolError.deviceRefused(code: "AFCOpen")
            }
            let handle = opened.body.littleEndianUInt64(at: 0)
            guard handle != 0 else { throw DeviceProtocolError.deviceRefused(code: "AFCOpen") }
            var handleBytes = Data()
            handleBytes.appendLittleEndian(handle)
            do {
                var offset = 0
                while offset < package.count {
                    try Task.checkCancellation()
                    let end = min(offset + 256 * 1024, package.count)
                    let response = try await exchange(.fileWrite, arguments: handleBytes, body: package.subdata(in: offset..<end))
                    let writeStatus = try status(response)
                    guard writeStatus == 0 else { throw DeviceProtocolError.deviceRefused(code: "AFCWrite(\(writeStatus))") }
                    offset = end
                }
                let closeReply = try await exchange(.fileClose, arguments: handleBytes)
                let closeStatus = try status(closeReply)
                guard closeStatus == 0 else { throw DeviceProtocolError.deviceRefused(code: "AFCClose(\(closeStatus))") }
            } catch {
                // Closing the connection below releases the remote handle.
                // Do not start another unbounded exchange after an interruption.
                throw error
            }
        }
    }

    private func installStagedPackage(
        remotePath: String, bundleIdentifier: String,
        record: DevicePairingRecord
    ) async throws -> [InstallationProxyProtocol.Progress] {
        let port = try await servicePort(
            LockdownProtocol.installationProxyService, record: record)
        return try await withDeviceTransport(record: record, port: port) { transport in
            let command = InstallationProxyProtocol.Command.install(
                packagePath: remotePath, bundleIdentifier: bundleIdentifier, isUpgrade: false)
            let framed = try PropertyListFraming.encodedMessage(command.message())
            try await transport.send(framed)

            var progress: [InstallationProxyProtocol.Progress] = []
            while progress.count < 4_096 {
                try Task.checkCancellation()
                let prefix = try await transport.receiveExactly(
                    PropertyListFraming.lengthPrefixBytes, maximum: PropertyListFraming.lengthPrefixBytes)
                let length = try PropertyListFraming.declaredLength(prefix: prefix)
                let payload = try await transport.receiveExactly(length, maximum: PropertyListFraming.maximumMessageBytes)
                let message = try PropertyListFraming.decode(payload)
                switch InstallationProxyProtocol.Update.decode(message) {
                case .progress(let step):
                    progress.append(step)
                    if step.isTerminal { return progress }
                case .failure(let code, let description):
                    throw DeviceProtocolError.deviceRefused(
                        code: description.isEmpty ? code : "\(code): \(description)")
                case .listing:
                    throw DeviceProtocolError.deviceRefused(code: "UnexpectedListing")
                }
            }
            throw DeviceProtocolError.deviceRefused(code: "InstallationProgressLimit")
        }
    }

    private func withDeviceTransport<T>(record: DevicePairingRecord, port: Int,
                                        body: (any DeviceTransport) async throws -> T) async throws -> T {
        let transport = makeTransport()
        do {
            try await transport.connect(pairing: record, port: port)
            let result = try await body(transport)
            await transport.close()
            return result
        } catch {
            await transport.close()
            throw error
        }
    }

    /// Ask lockdownd to start a service and return its port. The device
    /// decides whether the service exists at all.
    private func servicePort(_ name: String,
                             record: DevicePairingRecord) async throws -> Int {
        try await withLockdown(record) { stream in
            let response = try await stream.request(.startService(name: name))
            guard case .success(let message) = response else {
                throw DeviceProtocolError.deviceRefused(code: "StartService")
            }
            guard let port = message["Port"] as? Int, (1...65_535).contains(port) else {
                throw DeviceProtocolError.deviceRefused(code: "NoServicePort")
            }
            if let ssl = message["EnableServiceSSL"] {
                guard let requiresSSL = ssl as? Bool else {
                    throw DeviceProtocolError.deviceRefused(code: "InvalidServiceSSL")
                }
                // The current transport does not negotiate service-specific TLS.
                if requiresSSL { throw DeviceProtocolError.authenticatedTransportUnavailable }
            }
            return port
        }
    }

    private func withLockdown<T>(
        _ record: DevicePairingRecord,
        _ body: (LockdownStream) async throws -> T
    ) async throws -> T {
        let transport = makeTransport()
        do {
            try await transport.connect(pairing: record, port: LockdownProtocol.defaultPort)
            let stream = LockdownStream(transport: transport)
            let response = try await stream.request(.startSession(
                hostID: record.hostIdentifier, systemBUID: record.systemBUID))
            guard case .success(let message) = response,
                  let sessionID = message["SessionID"] as? String, !sessionID.isEmpty else {
                throw DeviceProtocolError.deviceRefused(code: "SessionRefused")
            }
            // lockdownd requests a TLS upgrade on the existing connection.
            // The current transport has no upgrade operation: never continue
            // a session that requests one over an unverified channel.
            if let ssl = message["EnableSessionSSL"] {
                guard let requiresSSL = ssl as? Bool else {
                    throw DeviceProtocolError.deviceRefused(code: "InvalidSessionSSL")
                }
                if requiresSSL { throw DeviceProtocolError.authenticatedTransportUnavailable }
            }
            let result = try await body(stream)
            await transport.close()
            return result
        } catch {
            await transport.close()
            throw error
        }
    }
}

/// One lockdownd conversation over a transport, with framing applied.
struct LockdownStream {

    let transport: any DeviceTransport

    func request(_ request: LockdownProtocol.Request) async throws
        -> LockdownProtocol.Response {
        let message = request.message(label: DeviceBridgeService.clientLabel)
        try await transport.send(try PropertyListFraming.encodedMessage(message))
        let prefix = try await transport.receiveExactly(
            PropertyListFraming.lengthPrefixBytes, maximum: PropertyListFraming.lengthPrefixBytes)
        let length = try PropertyListFraming.declaredLength(prefix: prefix)
        let payload = try await transport.receiveExactly(length, maximum: PropertyListFraming.maximumMessageBytes)
        return LockdownProtocol.Response.decode(try PropertyListFraming.decode(payload), expectedRequest: request.verb)
    }
}

/// Persistence for pairing records. The platform implementation keeps them in
/// the Keychain; nothing else may store the private key.
protocol PairingRecordStoring: Sendable {
    func save(_ record: DevicePairingRecord) throws
    func all() throws -> [DevicePairingRecord]
    func remove(hostIdentifier: String) throws
}
