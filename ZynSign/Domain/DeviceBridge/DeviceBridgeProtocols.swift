import Foundation

/// The wire protocols a device session is made of, as pure codecs.
///
/// Four layers sit between the app and a device's installer, and every one of
/// them is a length-prefixed message:
///
/// 1. **usbmuxd** — `16`-byte little-endian header (`length`, `version`,
///    `message`, `tag`) followed by a property list. The daemon proxies bytes
///    to a device port after answering `Result`.
/// 2. **lockdownd** — `4`-byte big-endian length followed by a property list,
///    carrying `QueryType`, `Pair`, `StartSession` and `StartService`.
/// 3. **AFC** — a `40`-byte little-endian header (`CFA6LPAA` magic plus four
///    `UInt64` fields) for file transfer.
/// 4. **installation_proxy** — lockdownd framing, with `Install` answered by a
///    stream of progress dictionaries.
///
/// Encoding and decoding live here, with no socket in sight, so a recorded
/// conversation can be replayed byte for byte in a test. The sockets live in
/// `Platform`.
enum USBMuxProtocol {

    static let headerLength = 16
    static let version: UInt32 = 1
    /// The largest plist frame this app will accept from a device.
    static let maximumPayloadBytes = 8 * 1_024 * 1_024

    enum MessageType: UInt32, Sendable {
        case result = 1
        case connect = 2
        case listen = 3
        case plist = 8
    }

    struct Frame: Equatable, Sendable {
        let type: MessageType
        let tag: UInt32
        let payload: Data

        func serialized() throws -> Data {
            var data = Data(capacity: USBMuxProtocol.headerLength + payload.count)
            let length = USBMuxProtocol.headerLength + payload.count
            guard payload.count <= USBMuxProtocol.maximumPayloadBytes,
                  let length32 = UInt32(exactly: length) else {
                throw DeviceProtocolError.frameTooLarge(bytes: length)
            }
            data.appendLittleEndian(length32)
            data.appendLittleEndian(USBMuxProtocol.version)
            data.appendLittleEndian(type.rawValue)
            data.appendLittleEndian(tag)
            data.append(payload)
            return data
        }
    }

    enum Request: Equatable, Sendable {
        case listDevices
        case connect(deviceID: Int, port: Int)

        func payload() throws -> [String: Any] {
            switch self {
            case .listDevices:
                return [
                    "MessageType": "ListDevices",
                    "ClientVersionString": "ZynSign-1.0",
                    "ProgName": "ZynSign",
                ]
            case .connect(let deviceID, let port):
                guard (1...65_535).contains(port) else {
                    throw DeviceProtocolError.invalidPort(port)
                }
                return [
                    "MessageType": "Connect",
                    "ClientVersionString": "ZynSign-1.0",
                    "ProgName": "ZynSign",
                    "DeviceID": deviceID,
                    // usbmux carries the port as a 16-bit network-order value
                    // inside the property list.
                    "PortNumber": Int(UInt16(port).bigEndian),
                ]
            }
        }
    }

    static func decodeHeader(_ data: Data) throws -> (Frame, Int) {
        guard data.count >= headerLength else {
            throw DeviceProtocolError.truncatedFrame(needed: headerLength, received: data.count)
        }
        let length = Int(data.littleEndianUInt32(at: 0))
        let version = data.littleEndianUInt32(at: 4)
        let message = data.littleEndianUInt32(at: 8)
        let tag = data.littleEndianUInt32(at: 12)
        guard version == self.version else {
            throw DeviceProtocolError.unsupportedVersion(version)
        }
        guard let type = MessageType(rawValue: message) else {
            throw DeviceProtocolError.unknownMessageType(message)
        }
        guard length >= headerLength, length - headerLength <= maximumPayloadBytes else {
            throw DeviceProtocolError.invalidFrameLength(length)
        }
        return (Frame(type: type, tag: tag, payload: Data()), length)
    }
}

/// lockdownd and every service it starts share one framing rule.
enum PropertyListFraming {

    static let lengthPrefixBytes = 4
    static let maximumMessageBytes = 8 * 1_024 * 1_024

    /// `length` is big-endian and counts the plist body only.
    static func frame(_ payload: Data) throws -> Data {
        guard payload.count <= maximumMessageBytes,
              let length = UInt32(exactly: payload.count) else {
            throw DeviceProtocolError.frameTooLarge(bytes: payload.count)
        }
        var data = Data(capacity: 4 + payload.count)
        data.append(UInt8((length >> 24) & 0xFF))
        data.append(UInt8((length >> 16) & 0xFF))
        data.append(UInt8((length >> 8) & 0xFF))
        data.append(UInt8(length & 0xFF))
        data.append(payload)
        return data
    }

