import Foundation

/// Why a local transfer session refused something.
///
/// Every case carries the HTTP status the caller answers with, so the
/// listening code never invents one. The cases are the whole vocabulary: a
/// refusal that is not named here cannot happen, which is why "it failed" is
/// never one of them.
enum LocalTransferRejection: Error, Equatable, Hashable, Sendable {

    /// The request head exceeded the session's head bound.
    case headTooLarge

    /// The request line could not be split into method, target and version.
    case malformedRequestLine

    /// A header field was malformed, folded across lines, or unbounded.
    case malformedHeader

    /// `Content-Length` arrived more than once.
    case conflictingContentLength

    /// `Content-Length` was not a bounded decimal number.
    case invalidContentLength

    /// A body was declared with `Transfer-Encoding`, which is not implemented.
    case unsupportedTransferEncoding

    /// A write arrived without a declared length.
    case lengthRequired

    /// The declared or received body exceeded the session's upload bound.
    case payloadTooLarge(limit: Int)

    /// The request did not carry the session's token, or carried the wrong one.
    case unauthorized

    /// The target named no route this surface answers.
    case notFound

    /// The destination name was not one this app will accept.
    case filenameRejected(String)

    /// A write arrived with no bytes.
    case emptyPayload

    /// The session is not listening, or its window has closed.
    case notListening

    /// The session's request budget is spent.
    case requestBudgetExhausted

    /// The received bytes could not be moved into the transfer workspace.
    case storageFailure

    /// The request used a method this surface does not answer.
    case unsupportedMethod

    /// Bytes arrived beyond the declared body length: a second request
    /// smuggled behind the first, or a client that cannot count.
    case unexpectedBodyBytes

    /// The connection was open, but the request did not complete in time.
    case requestTimedOut

    /// The status line this refusal is answered with.
    var status: Int {
        switch self {
        case .headTooLarge: return 431
        case .unsupportedMethod: return 405
        case .unexpectedBodyBytes: return 400
        case .requestTimedOut: return 408
        case .malformedRequestLine, .malformedHeader, .conflictingContentLength,
             .invalidContentLength: return 400
        case .unsupportedTransferEncoding, .lengthRequired: return 411
        case .payloadTooLarge: return 413
        case .unauthorized: return 401
        case .notFound: return 404
        case .filenameRejected: return 415
        case .emptyPayload: return 400
        case .notListening: return 503
        case .requestBudgetExhausted: return 429
        case .storageFailure: return 507
        }
    }

    /// The reason phrase the status line prints.
    var reason: String {
        switch self.status {
        case 400: return "Bad Request"
        case 405: return "Method Not Allowed"
        case 408: return "Request Timeout"
        case 401: return "Unauthorized"
        case 404: return "Not Found"
        case 411: return "Length Required"
        case 413: return "Content Too Large"
        case 415: return "Unsupported Media Type"
        case 429: return "Too Many Requests"
        case 431: return "Request Header Fields Too Large"
        case 503: return "Service Unavailable"
        case 507: return "Insufficient Storage"
        default: return "Error"
        }
    }

    /// A sentence a person can act on. It says what was refused, never what
    /// the app holds, and it never echoes a header value back.
    var message: String {
        switch self {
        case .headTooLarge:
            return "The request headers are larger than this session accepts."
        case .malformedRequestLine:
            return "The request line is not HTTP this app understands."
        case .unsupportedMethod:
            return "This transfer surface does not answer that HTTP method."
        case .unexpectedBodyBytes:
            return "The request sent more bytes than it declared."
        case .requestTimedOut:
            return "The request did not complete in time."
        case .malformedHeader:
            return "A request header field is malformed."
        case .conflictingContentLength:
            return "The request declared its length more than once."
        case .invalidContentLength:
            return "The request declared a body length that is not a bounded number."
        case .unsupportedTransferEncoding:
            return "Chunked transfer encoding is not supported. Send Content-Length."
        case .lengthRequired:
            return "A write must declare Content-Length."
        case .payloadTooLarge(let limit):
            return "The upload is larger than this session accepts (\(limit) bytes)."
        case .unauthorized:
            return "The request did not carry this session's token."
        case .notFound:
            return "No route at this address."
        case .filenameRejected(let name):
            return "“\(name)” is not a file name this app accepts for transfer."
        case .emptyPayload:
            return "The request carried no bytes."
        case .notListening:
            return "This transfer session is not listening."
        case .requestBudgetExhausted:
            return "This session has handled as many requests as it will."
        case .storageFailure:
            return "ZynSign could not store the received bytes."
        }
    }
}

/// The bounds one local transfer session runs under.
///
/// The numbers are ZynSign policy, not a published protocol limit. They exist
/// so a phone on a café network cannot be made to buffer, hash, or store more
/// than the feature is allowed to.
struct LocalTransferLimits: Equatable, Sendable {

