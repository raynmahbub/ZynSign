import Foundation

/// Transport port for the foreground LAN Web & WebDAV Workspace server.
protocol LANWebWorkspaceTransport: Sendable {
    func start(
        port: UInt16,
        maximumUploadBytes: Int,
        handling: @escaping @Sendable (WebDAVProtocol.HTTPRequestHead, URL?) async -> WebDAVProtocol.HTTPResponseMessage
    ) async throws -> LocalTransferEndpoint
    func stop() async
}

/// Foreground LAN HTTP Browser Upload Dashboard & WebDAV Level 1 Server.
///
/// Separate from `LocalTransferService` so `LocalTransfer`'s one-time token
/// receipt contract stays unchanged while offering an interactive browser upload UI,
/// mountable WebDAV drive (`Finder` / `Explorer` / `Files`), optional Basic Auth,
/// and smart category folders (`Packages/`, `Tweaks/`, `Materials/`, `Files/`).
@MainActor
final class LANWebWorkspaceService: ObservableObject {

    struct UploadedItem: Equatable, Sendable, Identifiable {
        var id: String { relativePath }
        let relativePath: String
        let category: String
        let fileName: String
        let fileURL: URL
        let byteSize: Int64
        let modifiedAt: Date
    }

    @Published private(set) var isRunning = false
    @Published private(set) var endpoint: LocalTransferEndpoint?
    @Published var port: UInt16 = 8088
    @Published var webdavEnabled = true
    @Published var requiresAuthentication = false
    @Published var username = "zynsign"
    @Published var password = ""
    @Published private(set) var items: [UploadedItem] = []
    @Published var statusMessage: String?

    let rootDirectory: URL
    let maximumUploadBytes: Int
    private let makeTransport: @Sendable () -> any LANWebWorkspaceTransport
    private var activeTransport: (any LANWebWorkspaceTransport)?

    static let categories = ["Packages", "Tweaks", "Materials", "Files"]

    nonisolated init(
        rootDirectory: URL,
        maximumUploadBytes: Int = 2 * 1_024 * 1_024 * 1_024,
        makeTransport: @escaping @Sendable () -> any LANWebWorkspaceTransport
    ) {
        self.rootDirectory = rootDirectory
        self.maximumUploadBytes = maximumUploadBytes
        self.makeTransport = makeTransport
        Self.createCategoryDirectories(at: rootDirectory)
    }