    static func encodedMessage(_ message: [String: Any]) throws -> Data {
        let plist = try PropertyListSerialization.data(
            fromPropertyList: message, format: .xml, options: 0)
        return try frame(plist)
    }

    /// The declared length from a four-byte prefix.
    static func declaredLength(prefix: Data) throws -> Int {
        guard prefix.count == lengthPrefixBytes else {
            throw DeviceProtocolError.truncatedFrame(needed: lengthPrefixBytes,
                                                     received: prefix.count)
        }
        let value = prefix.reduce(0) { ($0 << 8) | Int($1) }
        guard value > 0, value <= maximumMessageBytes else {
            throw DeviceProtocolError.invalidFrameLength(value)
        }
        return value
    }

    static func decode(_ payload: Data) throws -> [String: Any] {
        guard !payload.isEmpty else { throw DeviceProtocolError.emptyMessage }
        let value = try PropertyListSerialization.propertyList(
            from: payload, options: [], format: nil)
        guard let dictionary = value as? [String: Any] else {
            throw DeviceProtocolError.messageIsNotADictionary
        }
        return dictionary
    }
}

/// What lockdownd can be asked, and how its answer is judged.
enum LockdownProtocol {

    static let service = "com.apple.mobile.lockdown"
    static let afcService = "com.apple.afc"
    static let installationProxyService = "com.apple.mobile.installation_proxy"
    static let defaultPort = 62_078

    enum Request: Equatable, Sendable {
        case queryType
        case allValues
        case value(key: String, domain: String)
        case pair(recordData: Data)
        case startSession(hostID: String, systemBUID: String)
        case startService(name: String)
        case stopSession

        var verb: String {
            switch self {
            case .queryType: return "QueryType"
            case .allValues, .value: return "GetValue"
            case .pair: return "Pair"
            case .startSession: return "StartSession"
            case .startService: return "StartService"
            case .stopSession: return "StopSession"
            }
        }

        func message(label: String) -> [String: Any] {
            var message: [String: Any] = ["Label": label, "Request": verb]
            switch self {
            case .queryType, .stopSession, .allValues:
                break
            case .value(let key, let domain):
                message["Key"] = key
                message["Domain"] = domain
            case .pair(let recordData):
                message["PairRecordData"] = recordData
                message["ProtocolVersion"] = "2"
            case .startSession(let hostID, let systemBUID):
                message["HostID"] = hostID
                message["SystemBUID"] = systemBUID
            case .startService(let name):
                message["Service"] = name
            }
            return message
        }
    }

    struct DeviceValues: Equatable, Sendable {
        let uniqueDeviceID: String
        let deviceName: String
        let productVersion: String
        let buildVersion: String
        let productType: String
        let cpuArchitecture: String

        init(values: [String: Any]) {
            uniqueDeviceID = values["UniqueDeviceID"] as? String ?? ""
            deviceName = values["DeviceName"] as? String ?? "Device"
            productVersion = values["ProductVersion"] as? String ?? "0"
            buildVersion = values["BuildVersion"] as? String ?? "0"
            productType = values["ProductType"] as? String ?? "iPhone"
            cpuArchitecture = values["CPUArchitecture"] as? String ?? "arm64"
        }
    }

    /// Accept a modern result-less response only when its Request matches the
    /// request sent. Callers must still validate the expected payload fields.
    ///
    /// Not `Equatable`: the success case carries the device's dictionary,
    /// whose contents are not necessarily comparable. Callers match the case.
    enum Response: Sendable {
        case success([String: Any])
        case failure(code: String)

        static func decode(_ message: [String: Any], expectedRequest: String) -> Response {
            guard let request = message["Request"] as? String, request == expectedRequest else {
                return .failure(code: "UnexpectedResponse")
            }
            if let error = message["Error"] {
                guard let code = error as? String, !code.isEmpty else {
                    return .failure(code: "InvalidError")
                }
                return .failure(code: code)
            }
            if let result = message["Result"] {
                guard let result = result as? String, !result.isEmpty else {
                    return .failure(code: "InvalidResult")
                }
                return result == "Success" ? .success(message) : .failure(code: result)
            }
            return .success(message)
        }
    }
}

