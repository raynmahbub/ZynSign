import Foundation

/// The HTTP/1.1 subset a local transfer session speaks, as a pure codec.
///
/// A local transfer is one long-running question — "may these bytes come onto
/// this device?" — asked over a socket that anyone on the network can reach.
/// The microphone for that question is a deliberately small HTTP surface:
///
/// - `GET` a session page, so a person on another machine learns the exact
///   command to run rather than guessing at an interface.
/// - `HEAD` the same page, for a client that only wants to know it is there.
/// - `PUT`/`POST` raw bytes to a named destination. There is no multipart
///   parser here on purpose: a multipart body is a second, larger grammar
///   with its own failure modes, and the transfer does not need it.
///
/// Everything in this file is bytes in, a typed value out. No socket, no
/// file, and no clock. That split is what lets a recorded request be replayed
/// in a test, and it keeps the listening code in `Platform` from having to
/// decide what a malformed header means.
enum LocalTransferHTTP {

    /// The largest request head ZynSign will buffer. A head larger than this
    /// is a client that is not speaking this protocol, or one trying to make
    /// the app hold memory it did not ask for.
    static let maximumHeadBytes = 16 * 1_024

    /// The largest request target ZynSign will accept, in bytes.
    static let maximumTargetBytes = 2_048

    /// The line terminator that ends the head section.
    private static let headTerminator: [UInt8] = [0x0D, 0x0A, 0x0D, 0x0A]

    /// The methods the transfer surface answers. Any other method is refused
    /// with `405` rather than treated as a request this code might half
    /// understand.
    enum Method: String, Equatable, Hashable, Sendable {
        case get = "GET"
        case head = "HEAD"
        case put = "PUT"
        case post = "POST"

        /// Whether the method reads session metadata without carrying an upload body.
        var isReadOnly: Bool {
            self == .get || self == .head
        }
    }

    /// A parsed request head plus the number of bytes it consumed.
    struct Request: Equatable, Sendable {

        let method: Method

        /// The request target exactly as it arrived, without validation of
        /// its content beyond the framing rules.
        let target: String

        /// Header fields with lowercased names, values trimmed of the single
        /// optional space after the colon.
        let headers: [String: String]

        /// The declared body length. `0` when no `Content-Length` was sent.
        let contentLength: Int

        /// The header value for `name`, compared case-insensitively.
        func header(_ name: String) -> String? {
            headers[name.lowercased()]
        }

        /// The target without its query string, still percent-encoded.
        var path: String {
            guard let mark = target.firstIndex(of: "?") else { return target }
            return String(target[target.startIndex..<mark])
        }

        /// The target's query string, without the leading `?`.
        var query: String {
            guard let mark = target.firstIndex(of: "?") else { return "" }
            return String(target[target.index(after: mark)...])
        }

        /// Whether this request is a resource read rather than an upload.
        var isReadOnly: Bool {
            method == .get || method == .head
        }
    }

    /// The outcome of feeding bytes to `parseHead`.
    enum HeadParse: Equatable, Sendable {

        /// The head is not complete yet. The caller reads more bytes; it must
        /// keep the total under ``LocalTransferLimits/maximumHeadBytes``.
        case incomplete

        /// A complete head. `consumed` counts the head bytes *and* the
        /// four-byte terminator, so the caller's leftover body bytes start at
        /// that offset.
        case requested(Request, consumed: Int)

        /// The head is complete and not acceptable. The rejection carries the
        /// status the caller answers with.
        case rejected(LocalTransferRejection)
    }

    /// A response to write back, as bytes.
    struct Response: Equatable, Sendable {

        let status: Int
        let reason: String
        let headers: [String]
        let body: Data

        init(status: Int, reason: String, headers: [String] = [], body: Data = Data()) {
            self.status = status
            self.reason = reason
            self.headers = headers
            self.body = body
        }

        /// A text response. The caller supplies a plain-text body; this does
        /// not render HTML, and nothing here escapes markup.
        static func text(_ status: Int, _ reason: String, body: String) -> Response {
            Response(
                status: status,
                reason: reason,
                headers: ["Content-Type: text/plain; charset=utf-8"],
                body: Data(body.utf8)
            )
        }

