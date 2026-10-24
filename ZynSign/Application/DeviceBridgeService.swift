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
            let session = try await stream.request(.startSession(
                hostID: record.hostIdentifier, systemBUID: record.systemBUID))
            guard case .success(let sessionAnswer) = session,
                  (sessionAnswer["EnableSessionID"] as? Bool) == true else {
                throw DeviceProtocolError.deviceRefused(code: "SessionRefused")
            }
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
        let (port, _) = try await servicePort(LockdownProtocol.afcService, record: record)
        let transport = makeTransport()
        try await transport.connect(pairing: record, port: port)
        defer { Task { await transport.close() } }

        var transaction: UInt64 = 0
        func exchange(_ operation: AFCProtocol.Operation, payload: Data) async throws
            -> (status: UInt64, body: Data) {
            transaction += 1
            let header = AFCProtocol.Header(entryType: 0, operation: operation,
                                            operationRaw: operation.rawValue,
                                            transaction: transaction,
                                            payloadSize: UInt64(payload.count))
            try await transport.send(header.serialized() + payload)
            let headerBytes = try await transport.receive(
                maximumBytes: AFCProtocol.headerLength)
            let decoded = try AFCProtocol.Header.decode(headerBytes)
            let body = decoded.payloadSize > 0
                ? try await transport.receive(maximumBytes: Int(decoded.payloadSize))
                : Data()
            if decoded.operation == .status, body.count >= 8 {
                return (body.littleEndianUInt64(at: 0), Data(body.dropFirst(8)))
            }
            return (0, body)
        }

        // The hello exchange names the protocol before any operation.
        let hello = try await exchange(.hello, payload: AFCProtocol.magic)
        guard hello.status == 0 else {
            throw DeviceProtocolError.deviceRefused(code: "AFCHello")
        }
        _ = try await exchange(.makeDirectory,
                               payload: Data("/PublicStaging".utf8) + Data([0]))
        let opened = try await exchange(
            .fileOpen, payload: Data(remotePath.utf8) + Data([0]) + Data(count: 8))
        guard opened.status == 0, opened.body.count >= 8 else {
            throw DeviceProtocolError.deviceRefused(code: "AFCOpen")
        }
        let handle = opened.body.littleEndianUInt64(at: 0)
        var writeHeader = Data()
        writeHeader.appendLittleEndian(handle)
        let written = try await exchange(.fileWrite, payload: writeHeader + package)
        guard written.status == 0 else {
            throw DeviceProtocolError.deviceRefused(code: "AFCWrite")
        }
        var closeHeader = Data()
        closeHeader.appendLittleEndian(handle)
        _ = try await exchange(.fileClose, payload: closeHeader)
    }

    private func installStagedPackage(
        remotePath: String, bundleIdentifier: String,
        record: DevicePairingRecord
    ) async throws -> [InstallationProxyProtocol.Progress] {
        let (port, _) = try await servicePort(
            LockdownProtocol.installationProxyService, record: record)
        let transport = makeTransport()
        try await transport.connect(pairing: record, port: port)
        defer { Task { await transport.close() } }

        let command = InstallationProxyProtocol.Command.install(
            packagePath: remotePath, bundleIdentifier: bundleIdentifier, isUpgrade: false)
        let framed = try PropertyListFraming.encodedMessage(command.message())
        try await transport.send(framed)

        var progress: [InstallationProxyProtocol.Progress] = []
        while true {
            let prefix = try await transport.receive(
                maximumBytes: PropertyListFraming.lengthPrefixBytes)
            let length = try PropertyListFraming.declaredLength(prefix: prefix)
            let payload = try await transport.receive(maximumBytes: length)
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
    }

    /// Ask lockdownd to start a service and return its port. The device
    /// decides whether the service exists at all.
    private func servicePort(_ name: String,
                             record: DevicePairingRecord) async throws -> (Int, Bool) {
        try await withLockdown(record) { stream in
            let response = try await stream.request(.startService(name: name))
            guard case .success(let message) = response else {
                throw DeviceProtocolError.deviceRefused(code: "StartService")
            }
            guard let port = message["Port"] as? Int else {
                throw DeviceProtocolError.deviceRefused(code: "NoServicePort")
            }
            return (port, message["EnableServiceSSL"] as? Bool ?? false)
        }
    }

    private func withLockdown<T>(
        _ record: DevicePairingRecord,
        _ body: (LockdownStream) async throws -> T
    ) async throws -> T {
        let transport = makeTransport()
        try await transport.connect(pairing: record, port: LockdownProtocol.defaultPort)
        defer { Task { await transport.close() } }
        return try await body(LockdownStream(transport: transport))
    }
}

/// One lockdownd conversation over a transport, with framing applied.
struct LockdownStream {

    let transport: any DeviceTransport

    func request(_ request: LockdownProtocol.Request) async throws
        -> LockdownProtocol.Response {
        let message = request.message(label: DeviceBridgeService.clientLabel)
        try await transport.send(try PropertyListFraming.encodedMessage(message))
        let prefix = try await transport.receive(
            maximumBytes: PropertyListFraming.lengthPrefixBytes)
        let length = try PropertyListFraming.declaredLength(prefix: prefix)
        let payload = try await transport.receive(maximumBytes: length)
        return LockdownProtocol.Response.decode(try PropertyListFraming.decode(payload))
    }
}

/// Persistence for pairing records. The platform implementation keeps them in
/// the Keychain; nothing else may store the private key.
protocol PairingRecordStoring: Sendable {
    func save(_ record: DevicePairingRecord) throws
    func all() throws -> [DevicePairingRecord]
    func remove(hostIdentifier: String) throws
}
