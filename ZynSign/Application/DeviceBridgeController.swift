import Foundation

/// Endpoint configuration shared with the `DeviceTransport` factory.
final class DeviceBridgeEndpointConfig: @unchecked Sendable {
    private let lock = NSLock()
    private var _host: String
    private var _port: UInt16

    init(host: String = "10.7.0.1", port: UInt16 = 27015) {
        self._host = host
        self._port = port
    }

    var snapshot: (host: String, port: UInt16) {
        lock.lock()
        defer { lock.unlock() }
        return (_host, _port)
    }

    func update(host: String, port: UInt16) {
        lock.lock()
        _host = host
        _port = port
        lock.unlock()
    }
}

/// Application-layer coordinator for `.mobiledevicepairing` records, wire-free
/// loopback / local-tunnel `lockdownd` sessions, UDID discovery, and direct
/// `AFC` + `installation_proxy` package installation & 7-day lease refresh.
@MainActor
final class DeviceBridgeController: ObservableObject {

    enum ControllerError: Error, LocalizedError {
        case noPairingRecordImported
        case unreadablePackageFile

        var errorDescription: String? {
            switch self {
            case .noPairingRecordImported:
                return "Import a .mobiledevicepairing file before starting a device session."
            case .unreadablePackageFile:
                return "Could not read the signed .ipa package for AFC upload."
            }
        }
    }

    @Published private(set) var pairingRecords: [DevicePairingRecord] = []
    @Published private(set) var lastConnectedDevice: PairedDevice?
    @Published private(set) var lastInstallOutcome: DeviceInstallOutcome?
    @Published var tunnelHost: String {
        didSet { syncEndpoint() }
    }
    @Published var muxPortText: String {
        didSet { syncEndpoint() }
    }
    @Published private(set) var isBusy = false
    @Published var statusMessage: String?
    @Published var errorMessage: String?

    let bridgeService: DeviceBridgeService
    let isTransportComposed: Bool
    private let digest: any MessageDigest
    private let recordStore: any PairingRecordStoring
    private let endpointConfig: DeviceBridgeEndpointConfig

    var hasPairingRecord: Bool {
        !pairingRecords.isEmpty
    }

    nonisolated init(
        recordStore: any PairingRecordStoring,
        digest: any MessageDigest,
        endpointConfig: DeviceBridgeEndpointConfig,
        isTransportComposed: Bool = true,
        makeTransport: @escaping @Sendable () -> any DeviceTransport
    ) {
        self.recordStore = recordStore
        self.digest = digest
        self.endpointConfig = endpointConfig
        self.isTransportComposed = isTransportComposed
        let snap = endpointConfig.snapshot
        self.tunnelHost = snap.host
        self.muxPortText = String(snap.port)
        let service = DeviceBridgeService(
            recordStore: recordStore,
            makeTransport: makeTransport
        )
        self.bridgeService = service
        self.pairingRecords = (try? service.pairingRecords()) ?? []
    }

    func reloadRecords() {
        pairingRecords = (try? bridgeService.pairingRecords()) ?? []
    }

    @discardableResult
    func importPairingFile(data: Data) throws -> DevicePairingRecord {
        errorMessage = nil
        do {
            let record = try bridgeService.importPairingRecord(data: data, digest: digest)
            reloadRecords()
            statusMessage = "Imported pairing record (HostID \(record.hostFingerprint.prefix(12))…)."
            return record
        } catch let error as PairingRecordError {
            errorMessage = error.message
            throw error
        } catch {
            errorMessage = error.localizedDescription
            throw error
        }
    }

    func removePairingRecord(hostIdentifier: String) throws {
        try recordStore.remove(hostIdentifier: hostIdentifier)
        if lastConnectedDevice?.hostIdentifier == hostIdentifier {
            lastConnectedDevice = nil
        }
        reloadRecords()
        statusMessage = "Removed pairing record from Keychain."
    }

    @discardableResult
    func probeDeviceConnection(using explicitRecord: DevicePairingRecord? = nil) async throws -> PairedDevice {
        guard let record = explicitRecord ?? pairingRecords.first else {
            throw ControllerError.noPairingRecordImported
        }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }

        do {
            let device = try await bridgeService.connect(record: record)
            lastConnectedDevice = device
            statusMessage = "Connected to \(device.name) (iOS \(device.productVersion) · UDID \(device.uniqueDeviceID.prefix(8))…)."
            return device
        } catch {
            errorMessage = error.localizedDescription
            throw error
        }
    }

    @discardableResult
    func installSignedPackage(
        at ipaURL: URL,
        bundleIdentifier: String,
        using explicitRecord: DevicePairingRecord? = nil
    ) async throws -> DeviceInstallOutcome {
        guard let record = explicitRecord ?? pairingRecords.first else {
            throw ControllerError.noPairingRecordImported
        }
        guard let packageBytes = try? Data(contentsOf: ipaURL), !packageBytes.isEmpty else {
            throw ControllerError.unreadablePackageFile
        }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }

        do {
            let outcome = try await bridgeService.install(
                package: packageBytes,
                bundleIdentifier: bundleIdentifier,
                fileName: ipaURL.lastPathComponent,
                record: record
            )
            lastInstallOutcome = outcome
            statusMessage = outcome.isInstalled
                ? "Installed \(bundleIdentifier) via installation_proxy (Complete)."
                : "Device reported status: \(outcome.finalStatus)."
            return outcome
        } catch {
            errorMessage = error.localizedDescription
            throw error
        }
    }

    private func syncEndpoint() {
        let trimmedHost = tunnelHost.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveHost = trimmedHost.isEmpty ? "10.7.0.1" : trimmedHost
        let parsedPort = UInt16(muxPortText.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 27015
        endpointConfig.update(host: effectiveHost, port: parsedPort == 0 ? 27015 : parsedPort)
    }
}