        /// An HTML response. Callers are responsible for escaping any value
        /// they interpolate into the markup.
        static func html(_ status: Int, _ reason: String, body: String) -> Response {
            Response(
                status: status,
                reason: reason,
                headers: [
                    "Content-Type: text/html; charset=utf-8",
                    "Cache-Control: no-store",
                    "X-Content-Type-Options: nosniff",
                    "Referrer-Policy: no-referrer",
                ],
                body: Data(body.utf8)
            )
        }

        /// A JSON acknowledgement. The body is supplied already encoded and
        /// already bounded by the caller.
        static func json(_ status: Int, _ reason: String, body: Data) -> Response {
            Response(
                status: status,
                reason: reason,
                headers: ["Content-Type: application/json; charset=utf-8"],
                body: body
            )
        }

        /// The rejection's status and reason, with its message as the body.
        static func rejection(_ rejection: LocalTransferRejection) -> Response {
            var headers: [String] = []
            if rejection == .unauthorized {
                headers.append("WWW-Authenticate: Bearer realm=\"ZynSign local transfer\"")
            }
            return Response(
                status: rejection.status,
                reason: rejection.reason,
                headers: headers + [
                    "Content-Type: text/plain; charset=utf-8",
                    "Cache-Control: no-store",
                ],
                body: Data((rejection.message + "\n").utf8)
            )
        }

        /// The response as wire bytes: status line, headers, terminator, body.
        ///
        /// `Content-Length` is always written from the body's own size, and
        /// `Connection: close` is always present because every transfer
        /// connection is answered once and closed.
        var serialized: Data {
            var head = "HTTP/1.1 \(status) \(reason)\r\n"
            for header in headers {
                head += header + "\r\n"
            }
            head += "Content-Length: \(body.count)\r\n"
            head += "Connection: close\r\n\r\n"
            var data = Data(head.utf8)
            data.append(body)
            return data
        }
    }

    /// Parses bytes received so far into a request head.
    ///
    /// - Parameters:
    ///   - data: The bytes received on the connection, from its first byte.
    ///   - limits: The session limits, for the head bound and the body bound.
    /// - Returns: `.incomplete` while the head is still arriving, otherwise a
    ///   request or the reason it was refused.
    static func parseHead(_ data: Data, limits: LocalTransferLimits) -> HeadParse {
        let bytes = [UInt8](data)
        let headLimit = min(limits.maximumHeadBytes, maximumHeadBytes)
        guard bytes.count <= headLimit else { return .rejected(.headTooLarge) }
        guard let terminator = firstTerminator(in: bytes) else { return .incomplete }
        let headBytes = Array(bytes[0..<terminator])
        let consumed = terminator + headTerminator.count
        guard let text = String(bytes: headBytes, encoding: .utf8) else {
            return .rejected(.malformedRequestLine)
        }

        var lines = text.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return .rejected(.malformedRequestLine) }
        let requestLine = lines.removeFirst()
        let head: (method: Method, target: String)
        switch parseRequestLine(requestLine) {
        case .success(let parsed):
            head = parsed
        case .failure(let rejection):
            return .rejected(rejection)
        }

        var headers: [String: String] = [:]
        var contentLength: Int?
        for line in lines {
            guard !line.isEmpty else { continue }
            // Obsolete line folding begins with a space or tab. Continuing a
            // header across lines is a request-smuggling primitive, so it is
            // refused rather than unfolded.
            guard let first = line.utf8.first, first != 0x20, first != 0x09 else {
                return .rejected(.malformedHeader)
            }
            guard let colon = line.firstIndex(of: ":") else { return .rejected(.malformedHeader) }
            let name = String(line[line.startIndex..<colon]).lowercased()
            guard isHeaderName(name) else { return .rejected(.malformedHeader) }
            var value = String(line[line.index(after: colon)...])
            if value.hasPrefix(" ") { value.removeFirst() }
            guard isHeaderValue(value) else { return .rejected(.malformedHeader) }
            if name == "transfer-encoding" {
                // Chunked framing is not implemented; accepting the header
                // without decoding it would misread the body.
                return .rejected(.unsupportedTransferEncoding)
            }
            if name == "content-length" {
                guard headers[name] == nil else { return .rejected(.conflictingContentLength) }
                guard let length = parseContentLength(value) else {
                    return .rejected(.invalidContentLength)
                }
                contentLength = length
                headers[name] = value
                continue
            }
            // Repeated headers other than Content-Length keep their first
            // value; nothing in this protocol depends on a repeated field.
            if headers[name] == nil { headers[name] = value }
        }