    /// The largest body one upload may carry: 2 GiB, enough for an `.ipa` and
    /// bounded enough to refuse a file that is not one.
    let maximumUploadBytes: Int

    /// The largest request head this session buffers.
    let maximumHeadBytes: Int

    /// How long a session stays usable after it starts: 30 minutes.
    let sessionLifetime: TimeInterval

    /// The most requests one session will answer: 200.
    let maximumRequests: Int

    /// How long one connection may take, from accepted to answered.
    let requestTimeout: TimeInterval

    /// The only bounds this build ships with.
    static let standard = LocalTransferLimits(
        maximumUploadBytes: 2 * 1_024 * 1_024 * 1_024,
        maximumHeadBytes: 16 * 1_024,
        sessionLifetime: 30 * 60,
        maximumRequests: 200,
        requestTimeout: 60
    )
}

/// The unpredictable value that makes a session usable only by the person who
/// started it.
///
/// The token is 32 random bytes rendered as 64 lowercase hexadecimal
/// characters. Length is fixed, so length is public; the comparison is
/// constant-time over the bytes so a wrong token cannot be guessed by timing.
struct LocalTransferToken: Equatable, Hashable, Sendable {

    /// The number of random bytes a token is made of.
    static let byteCount = 32

    /// The number of hex characters a rendered token has.
    static let textLength = byteCount * 2

    /// The rendered token: lowercase hexadecimal, exactly `textLength` long.
    let value: String

    /// Accepts a token only when it is exactly the expected shape. A value of
    /// the wrong length or alphabet is not a token, so it is never stored or
    /// compared.
    init?(value: String) {
        guard value.utf8.count == LocalTransferToken.textLength else { return nil }
        for byte in value.utf8 {
            switch byte {
            case 0x30...0x39, 0x61...0x66: continue
            default: return nil
            }
        }
        self.value = value
    }

    /// Renders `bytes` as a token, or returns `nil` when the caller supplied a
    /// sequence that is not exactly one token's worth of entropy.
    init?(bytes: Data) {
        guard bytes.count == LocalTransferToken.byteCount else { return nil }
        let digits: [UInt8] = Array("0123456789abcdef".utf8)
        var characters: [UInt8] = []
        characters.reserveCapacity(LocalTransferToken.textLength)
        for byte in bytes {
            characters.append(digits[Int(byte >> 4)])
            characters.append(digits[Int(byte & 0x0F)])
        }
        guard let text = String(bytes: characters, encoding: .utf8) else { return nil }
        self.value = text
    }

    /// Whether `presented` is this token.
    ///
    /// The comparison walks every character regardless of where a mismatch
    /// first appears, so the time it takes does not describe how much of a
    /// guess was right.
    func matches(_ presented: String) -> Bool {
        let expected = Array(value.utf8)
        let candidate = Array(presented.utf8)
        guard candidate.count == expected.count else { return false }
        var difference: UInt8 = 0
        for index in 0..<expected.count {
            difference |= expected[index] ^ candidate[index]
        }
        return difference == 0
    }
}

/// The platform's source of unpredictable bytes.
///
/// Domain names the need; the implementation is platform-bound and lives in
/// `Platform`, and tests substitute it so a session's token is known.
protocol SecureRandomSource: Sendable {
    /// Returns exactly `count` unpredictable bytes.
    func randomBytes(count: Int) throws -> Data
}

/// One listening window: the token, when it opened, and the bounds it runs
/// under.
struct LocalTransferSession: Equatable, Sendable {

    let token: LocalTransferToken
    let startedAt: Date
    let expiresAt: Date
    let limits: LocalTransferLimits

    /// Opens a session with a freshly drawn token.
    ///
    /// - Parameters:
    ///   - limits: The bounds the session runs under.
    ///   - now: The moment the session opens.
    ///   - random: The platform entropy source.
    static func open(
        limits: LocalTransferLimits,
        now: Date,
        random: any SecureRandomSource
    ) throws -> LocalTransferSession {
        let bytes = try random.randomBytes(count: LocalTransferToken.byteCount)
        guard let token = LocalTransferToken(bytes: bytes) else {
            throw LocalTransferRejection.notListening
        }
        return LocalTransferSession(
            token: token,
            startedAt: now,
            expiresAt: now.addingTimeInterval(limits.sessionLifetime),
            limits: limits
        )
    }

    /// Whether the session's window has closed at `date`.
    func isExpired(at date: Date) -> Bool {
        date >= expiresAt
    }
}

/// Where the session is listening, as the app can honestly report it.
struct LocalTransferEndpoint: Equatable, Sendable {

    /// The TCP port the listener bound.
    let port: UInt16

    /// The device's own IPv4 addresses, most useful first. Empty when the
    /// platform could not report one; the app then shows the port and says the
    /// address is unavailable rather than guessing.
    let addresses: [String]

