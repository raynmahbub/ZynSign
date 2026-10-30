import Foundation

/// Pure-Swift HTTP/1.1 + WebDAV Level 1 (`OPTIONS`, `PROPFIND`, `GET`, `HEAD`,
/// `PUT`, `DELETE`, `MKCOL`, `MOVE`, `COPY`) protocol codec, constant-time
/// HTTP Basic Auth evaluator, and browser drag-and-drop dashboard renderer.
enum WebDAVProtocol {

    struct HTTPRequestHead: Equatable, Sendable {
        let method: String
        let rawTarget: String
        let headers: [String: String]
        let contentLength: Int
    }

    struct HTTPResponseMessage: Equatable, Sendable {
        let status: Int
        let reason: String
        let headers: [(String, String)]
        let body: Data

        static func == (lhs: HTTPResponseMessage, rhs: HTTPResponseMessage) -> Bool {
            guard lhs.status == rhs.status,
                  lhs.reason == rhs.reason,
                  lhs.body == rhs.body,
                  lhs.headers.count == rhs.headers.count else {
                return false
            }
            for (left, right) in zip(lhs.headers, rhs.headers) {
                if left.0 != right.0 || left.1 != right.1 { return false }
            }
            return true
        }

        func serialized() -> Data {
            var lines = ["HTTP/1.1 \(status) \(reason)"]
            var hasLength = false
            for (name, value) in headers {
                if name.lowercased() == "content-length" { hasLength = true }
                lines.append("\(name): \(value)")
            }
            if !hasLength {
                lines.append("Content-Length: \(body.count)")
            }
            lines.append("Connection: close")
            lines.append("")
            lines.append("")
            var out = Data(lines.joined(separator: "\r\n").utf8)
            out.append(body)
            return out
        }
    }

    struct ResourceMetadata: Equatable, Sendable {
        let hrefPath: String
        let displayName: String
        let isDirectory: Bool
        let byteSize: Int64
        let modifiedAt: Date
    }

    static let allowedMethods = "OPTIONS, GET, HEAD, PUT, DELETE, MKCOL, MOVE, COPY, PROPFIND"

    /// Parses an HTTP/1.1 request head (`\r\n\r\n` excluded or included).
    static func parseHead(_ data: Data) -> HTTPRequestHead? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let rawLines = text.components(separatedBy: "\r\n")
        guard let firstLine = rawLines.first else { return nil }
        let parts = firstLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count == 3, parts[2].hasPrefix("HTTP/1.") else { return nil }