/// AFC (the device's file service) header codec.
enum AFCProtocol {

    static let magic = Data("CFA6LPAA".utf8)
    static let headerLength = 40

    enum Operation: UInt64, Sendable {
        case status = 0x01
        case data = 0x02
        case readDirectory = 0x03
        case delete = 0x08
        case makeDirectory = 0x09
        case getInfo = 0x0A
        case fileOpen = 0x0D
        case fileOpenResult = 0x0E
        case fileRead = 0x0F
        case fileWrite = 0x10
        case fileClose = 0x14
        case truncate = 0x07
        case rename = 0x18
    }

    /// AFC lengths include the header. `thisLength` counts the header and
    /// command arguments; `entireLength` additionally includes any data body.
    struct Header: Equatable, Sendable {
        let entireLength: UInt64
        let thisLength: UInt64
        let transaction: UInt64
        let operationRaw: UInt64
        var operation: Operation? { Operation(rawValue: operationRaw) }
        var payloadSize: UInt64 { entireLength - UInt64(AFCProtocol.headerLength) }

        func serialized() -> Data {
            var data = Data(capacity: AFCProtocol.headerLength)
            data.append(AFCProtocol.magic)
            data.appendLittleEndian(entireLength)
            data.appendLittleEndian(thisLength)
            data.appendLittleEndian(transaction)
            data.appendLittleEndian(operationRaw)
            return data
        }

        static func decode(_ data: Data) throws -> Header {
            guard data.count == AFCProtocol.headerLength else {
                throw DeviceProtocolError.truncatedFrame(needed: AFCProtocol.headerLength, received: data.count)
            }
            guard data.prefix(8) == AFCProtocol.magic else { throw DeviceProtocolError.invalidAFCMagic }
            let total = data.littleEndianUInt64(at: 8)
            let current = data.littleEndianUInt64(at: 16)
            guard current >= UInt64(AFCProtocol.headerLength), current <= total,
                  total <= UInt64(AFCProtocol.headerLength + PropertyListFraming.maximumMessageBytes) else {
                throw DeviceProtocolError.invalidFrameLength(-1)
            }
            return Header(entireLength: total, thisLength: current,
                          transaction: data.littleEndianUInt64(at: 24),
                          operationRaw: data.littleEndianUInt64(at: 32))
        }
    }

    /// The device's errno for "already exists"; creating `/PublicStaging` is
    /// idempotent, so this status is success for `mkdir`.
    static let alreadyExistsStatus: UInt64 = 16
}

/// installation_proxy: one request, then a stream of progress dictionaries.
enum InstallationProxyProtocol {

    enum Command: Equatable, Sendable {
        case install(packagePath: String, bundleIdentifier: String, isUpgrade: Bool)
        case uninstall(bundleIdentifier: String)
        case listApplications
        case lookup(bundleIdentifiers: [String])

        func message() -> [String: Any] {
            switch self {
            case .install(let packagePath, let bundleIdentifier, let isUpgrade):
                return [
                    "Command": isUpgrade ? "Upgrade" : "Install",
                    "PackagePath": packagePath,
                    "ClientOptions": [
                        "PackageType": "Developer",
                        "CFBundleIdentifier": bundleIdentifier,
                    ],
                ]
            case .uninstall(let bundleIdentifier):
                return ["Command": "Uninstall",
                        "ApplicationIdentifier": bundleIdentifier]
            case .listApplications:
                return ["Command": "ListApps"]
            case .lookup(let bundleIdentifiers):
                return ["Command": "Lookup",
                        "ClientOptions": ["BundleIDs": bundleIdentifiers]]
            }
        }
    }

    /// The statuses a device streams. `Unknown` is kept as a value so a new
    /// device status is reported rather than dropped.
    enum Status: Equatable, Sendable {
        case creatingStagingDirectory
        case extractingPackage
        case inspectingPackage
        case verifyingApplication
        case installingApplication
        case complete
        case unknown(String)

        init(raw: String) {
            switch raw {
            case "CreatingStagingDirectory": self = .creatingStagingDirectory
            case "ExtractingPackage": self = .extractingPackage
            case "InspectingPackage": self = .inspectingPackage
            case "VerifyingApplication": self = .verifyingApplication
            case "InstallingApplication": self = .installingApplication
            case "Complete": self = .complete
            default: self = .unknown(raw)
            }
        }