    func startServer() async {
        guard !isRunning else { return }
        Self.createCategoryDirectories(at: rootDirectory)
        let transport = makeTransport()
        let root = rootDirectory
        let davOn = webdavEnabled
        let authOn = requiresAuthentication
        let expectedUser = username
        let expectedPass = password

        do {
            let bound = try await transport.start(
                port: port,
                maximumUploadBytes: maximumUploadBytes
            ) { [weak self] head, bodyFileURL in
                let response = Self.handleRequest(
                    head: head,
                    bodyFileURL: bodyFileURL,
                    rootDirectory: root,
                    webdavEnabled: davOn,
                    requiresAuth: authOn,
                    expectedUser: expectedUser,
                    expectedPass: expectedPass
                )
                Task { @MainActor in self?.refreshItems() }
                return response
            }
            activeTransport = transport
            endpoint = bound
            isRunning = true
            statusMessage = nil
            refreshItems()
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func stopServer() async {
        if let transport = activeTransport {
            await transport.stop()
        }
        activeTransport = nil
        endpoint = nil
        isRunning = false
    }

    func refreshItems() {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: rootDirectory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            items = []
            return
        }
        let basePath = rootDirectory.standardizedFileURL.path
        var loaded: [UploadedItem] = []
        for case let url as URL in enumerator {
            guard let vals = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]),
                  vals.isRegularFile == true else { continue }
            let std = url.standardizedFileURL.path
            guard std.hasPrefix(basePath + "/") else { continue }
            let rel = String(std.dropFirst(basePath.count + 1))
            let category = rel.split(separator: "/").first.map(String.init) ?? "Files"
            loaded.append(UploadedItem(
                relativePath: rel,
                category: category,
                fileName: url.lastPathComponent,
                fileURL: url,
                byteSize: Int64(vals.fileSize ?? 0),
                modifiedAt: vals.contentModificationDate ?? Date()
            ))
        }
        items = loaded.sorted { $0.modifiedAt > $1.modifiedAt }
    }

    func deleteItem(_ item: UploadedItem) {
        try? FileManager.default.removeItem(at: item.fileURL)
        refreshItems()
    }

    nonisolated private static func createCategoryDirectories(at rootDirectory: URL) {
        let fm = FileManager.default
        try? fm.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        for category in Self.categories {
            try? fm.createDirectory(
                at: rootDirectory.appendingPathComponent(category, isDirectory: true),
                withIntermediateDirectories: true
            )
        }
    }

    // MARK: - Stateless Request Dispatcher

    nonisolated static func handleRequest(
        head: WebDAVProtocol.HTTPRequestHead,
        bodyFileURL: URL?,
        rootDirectory: URL,
        webdavEnabled: Bool,
        requiresAuth: Bool,
        expectedUser: String,
        expectedPass: String
    ) -> WebDAVProtocol.HTTPResponseMessage {
        if requiresAuth, !expectedPass.isEmpty,
           !WebDAVProtocol.verifyBasicAuthorization(
            headerValue: head.headers["authorization"],
            expectedUsername: expectedUser,
            expectedPassword: expectedPass
           ) {
            return unauthorizedResponse()
        }

        guard let parts = WebDAVProtocol.sanitizePath(head.rawTarget) else {
            return plainResponse(status: 400, reason: "Bad Request", text: "Invalid path.")
        }

        let targetURL = parts.reduce(rootDirectory) { $0.appendingPathComponent($1) }
        switch head.method {
        case "OPTIONS":
            var headers = [("Allow", WebDAVProtocol.allowedMethods)]
            if webdavEnabled {
                headers.append(("DAV", "1"))
                headers.append(("MS-Author-Via", "DAV"))
            }
            return WebDAVProtocol.HTTPResponseMessage(status: 200, reason: "OK", headers: headers, body: Data())

        case "PROPFIND":
            return handlePropfind(
                parts: parts,
                targetURL: targetURL,
                depth: head.headers["depth"] ?? "1",
                webdavEnabled: webdavEnabled
            )

        case "GET", "HEAD":
            return handleRead(parts: parts, targetURL: targetURL, rootDirectory: rootDirectory, webdavEnabled: webdavEnabled, headOnly: head.method == "HEAD")

        case "PUT":
            return handlePut(targetURL: targetURL, bodyFileURL: bodyFileURL)

        case "DELETE":
            guard !parts.isEmpty, FileManager.default.fileExists(atPath: targetURL.path) else {
                return plainResponse(status: 404, reason: "Not Found", text: "Not found.")
            }
            try? FileManager.default.removeItem(at: targetURL)
            return plainResponse(status: 204, reason: "No Content", text: "")

        case "MKCOL":
            guard webdavEnabled, !parts.isEmpty else {
                return plainResponse(status: 405, reason: "Method Not Allowed", text: "Not allowed.")
            }
            do {
                try FileManager.default.createDirectory(at: targetURL, withIntermediateDirectories: false)
                return plainResponse(status: 201, reason: "Created", text: "Created.")
            } catch {
                return plainResponse(status: 409, reason: "Conflict", text: "Could not create directory.")
            }

        case "MOVE", "COPY":
            return handleMoveOrCopy(
                method: head.method,
                targetURL: targetURL,
                destinationHeader: head.headers["destination"],
                rootDirectory: rootDirectory,
                webdavEnabled: webdavEnabled
            )

        default:
            return plainResponse(status: 405, reason: "Method Not Allowed", text: "Unsupported method.")
        }
    }

    nonisolated private static func unauthorizedResponse() -> WebDAVProtocol.HTTPResponseMessage {
        WebDAVProtocol.HTTPResponseMessage(
            status: 401,
            reason: "Unauthorized",
            headers: [
                ("WWW-Authenticate", "Basic realm=\"ZynSign Web Workspace\""),
                ("Content-Type", "text/plain; charset=utf-8")
            ],
            body: Data("Authentication required.".utf8)
        )
    }

    nonisolated private static func handlePropfind(
        parts: [String],
        targetURL: URL,
        depth: String,
        webdavEnabled: Bool
    ) -> WebDAVProtocol.HTTPResponseMessage {
        guard webdavEnabled else {
            return plainResponse(status: 405, reason: "Method Not Allowed", text: "WebDAV is disabled.")
        }
        guard let resources = collectMetadata(at: targetURL, hrefParts: parts, depth: depth) else {
            return plainResponse(status: 404, reason: "Not Found", text: "Not found.")
        }
        return WebDAVProtocol.HTTPResponseMessage(
            status: 207,
            reason: "Multi-Status",
            headers: [("Content-Type", "application/xml; charset=utf-8")],
            body: WebDAVProtocol.renderMultiStatusXML(resources: resources)
        )
    }

    nonisolated private static func handleMoveOrCopy(
        method: String,
        targetURL: URL,
        destinationHeader: String?,
        rootDirectory: URL,
        webdavEnabled: Bool
    ) -> WebDAVProtocol.HTTPResponseMessage {
        guard webdavEnabled,
              let destHeader = destinationHeader,
              let destParts = WebDAVProtocol.sanitizePath(destHeader),
              !destParts.isEmpty else {
            return plainResponse(status: 400, reason: "Bad Request", text: "Invalid Destination header.")
        }
        let destURL = destParts.reduce(rootDirectory) { $0.appendingPathComponent($1) }
        let fm = FileManager.default
        try? fm.removeItem(at: destURL)
        do {
            try fm.createDirectory(at: destURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if method == "MOVE" {
                try fm.moveItem(at: targetURL, to: destURL)
            } else {
                try fm.copyItem(at: targetURL, to: destURL)
            }
            return plainResponse(status: 201, reason: "Created", text: "")
        } catch {
            return plainResponse(status: 409, reason: "Conflict", text: "Operation failed.")
        }
    }

    nonisolated private static func handleRead(
        parts: [String],
        targetURL: URL,
        rootDirectory: URL,
        webdavEnabled: Bool,
        headOnly: Bool
    ) -> WebDAVProtocol.HTTPResponseMessage {
        let fm = FileManager.default
        if parts.isEmpty {
            let tree = collectAllDashboardMetadata(in: rootDirectory)
            let html = WebDAVProtocol.renderDashboardHTML(items: tree, webdavEnabled: webdavEnabled)
            return WebDAVProtocol.HTTPResponseMessage(
                status: 200,
                reason: "OK",
                headers: [("Content-Type", "text/html; charset=utf-8"), ("Content-Length", "\(html.count)")],
                body: headOnly ? Data() : html
            )
        }
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: targetURL.path, isDirectory: &isDir), !isDir.boolValue,
              let data = try? Data(contentsOf: targetURL, options: .mappedIfSafe) else {
            return plainResponse(status: 404, reason: "Not Found", text: "File not found.")
        }
        return WebDAVProtocol.HTTPResponseMessage(
            status: 200,
            reason: "OK",
            headers: [
                ("Content-Type", "application/octet-stream"),
                ("Content-Length", "\(data.count)")
            ],
            body: headOnly ? Data() : data
        )
    }

    nonisolated private static func handlePut(
        targetURL: URL,
        bodyFileURL: URL?
    ) -> WebDAVProtocol.HTTPResponseMessage {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: targetURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let existed = fm.fileExists(atPath: targetURL.path)
            if existed { try fm.removeItem(at: targetURL) }
            if let bodyFileURL, fm.fileExists(atPath: bodyFileURL.path) {
                try fm.moveItem(at: bodyFileURL, to: targetURL)
            } else {
                try Data().write(to: targetURL, options: .atomic)
            }
            return plainResponse(status: existed ? 204 : 201, reason: existed ? "No Content" : "Created", text: "")
        } catch {
            return plainResponse(status: 507, reason: "Insufficient Storage", text: "Write failed.")
        }
    }

    nonisolated private static func collectMetadata(
        at url: URL,
        hrefParts: [String],
        depth: String
    ) -> [WebDAVProtocol.ResourceMetadata]? {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return nil }
        let selfMeta = makeResourceMetadata(url: url, hrefParts: hrefParts, isDir: isDir.boolValue)
        var list = [selfMeta]
        if isDir.boolValue, depth != "0",
           let children = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey], options: [.skipsHiddenFiles]) {
            for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                var childDir: ObjCBool = false
                _ = fm.fileExists(atPath: child.path, isDirectory: &childDir)
                list.append(makeResourceMetadata(url: child, hrefParts: hrefParts + [child.lastPathComponent], isDir: childDir.boolValue))
            }
        }
        return list
    }

    nonisolated private static func collectAllDashboardMetadata(in root: URL) -> [WebDAVProtocol.ResourceMetadata] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        let base = root.standardizedFileURL.path
        var out: [WebDAVProtocol.ResourceMetadata] = []
        for case let fileURL as URL in enumerator {
            guard let vals = try? fileURL.resourceValues(forKeys: [.isRegularFileKey]),
                  vals.isRegularFile == true else { continue }
            let std = fileURL.standardizedFileURL.path
            guard std.hasPrefix(base + "/") else { continue }
            let relParts = String(std.dropFirst(base.count + 1)).split(separator: "/").map(String.init)
            out.append(makeResourceMetadata(url: fileURL, hrefParts: relParts, isDir: false))
        }
        return out
    }

    nonisolated private static func makeResourceMetadata(
        url: URL,
        hrefParts: [String],
        isDir: Bool
    ) -> WebDAVProtocol.ResourceMetadata {
        let vals = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let encoded = hrefParts.map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? $0 }
        let href = "/" + encoded.joined(separator: "/") + (isDir && !hrefParts.isEmpty ? "/" : "")
        return WebDAVProtocol.ResourceMetadata(
            hrefPath: href,
            displayName: hrefParts.last ?? "ZynSign",
            isDirectory: isDir,
            byteSize: Int64(vals?.fileSize ?? 0),
            modifiedAt: vals?.contentModificationDate ?? Date()
        )
    }

    nonisolated private static func plainResponse(
        status: Int,
        reason: String,
        text: String
    ) -> WebDAVProtocol.HTTPResponseMessage {
        WebDAVProtocol.HTTPResponseMessage(
            status: status,
            reason: reason,
            headers: [("Content-Type", "text/plain; charset=utf-8")],
            body: Data(text.utf8)
        )
    }
}