        var headers: [String: String] = [:]
        for line in rawLines.dropFirst() {
            if line.isEmpty { break }
            guard let colon = line.firstIndex(of: ":") else { return nil }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let val = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, headers[key] == nil else { return nil }
            headers[key] = val
        }
        if headers["transfer-encoding"] != nil { return nil }
        if parts[0].uppercased() == "PUT", headers["content-length"] == nil { return nil }
        let length: Int
        if let rawLen = headers["content-length"] {
            guard let parsed = Int(rawLen), parsed >= 0 else { return nil }
            length = parsed
        } else {
            length = 0
        }
        return HTTPRequestHead(
            method: parts[0].uppercased(),
            rawTarget: parts[1],
            headers: headers,
            contentLength: length
        )
    }

    /// Evaluates HTTP Basic Auth in constant time across the decoded credential bytes.
    static func verifyBasicAuthorization(
        headerValue: String?,
        expectedUsername: String,
        expectedPassword: String
    ) -> Bool {
        guard !expectedUsername.isEmpty, !expectedPassword.isEmpty, !expectedUsername.contains(":") else { return false }
        guard let headerValue,
              headerValue.lowercased().hasPrefix("basic ") else { return false }
        let b64 = String(headerValue.dropFirst(6)).trimmingCharacters(in: .whitespaces)
        guard let decoded = Data(base64Encoded: b64) else { return false }
        let expected = Data("\(expectedUsername):\(expectedPassword)".utf8)
        return constantTimeEquals(decoded, expected)
    }

    /// Whether a request names a different origin than the one it was sent to.
    ///
    /// A browser attaches `Origin` to state-changing requests and `Sec-Fetch-Site`
    /// to most of them; both are set by the browser and cannot be forged from a
    /// page. Comparing them against `Host` is what makes a cross-site form or
    /// script unable to use this workspace's cached Basic credential to upload or
    /// delete a file. A non-browser client sends neither header, so it is not
    /// judged by them.
    static func hasForeignOrigin(headers: [String: String]) -> Bool {
        if let fetchSite = headers["sec-fetch-site"]?.lowercased(),
           fetchSite == "cross-site" || fetchSite == "same-site" {
            return true
        }
        guard let origin = headers["origin"], !origin.isEmpty else { return false }
        let originAuthority = authority(of: origin)
        guard !originAuthority.isEmpty else { return true }
        guard let host = headers["host"]?.lowercased(), !host.isEmpty else {
            return true
        }
        return originAuthority != host
    }

    /// Reduces an `Origin` value to its lowercased `host[:port]`.
    private static func authority(of origin: String) -> String {
        var value = origin
        if let schemeEnd = value.range(of: "://") {
            value = String(value[schemeEnd.upperBound...])
        }
        if let slash = value.firstIndex(of: "/") {
            value = String(value[..<slash])
        }
        return value.lowercased()
    }

    static func constantTimeEquals(_ lhs: Data, _ rhs: Data) -> Bool {
        let maxLen = max(lhs.count, rhs.count)
        var diff: UInt8 = lhs.count == rhs.count ? 0 : 1
        for idx in 0..<maxLen {
            let a = idx < lhs.count ? lhs[idx] : 0
            let b = idx < rhs.count ? rhs[idx] : 0
            diff |= (a ^ b)
        }
        return diff == 0
    }

    // A request target becomes a location through `WebDAVPathPolicy`, never here:
    // the codec stays a codec, and the rules that decide what a target may name
    // live in one testable place.

    /// Builds a WebDAV `207 Multi-Status` XML response body for `PROPFIND`.
    static func renderMultiStatusXML(resources: [ResourceMetadata]) -> Data {
        let rfc1123 = DateFormatter()
        rfc1123.locale = Locale(identifier: "en_US_POSIX")
        rfc1123.timeZone = TimeZone(secondsFromGMT: 0)
        rfc1123.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"

        var xml = "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n"
        xml += "<D:multistatus xmlns:D=\"DAV:\">\n"
        for item in resources {
            let escapedHref = xmlEscape(item.hrefPath)
            let escapedName = xmlEscape(item.displayName)
            let modified = rfc1123.string(from: item.modifiedAt)
            xml += "  <D:response>\n"
            xml += "    <D:href>\(escapedHref)</D:href>\n"
            xml += "    <D:propstat>\n"
            xml += "      <D:prop>\n"
            xml += "        <D:displayname>\(escapedName)</D:displayname>\n"
            xml += "        <D:getlastmodified>\(modified)</D:getlastmodified>\n"
            if item.isDirectory {
                xml += "        <D:resourcetype><D:collection/></D:resourcetype>\n"
            } else {
                xml += "        <D:resourcetype/>\n"
                xml += "        <D:getcontentlength>\(item.byteSize)</D:getcontentlength>\n"
            }
            xml += "      </D:prop>\n"
            xml += "      <D:status>HTTP/1.1 200 OK</D:status>\n"
            xml += "    </D:propstat>\n"
            xml += "  </D:response>\n"
        }
        xml += "</D:multistatus>\n"
        return Data(xml.utf8)
    }

    /// Renders the self-contained HTML5 Drag-and-Drop Web Workspace Dashboard.
    static func renderDashboardHTML(items: [ResourceMetadata], webdavEnabled: Bool) -> Data {
        let rows = items.filter { $0.hrefPath != "/" }.map { item -> String in
            let safeHref = xmlEscape(item.hrefPath)
            let safeLabel = xmlEscape(item.hrefPath.dropFirst().description)
            let badge = item.isDirectory ? "Folder" : "\(item.byteSize / 1024) KB"
            let action = item.isDirectory
                ? ""
                : "<a href=\"\(safeHref)\" download style=\"margin-right:10px;color:#0a84ff;text-decoration:none;\">Download</a>"
            return """
            <div style="display:flex;justify-content:space-between;align-items:center;padding:10px 12px;border-bottom:1px solid #2c2c2e;">
              <div><strong>\(safeLabel)</strong> <span style="opacity:.65;font-size:12px;">(\(badge))</span></div>
              <div>\(action)<button data-href="\(safeHref)" onclick="delItem(this.dataset.href)" style="background:#ff453a;color:#fff;border:none;border-radius:6px;padding:5px 10px;cursor:pointer;">Delete</button></div>
            </div>
            """
        }.joined(separator: "\n")

        let davNote = webdavEnabled
            ? "WebDAV Level 1 is active on this URL — mount directly in macOS Finder (Cmd+K), Windows Explorer, or iOS Files."
            : "Browser upload mode active (enable WebDAV in ZynSign to mount as a network drive)."

        let html = """
        <!doctype html>
        <html lang="en">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width,initial-scale=1">
          <title>ZynSign LAN Web Workspace</title>
        </head>
        <body style="font-family:-apple-system,BlinkMacSystemFont,sans-serif;background:#111216;color:#f5f5f7;max-width:780px;margin:28px auto;padding:0 16px;">
          <h2 style="margin-bottom:4px;">ZynSign LAN Web Workspace</h2>
          <p style="opacity:.75;font-size:14px;margin-top:0;">\(xmlEscape(davNote))</p>
          <div style="background:#1c1c1e;border-radius:12px;padding:16px;margin-bottom:20px;">
            <label style="font-size:14px;">Target Category:
              <select id="cat" style="margin-left:8px;padding:6px 10px;border-radius:8px;background:#2c2c2e;color:#fff;border:1px solid #3a3a3c;">
                <option value="Packages">Packages (.ipa / .tipa)</option>
                <option value="Tweaks">Tweaks (.dylib / .deb / .framework)</option>
                <option value="Materials">Signing Materials (.p12 / .mobileprovision)</option>
                <option value="Files">General Files</option>
              </select>
            </label>
            <div id="drop" style="margin-top:14px;border:2px dashed #0a84ff;border-radius:10px;padding:28px;text-align:center;">
              <p style="margin:0 0 10px 0;">Drag &amp; drop files here or choose from your computer</p>
              <input id="picker" type="file" multiple style="color:#fff;">
            </div>
            <p id="status" style="font-size:13px;opacity:.85;margin:10px 0 0 0;"></p>
          </div>
          <div style="background:#1c1c1e;border-radius:12px;overflow:hidden;">
            <div style="padding:12px 14px;background:#252529;font-weight:600;">Workspace Contents</div>
            \(rows.isEmpty ? "<div style=\"padding:18px;opacity:.65;\">No uploaded files yet.</div>" : rows)
          </div>
          <script>
          const statusEl = document.getElementById('status');
          async function sendFiles(list) {
            const cat = document.getElementById('cat').value;
            for (const f of list) {
              statusEl.textContent = 'Uploading ' + f.name + '…';
              const target = '/' + encodeURIComponent(cat) + '/' + encodeURIComponent(f.name);
              const res = await fetch(target, { method: 'PUT', body: f });
              if (!res.ok) { statusEl.textContent = 'Upload failed (' + res.status + '): ' + f.name; return; }
            }
            statusEl.textContent = 'Upload complete. Reloading…';
            location.reload();
          }
          document.getElementById('picker').addEventListener('change', e => sendFiles(e.target.files));
          const drop = document.getElementById('drop');
          drop.addEventListener('dragover', e => { e.preventDefault(); });
          drop.addEventListener('drop', e => { e.preventDefault(); sendFiles(e.dataTransfer.files); });
          async function delItem(href) {
            await fetch(href, { method: 'DELETE' });
            location.reload();
          }
          </script>
        </body>
        </html>
        """
        return Data(html.utf8)
    }

    private static func xmlEscape(_ raw: String) -> String {
        raw.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
