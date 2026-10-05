import Foundation

/// One Apple device model the firmware browser can query.
struct IPSWDevice: Decodable, Equatable, Hashable, Identifiable, Sendable {
    let name: String
    let identifier: String

    var id: String { identifier }
}

/// One firmware release and the signing status reported by IPSW.me.
struct IPSWFirmware: Decodable, Equatable, Identifiable, Sendable {
    let identifier: String
    let version: String
    let buildID: String
    let fileSize: Int64?
    let releaseDate: Date?
    let signed: Bool?
    private let downloadAddress: String?

    var id: String { "\(identifier):\(version):\(buildID)" }

    /// Only return HTTPS download links on Apple's firmware hosts.
    /// A catalog response cannot turn this row into an arbitrary web link.
    var appleDownloadURL: URL? {
        guard let downloadAddress,
              let url = URL(string: downloadAddress),
              url.scheme?.lowercased() == "https",
              url.user == nil,
              url.password == nil,
              url.port == nil || url.port == 443,
              url.pathExtension.lowercased() == "ipsw",
              let host = url.host?.lowercased(),
              host == "appldnld.apple.com"
                || host.hasSuffix(".appldnld.apple.com")
                || host == "cdn-apple.com"
                || host.hasSuffix(".cdn-apple.com") else {
            return nil
        }
        return url
    }

    private enum CodingKeys: String, CodingKey {
        case identifier
        case version
        case buildID = "buildid"
        case fileSize = "filesize"
        case releaseDate = "releasedate"
        case signed
        case downloadAddress = "url"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        identifier = try container.decode(String.self, forKey: .identifier)
        version = try container.decode(String.self, forKey: .version)
        buildID = try container.decode(String.self, forKey: .buildID)
        fileSize = try container.decodeIfPresent(Int64.self, forKey: .fileSize)
        signed = try container.decodeIfPresent(Bool.self, forKey: .signed)
        downloadAddress = try container.decodeIfPresent(String.self, forKey: .downloadAddress)
        let releaseDateString = try container.decodeIfPresent(String.self, forKey: .releaseDate)
        releaseDate = Self.parseDate(releaseDateString)
    }

    private static func parseDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        return standard.date(from: value)
    }
}

/// The firmware catalogue interface used by Settings, Home, and tests.
protocol IPSWFirmwareCatalog: Sendable {
    func devices() async throws -> [IPSWDevice]
    func firmwares(for device: IPSWDevice) async throws -> [IPSWFirmware]
}

/// A testable boundary for loading IPSW catalog JSON over HTTPS.
protocol IPSWFirmwareCatalogTransport: Sendable {
    func fetch(url: URL, timeout: TimeInterval) async throws -> Data
}

/// Reads device models and firmware releases from the public IPSW.me API.
///
/// The service only constructs requests to the fixed API host, validates
/// device identifiers before placing them in a URL, and bounds response size.
/// Signing status is a point-in-time report from IPSW.me; Apple's restore
/// servers remain authoritative and can change that status at any time.
struct IPSWFirmwareCatalogService: IPSWFirmwareCatalog, Sendable {
    static let apiBaseURL = URL(string: "https://api.ipsw.me/v4")
    static let requestTimeout: TimeInterval = 15
    static let maximumResponseBytes = 4 * 1_024 * 1_024

    private struct DeviceFirmwareResponse: Decodable {
        let firmwares: [IPSWFirmware]
    }

    private let transport: any IPSWFirmwareCatalogTransport
    private let baseURL: URL?

    init(
        transport: any IPSWFirmwareCatalogTransport,
        baseURL: URL? = IPSWFirmwareCatalogService.apiBaseURL
    ) {
        self.transport = transport
        self.baseURL = baseURL
    }

    func devices() async throws -> [IPSWDevice] {
        guard let baseURL else { throw IPSWFirmwareCatalogError.invalidResponse }
        let url = baseURL.appendingPathComponent("devices", isDirectory: false)
        let data = try await responseData(from: url)
        let devices = try decode([IPSWDevice].self, from: data)
        return devices.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    func firmwares(for device: IPSWDevice) async throws -> [IPSWFirmware] {
        guard let baseURL else { throw IPSWFirmwareCatalogError.invalidResponse }
        guard Self.isSafeDeviceIdentifier(device.identifier) else {
            throw IPSWFirmwareCatalogError.invalidDeviceIdentifier
        }

        let deviceURL = baseURL
            .appendingPathComponent("device", isDirectory: true)
            .appendingPathComponent(device.identifier, isDirectory: false)
        guard var components = URLComponents(url: deviceURL, resolvingAgainstBaseURL: false) else {
            throw IPSWFirmwareCatalogError.invalidResponse
        }
        components.queryItems = [URLQueryItem(name: "type", value: "ipsw")]
        guard let url = components.url else { throw IPSWFirmwareCatalogError.invalidResponse }

        let data = try await responseData(from: url)
        let releases = try decode(DeviceFirmwareResponse.self, from: data).firmwares
        return releases.sorted { lhs, rhs in
            switch (lhs.releaseDate, rhs.releaseDate) {
            case let (left?, right?): return left > right
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return lhs.version.localizedStandardCompare(rhs.version) == .orderedDescending
            }
        }
    }

    private func responseData(from url: URL) async throws -> Data {
        let data: Data
        do {
            data = try await transport.fetch(url: url, timeout: Self.requestTimeout)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as IPSWFirmwareCatalogError {
            throw error
        } catch {
            throw IPSWFirmwareCatalogError.requestFailed
        }
        guard data.count <= Self.maximumResponseBytes else {
            throw IPSWFirmwareCatalogError.responseTooLarge
        }
        return data
    }

    private func decode<Value: Decodable>(_ type: Value.Type, from data: Data) throws -> Value {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw IPSWFirmwareCatalogError.malformedResponse
        }
    }

    private static func isSafeDeviceIdentifier(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 80 else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            (scalar.value >= 48 && scalar.value <= 57)
                || (scalar.value >= 65 && scalar.value <= 90)
                || (scalar.value >= 97 && scalar.value <= 122)
                || ",._-".unicodeScalars.contains(scalar)
        }
    }
}

/// Safe, user-facing failures from IPSW catalog lookup.
enum IPSWFirmwareCatalogError: Error, Equatable, LocalizedError {
    case requestFailed
    case invalidResponse
    case responseTooLarge
    case malformedResponse
    case invalidDeviceIdentifier

    var errorDescription: String? {
        switch self {
        case .requestFailed:
            return "The firmware catalog could not be reached. Check your connection and try again."
        case .invalidResponse:
            return "The firmware catalog returned an unexpected response."
        case .responseTooLarge:
            return "The firmware catalog response was larger than expected and was stopped."
        case .malformedResponse:
            return "The firmware catalog data could not be read. Try again later."
        case .invalidDeviceIdentifier:
            return "This device identifier is not valid."
        }
    }
}

extension IPSWFirmwareCatalogError: Sendable {}