        var label: String {
            switch self {
            case .creatingStagingDirectory: return "Creating staging directory"
            case .extractingPackage: return "Extracting package"
            case .inspectingPackage: return "Inspecting package"
            case .verifyingApplication: return "Verifying signature"
            case .installingApplication: return "Installing"
            case .complete: return "Complete"
            case .unknown(let raw): return raw
            }
        }
    }

    struct Progress: Equatable, Sendable {
        let status: Status
        let percentComplete: Int

        var isTerminal: Bool { status == .complete }
    }

    /// One decoded progress message, or the device's refusal. Not
    /// `Equatable` for the same reason as `LockdownProtocol.Response`.
    enum Update: Sendable {
        case progress(Progress)
        case failure(code: String, description: String)
        case listing([String: Any])

        static func decode(_ message: [String: Any]) -> Update {
            if let error = message["Error"] as? String {
                return .failure(code: error,
                                description: message["ErrorDescription"] as? String ?? "")
            }
            if let status = message["Status"] as? String {
                return .progress(Progress(
                    status: Status(raw: status),
                    percentComplete: message["PercentComplete"] as? Int ?? 0))
            }
            if let list = message["CurrentList"] as? [String: Any] {
                return .listing(list)
            }
            return .failure(code: "UnrecognisedMessage", description: "The device sent a message this app cannot read.")
        }
    }
}

/// Every protocol refusal, in one typed list.
enum DeviceProtocolError: LocalizedError, Equatable, Hashable, Sendable {
    case truncatedFrame(needed: Int, received: Int)
    case invalidFrameLength(Int)
    case frameTooLarge(bytes: Int)
    case unsupportedVersion(UInt32)
    case unknownMessageType(UInt32)
    case invalidPort(Int)
    case emptyMessage
    case messageIsNotADictionary
    case invalidAFCMagic
    case deviceRefused(code: String)
    case deviceUnavailable
    case authenticatedTransportUnavailable
    case notPaired
    case sessionNotStarted

    var errorDescription: String? { message }

    var message: String {
        switch self {
        case .truncatedFrame(let needed, let received):
            return "The device frame is incomplete: \(received) of \(needed) bytes."
        case .invalidFrameLength(let length):
            return "The device declared a frame length of \(length) bytes."
        case .frameTooLarge(let bytes):
            return "The message is \(bytes) bytes; the limit is 8 MiB."
        case .unsupportedVersion(let version):
            return "usbmuxd protocol version \(version) is not supported."
        case .unknownMessageType(let value):
            return "usbmuxd message type \(value) is not one this app sends or reads."
        case .invalidPort(let port):
            return "\(port) is not a device port."
        case .emptyMessage:
            return "The device sent an empty message."
        case .messageIsNotADictionary:
            return "The device message is not a property-list dictionary."
        case .invalidAFCMagic:
            return "The AFC stream does not start with its magic."
        case .deviceRefused(let code):
            return "The device refused the request: \(code)."
        case .deviceUnavailable:
            return "No paired device is reachable."
        case .authenticatedTransportUnavailable:
            return "Device sessions are unavailable until authenticated TLS and protocol framing are implemented and verified."
        case .notPaired:
            return "A pairing record is required before a session can start."
        case .sessionNotStarted:
            return "The device session has not started."
        }
    }
}

// --- little-endian helpers -------------------------------------------------
//
// Mach-O, usbmuxd and AFC are little-endian; lockdownd framing is big-endian.
// Both directions are written out here rather than relying on platform byte
// order, so a recorded frame decodes identically on any host.

extension Data {

    mutating func appendLittleEndian(_ value: UInt32) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 24) & 0xFF))
    }

    mutating func appendLittleEndian(_ value: UInt64) {
        for shift in stride(from: 0, to: 64, by: 8) {
            append(UInt8((value >> UInt64(shift)) & 0xFF))
        }
    }

    func littleEndianUInt32(at offset: Int) -> UInt32 {
        guard offset >= 0, offset + 4 <= count else { return 0 }
        let start = index(startIndex, offsetBy: offset)
        var value: UInt32 = 0
        for index in 0..<4 {
            value |= UInt32(self[start + index]) << (8 * UInt32(index))
        }
        return value
    }

    func littleEndianUInt64(at offset: Int) -> UInt64 {
        guard offset >= 0, offset + 8 <= count else { return 0 }
        let start = index(startIndex, offsetBy: offset)
        var value: UInt64 = 0
        for index in 0..<8 {
            value |= UInt64(self[start + index]) << (8 * UInt64(index))
        }
        return value
    }
}