    /// The address a person should type, when the device has one.
    var displayAddress: String? {
        guard let address = addresses.first, !address.isEmpty else { return nil }
        return "http://\(address):\(port)"
    }

    /// The address to type, or an honest statement about what is missing.
    var addressDescription: String {
        displayAddress ?? "Port \(port) — this device reported no network address"
    }
}

/// What a transfer session is doing.
enum LocalTransferState: Equatable, Sendable {

    /// No listener. Nothing can reach the app.
    case stopped

    /// A listener is being opened.
    case starting

    /// A listener is open on `endpoint` until `expiresAt`.
    case listening(LocalTransferEndpoint, expiresAt: Date)

    /// The listener could not be opened, or stopped because of an error. The
    /// message is a sentence a person can act on.
    case failed(String)
}

/// One file the session received.
///
/// The receipt describes what arrived, not what it is: a received `.ipa` is
/// bytes on this device until an import says otherwise. `fileName` is the
/// name the file is stored under inside the session's workspace, never the
/// path the client sent.
struct LocalTransferReceipt: Identifiable, Equatable, Sendable {

    let id: UUID

    /// The stored file name, inside the session workspace.
    let fileName: String

    /// The number of bytes stored.
    let byteCount: Int

    /// When the bytes finished arriving.
    let receivedAt: Date

    /// A ready-to-read size for the list.
    var formattedByteCount: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(byteCount))
    }
}

/// The names a transfer will accept, and the rules that make them safe to
/// write.
///
/// A name arriving over a socket is attacker-controlled text. This policy
/// reduces it to a single safe file name or refuses it: no separators, no
/// traversal, no control characters, no leading dot, no reserved device name,
/// and an extension the app actually knows how to route.
enum LocalTransferFileName {

    /// The largest accepted name, in bytes. The file systems iOS writes to
    /// accept 255 bytes per component.
    static let maximumBytes = 255

    /// Package extensions ZynSign imports.
    static let packageExtensions = ["ipa", "tipa"]

    /// Signing-material extensions ZynSign routes to Certificates & Profiles.
    static let signingMaterialExtensions = SigningMaterialFileFormat.acceptedPathExtensions

    /// Every extension a transfer accepts.
    static var acceptedExtensions: [String] { packageExtensions + signingMaterialExtensions }

    /// The accepted name for `candidate`, or `nil` when it is not one.
    ///
    /// The caller percent-decodes first; this function decides the policy, not
    /// the encoding.
    static func accepted(_ candidate: String) -> String? {
        guard !candidate.isEmpty else { return nil }
        guard candidate.utf8.count <= maximumBytes else { return nil }
        guard !candidate.hasPrefix(".") else { return nil }
        for scalar in candidate.unicodeScalars {
            if scalar == "/" || scalar == "\\" || scalar == ":" { return nil }
            if scalar.value < 0x20 || scalar.value == 0x7F { return nil }
            if scalar.value >= 0x80 { return nil }
        }
        let extensionName = (candidate as NSString).pathExtension.lowercased()
        guard acceptedExtensions.contains(extensionName) else { return nil }
        let stem = (candidate as NSString).deletingPathExtension
        guard !stem.isEmpty else { return nil }
        guard !reservedNames.contains(stem.uppercased()) else { return nil }
        return candidate
    }

    /// Names Windows and some file systems reserve. Refusing them keeps an
    /// uploaded file readable when it is later copied to a Mac.
    private static let reservedNames: Set<String> = [
        "CON", "PRN", "AUX", "NUL",
        "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9",
        "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9",
    ]
}

/// Percent decoding for request targets.
///
/// Returns `nil` for a `%` that does not introduce two hex digits, so a
/// malformed escape is refused instead of being silently kept as text. A
/// decoded NUL is refused too: a C string terminator inside a name is how a
/// path check and a file-system call come to disagree about where a name
/// ends.
enum LocalTransferPercentDecoding {

    /// The decoded form of `text`, or `nil` when it is not valid UTF-8.
    static func decode(_ text: String) -> String? {
        let bytes = Array(text.utf8)
        var output: [UInt8] = []
        output.reserveCapacity(bytes.count)
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 0x25 {  // "%"
                guard index + 2 < bytes.count else { return nil }
                guard let high = hexValue(bytes[index + 1]),
                      let low = hexValue(bytes[index + 2]) else { return nil }
                let decoded = high << 4 | low
                guard decoded != 0 else { return nil }
                output.append(decoded)
                index += 3
                continue
            }
            output.append(byte)
            index += 1
        }
        return String(bytes: output, encoding: .utf8)
    }

    private static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 0x30...0x39: return byte - 0x30
        case 0x41...0x46: return byte - 0x41 + 10
        case 0x61...0x66: return byte - 0x61 + 10
        default: return nil
        }
    }
}