        let declared = contentLength ?? 0
        guard declared <= limits.maximumUploadBytes else {
            return .rejected(.payloadTooLarge(limit: limits.maximumUploadBytes))
        }
        if !head.method.isReadOnly && contentLength == nil {
            return .rejected(.lengthRequired)
        }

        let request = Request(
            method: head.method,
            target: head.target,
            headers: headers,
            contentLength: declared
        )
        return .requested(request, consumed: consumed)
    }

    /// Whether `name` is a plausible header field name.
    ///
    /// Restricted to the token characters of RFC 9110 §5.6.2. A name outside
    /// them is not a header this code will interpret.
    private static func isHeaderName(_ name: String) -> Bool {
        guard !name.isEmpty, name.utf8.count <= 64 else { return false }
        for byte in name.utf8 {
            switch byte {
            case 0x61...0x7A, 0x30...0x39: continue  // a-z, 0-9
            case 0x21, 0x23...0x27, 0x2A, 0x2B, 0x2D, 0x2E, 0x5E, 0x5F, 0x60, 0x7C, 0x7E:
                continue
            default:
                return false
            }
        }
        return true
    }

    /// Whether `value` holds no control characters other than a tab.
    private static func isHeaderValue(_ value: String) -> Bool {
        guard value.utf8.count <= 4_096 else { return false }
        for byte in value.utf8 {
            if byte < 0x20 && byte != 0x09 { return false }
            if byte == 0x7F { return false }
        }
        return true
    }

    /// Parses a `Content-Length` value: digits only, bounded so a hostile
    /// length cannot overflow.
    private static func parseContentLength(_ value: String) -> Int? {
        guard !value.isEmpty, value.utf8.count <= 12 else { return nil }
        guard value.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }) else { return nil }
        return Int(value)
    }

    /// Splits `METHOD SP target SP HTTP/x.y`, or names why it cannot be.
    private static func parseRequestLine(
        _ line: String
    ) -> Result<(method: Method, target: String), LocalTransferRejection> {
        let parts = line.split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return .failure(.malformedRequestLine) }
        guard let method = Method(rawValue: String(parts[0])) else {
            // The method is not one this surface answers. Echoing it back
            // would put attacker-chosen text into a response line.
            return .failure(.unsupportedMethod)
        }
        let target = String(parts[1])
        guard target.hasPrefix("/") else { return .failure(.malformedRequestLine) }
        guard target.utf8.count <= maximumTargetBytes else { return .failure(.malformedRequestLine) }
        guard !target.utf8.contains(0) else { return .failure(.malformedRequestLine) }
        let version = String(parts[2])
        guard version == "HTTP/1.1" || version == "HTTP/1.0" else {
            return .failure(.malformedRequestLine)
        }
        return .success((method, target))
    }

    /// The offset of the head terminator, or `nil` while the head is short.
    private static func firstTerminator(in bytes: [UInt8]) -> Int? {
        let terminator = headTerminator
        guard bytes.count >= terminator.count else { return nil }
        let last = bytes.count - terminator.count
        var index = 0
        while index <= last {
            if bytes[index] == terminator[0],
               bytes[index + 1] == terminator[1],
               bytes[index + 2] == terminator[2],
               bytes[index + 3] == terminator[3] {
                return index
            }
            index += 1
        }
        return nil
    }
}
