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
/// mountable WebDAV drive (`Finder` / `Explorer` / `Files`),
/// mandatory HTTP Basic authentication, and smart category folders
/// (`Packages/`, `Tweaks/`, `Materials/`, `Files/`).
///
/// The transport is plaintext HTTP, which is a property of the feature and not
/// something this type can fix: a Basic credential on this link is readable by
/// anything on the path. What the type does control, it controls here — the
/// server refuses to start without a credential of its own minimum length, every
/// request is authenticated before anything else is decided, every target is
/// parsed by `WebDAVPathPolicy` and resolved inside a symlink-resolved root, and
/// no method replaces, moves or deletes the workspace root or its category
/// folders.
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

    /// The shortest credential this server will start with. A four-character
    /// password on a plaintext link is a formality, not a credential, so it is
    /// refused with a message that says what to do instead.
    static let minimumCredentialLength = 12

    /// The largest file a `GET` is answered with in one response. Bytes are
    /// carried in a single `Data`, so an unbounded read is an out-of-memory
    /// request from the network; past this bound the server refuses by name.
    static let defaultMaximumDownloadBytes = 512 * 1_024 * 1_024

    static let categories = ["Packages", "Tweaks", "Materials", "Files"]

    /// The category folders the workspace creates and the dashboard links to.
    /// A client can add files to them; it cannot replace, move or delete them.
    static let protectedTopLevelDirectories: Set<String> = Set(categories.map { $0.lowercased() })

    @Published private(set) var isRunning = false
    @Published private(set) var endpoint: LocalTransferEndpoint?
    @Published var port: UInt16 = 8088
    @Published var webdavEnabled = true
    @Published var username = "zynsign"
    @Published var password = ""
    @Published private(set) var items: [UploadedItem] = []
    @Published var statusMessage: String?

    let rootDirectory: URL
    let maximumUploadBytes: Int
    let maximumDownloadBytes: Int
    private let makeTransport: @Sendable () -> any LANWebWorkspaceTransport
    private var activeTransport: (any LANWebWorkspaceTransport)?

    nonisolated init(
        rootDirectory: URL,
        maximumUploadBytes: Int = 2 * 1_024 * 1_024 * 1_024,
        maximumDownloadBytes: Int = LANWebWorkspaceService.defaultMaximumDownloadBytes,
        makeTransport: @escaping @Sendable () -> any LANWebWorkspaceTransport
    ) {
        self.rootDirectory = rootDirectory
        self.maximumUploadBytes = maximumUploadBytes
        self.maximumDownloadBytes = maximumDownloadBytes
        self.makeTransport = makeTransport
        Self.createCategoryDirectories(at: rootDirectory)
    }

    /// Why the configured credential cannot be used, or `nil` when it can.
    ///
    /// This is a precondition of listening rather than a warning: the server is
    /// reachable from the whole local network and speaks plaintext HTTP, so it is
    /// never started unauthenticated.
    nonisolated static func credentialRefusal(username: String, password: String) -> String? {
        if username.trimmingCharacters(in: .whitespaces).isEmpty {
            return "Set a username before starting the LAN server."
        }
        if username.contains(":") {
            return "A username cannot contain a colon; HTTP Basic authentication uses one as its separator."
        }
        if password.count < minimumCredentialLength {
            return "Use a password of at least \(minimumCredentialLength) characters. This link is plaintext HTTP, so the credential is the only thing standing between the network and your workspace."
        }
        return nil
    }

    func startServer() async {
        guard !isRunning else { return }
        if let refusal = Self.credentialRefusal(username: username, password: password) {
            statusMessage = refusal
            return
        }
        Self.createCategoryDirectories(at: rootDirectory)
        let transport = makeTransport()
        let root = rootDirectory
        let davOn = webdavEnabled
        let expectedUser = username
        let expectedPass = password
        let downloadLimit = maximumDownloadBytes
        let protectedRoots = Self.protectedTopLevelDirectories

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
                    expectedUser: expectedUser,
                    expectedPass: expectedPass,
                    maximumDownloadBytes: downloadLimit,
                    protectedTopLevelDirectories: protectedRoots
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
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            items = []
            return
        }
        let basePath = rootDirectory.standardizedFileURL.path
        var loaded: [UploadedItem] = []
        for case let url as URL in enumerator {
            guard let vals = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]),
                  vals.isRegularFile == true,
                  vals.isSymbolicLink != true else { continue }
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
        expectedUser: String,
        expectedPass: String,
        maximumDownloadBytes: Int,
        protectedTopLevelDirectories: Set<String>
    ) -> WebDAVProtocol.HTTPResponseMessage {
        // Authentication is decided before anything else, including whether the
        // method or the target exists: an unauthenticated request learns nothing
        // about the workspace, not even which paths are real.
        guard WebDAVProtocol.verifyBasicAuthorization(
            headerValue: head.headers["authorization"],
            expectedUsername: expectedUser,
            expectedPassword: expectedPass
        ) else {
            return unauthorizedResponse()
        }

        // A browser attaches its credential to a request another page caused; the
        // origin headers are the only part of that request a page cannot set, so
        // a foreign one is refused before the method or target is considered.
        if WebDAVProtocol.hasForeignOrigin(headers: head.headers) {
            return WebDAVRequestRejection.foreignOrigin.response
        }

        let parts: [String]
        switch WebDAVPathPolicy.components(fromTarget: head.rawTarget) {
        case .success(let parsed):
            parts = parsed
        case .failure(let rejection):
            return rejection.response
        }

        let resolvedRoot = WebDAVPathPolicy.resolvedRoot(rootDirectory)
        guard hasNoSymbolicLink(in: parts, under: resolvedRoot) else {
            return WebDAVRequestRejection.outsideWorkspace.response
        }
        let targetURL = WebDAVPathPolicy.location(for: parts, underResolvedRoot: resolvedRoot)
        guard WebDAVPathPolicy.isContained(targetURL, underResolvedRoot: resolvedRoot) else {
            return WebDAVRequestRejection.outsideWorkspace.response
        }

        return respond(
            head: head,
            parts: parts,
            targetURL: targetURL,
            rootDirectory: resolvedRoot,
            bodyFileURL: bodyFileURL,
            webdavEnabled: webdavEnabled,
            maximumDownloadBytes: maximumDownloadBytes,
            protectedTopLevelDirectories: protectedTopLevelDirectories
        )
    }

    /// Answers the reading methods, and hands the rest to the mutation table.
    nonisolated private static func respond(
        head: WebDAVProtocol.HTTPRequestHead,
        parts: [String],
        targetURL: URL,
        rootDirectory: URL,
        bodyFileURL: URL?,
        webdavEnabled: Bool,
        maximumDownloadBytes: Int,
        protectedTopLevelDirectories: Set<String>
    ) -> WebDAVProtocol.HTTPResponseMessage {
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
            return handleRead(
                parts: parts,
                targetURL: targetURL,
                rootDirectory: rootDirectory,
                webdavEnabled: webdavEnabled,
                headOnly: head.method == "HEAD",
                maximumDownloadBytes: maximumDownloadBytes
            )

        default:
            return respondToMutation(
                head: head,
                parts: parts,
                targetURL: targetURL,
                rootDirectory: rootDirectory,
                bodyFileURL: bodyFileURL,
                webdavEnabled: webdavEnabled,
                protectedTopLevelDirectories: protectedTopLevelDirectories
            )
        }
    }

    /// Answers the writing methods. All four are refused when WebDAV is off and
    /// when the target is the workspace root or a category folder; `MOVE` and
    /// `COPY` then check their own destination as well.
    nonisolated private static func respondToMutation(
        head: WebDAVProtocol.HTTPRequestHead,
        parts: [String],
        targetURL: URL,
        rootDirectory: URL,
        bodyFileURL: URL?,
        webdavEnabled: Bool,
        protectedTopLevelDirectories: Set<String>
    ) -> WebDAVProtocol.HTTPResponseMessage {
        // `PUT` is answered with the drive off as well: uploading through the
        // browser page is what the listener is for in that mode. The methods that
        // make it a file manager — delete, make, move, copy — are the drive's,
        // and the dashboard hides its delete control to match.
        //
        // Availability is answered before policy: a method this listener is not
        // offering at all is `405`, and only a method it does offer is judged by
        // what it names (`403` for the workspace root or a category folder).
        let driveOnlyMethods: Set<String> = ["DELETE", "MKCOL", "MOVE", "COPY"]
        if driveOnlyMethods.contains(head.method), !webdavEnabled {
            return plainResponse(status: 405, reason: "Method Not Allowed", text: "WebDAV is disabled.")
        }
        if let refusal = WebDAVPathPolicy.refusalForMutation(of: parts, protectedRoots: protectedTopLevelDirectories) {
            return refusal.response
        }
        let fm = FileManager.default
        switch head.method {
        case "PUT":
            return handlePut(
                targetURL: targetURL,
                bodyFileURL: bodyFileURL,
                contentLength: head.contentLength,
                resolvedRoot: rootDirectory
            )

        case "DELETE":
            guard fm.fileExists(atPath: targetURL.path) else {
                return plainResponse(status: 404, reason: "Not Found", text: "Not found.")
            }
            do {
                try fm.removeItem(at: targetURL)
                return plainResponse(status: 204, reason: "No Content", text: "")
            } catch {
                return plainResponse(status: 409, reason: "Conflict", text: "Could not delete item.")
            }

        case "MKCOL":
            do {
                try fm.createDirectory(at: targetURL, withIntermediateDirectories: false)
                return plainResponse(status: 201, reason: "Created", text: "Created.")
            } catch {
                return plainResponse(status: 409, reason: "Conflict", text: "Could not create directory.")
            }

        case "MOVE", "COPY":
            return handleMoveOrCopy(
                method: head.method,
                targetURL: targetURL,
                destinationHeader: head.headers["destination"],
                resolvedRoot: rootDirectory,
                webdavEnabled: webdavEnabled,
                protectedTopLevelDirectories: protectedTopLevelDirectories
            )

        default:
            return plainResponse(status: 405, reason: "Method Not Allowed", text: "Unsupported method.")
        }
    }

    /// Reject a request whose path crosses an existing symbolic link.
    ///
    /// This is a pre-flight check, not a race-free substitute for
    /// descriptor-relative file access: it narrows the window in which a link
    /// could be introduced and, together with the resolved-containment test the
    /// caller performs afterwards, means a request either stays in the workspace
    /// or is refused. It is stated as a limit in the architecture record rather
    /// than presented as isolation.
    nonisolated private static func hasNoSymbolicLink(in parts: [String], under root: URL) -> Bool {
        var current = root
        for part in parts {
            current.appendPathComponent(part)
            if let attrs = try? FileManager.default.attributesOfItem(atPath: current.path),
               attrs[.type] as? FileAttributeType == .typeSymbolicLink {
                return false
            }
        }
        return true
    }

    nonisolated private static func unauthorizedResponse() -> WebDAVProtocol.HTTPResponseMessage {
        WebDAVProtocol.HTTPResponseMessage(
            status: 401,
            reason: "Unauthorized",
            headers: [
                ("WWW-Authenticate", "Basic realm=\"ZynSign Web Workspace\""),
                ("Content-Type", "text/plain; charset=utf-8")
            ],
            body: Data("Authentication required.\n".utf8)
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
        // `infinity` is answered as one level rather than refused: the depth the
        // workspace serves is bounded, and a client that asks for more gets the
        // collection it asked about plus its children, not a walk of the tree.
        let boundedDepth = depth == "0" ? "0" : "1"
        guard let resources = collectMetadata(at: targetURL, hrefParts: parts, depth: boundedDepth) else {
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
        resolvedRoot: URL,
        webdavEnabled: Bool,
        protectedTopLevelDirectories: Set<String>
    ) -> WebDAVProtocol.HTTPResponseMessage {
        guard webdavEnabled else {
            return plainResponse(status: 405, reason: "Method Not Allowed", text: "WebDAV is disabled.")
        }
        guard let destHeader = destinationHeader else {
            return plainResponse(status: 400, reason: "Bad Request", text: "A Destination header is required.")
        }
        // A `Destination` is an absolute URI in RFC 4918 and a bare path in
        // practice. The policy accepts both and drops the authority, so a client
        // cannot name another host and have it honoured.
        let destParts: [String]
        switch WebDAVPathPolicy.components(fromTarget: destHeader) {
        case .success(let parsed):
            destParts = parsed
        case .failure(let rejection):
            return rejection.response
        }
        if let refusal = WebDAVPathPolicy.refusalForMutation(of: destParts, protectedRoots: protectedTopLevelDirectories) {
            return refusal.response
        }
        guard hasNoSymbolicLink(in: destParts, under: resolvedRoot) else {
            return WebDAVRequestRejection.outsideWorkspace.response
        }
        let destURL = WebDAVPathPolicy.location(for: destParts, underResolvedRoot: resolvedRoot)
        guard WebDAVPathPolicy.isContained(destURL, underResolvedRoot: resolvedRoot) else {
            return WebDAVRequestRejection.outsideWorkspace.response
        }
        let fm = FileManager.default
        guard fm.fileExists(atPath: targetURL.path) else {
            return plainResponse(status: 404, reason: "Not Found", text: "Source not found.")
        }
        // Never delete an existing destination before a potentially failing move.
        // Until transactional replacement is implemented, refuse overwrites.
        guard !fm.fileExists(atPath: destURL.path) else {
            return plainResponse(status: 412, reason: "Precondition Failed", text: "Destination already exists.")
        }
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
        headOnly: Bool,
        maximumDownloadBytes: Int
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
        guard fm.fileExists(atPath: targetURL.path, isDirectory: &isDir), !isDir.boolValue else {
            return plainResponse(status: 404, reason: "Not Found", text: "File not found.")
        }
        let size = Int64((try? targetURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        guard size <= Int64(maximumDownloadBytes) else {
            return WebDAVRequestRejection.downloadTooLarge(limit: maximumDownloadBytes).response
        }
        guard let data = try? Data(contentsOf: targetURL, options: .mappedIfSafe) else {
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
        bodyFileURL: URL?,
        contentLength: Int,
        resolvedRoot: URL
    ) -> WebDAVProtocol.HTTPResponseMessage {
        let fm = FileManager.default
        // The transport already refuses a declared body it never received; this
        // checks the bytes that actually landed, so a truncated upload is
        // refused here instead of being published as a shorter file.
        if contentLength > 0 {
            guard let bodyFileURL,
                  let size = fileSize(at: bodyFileURL),
                  size == contentLength else {
                return WebDAVRequestRejection.incompleteBody.response
            }
        }
        guard WebDAVPathPolicy.isContained(targetURL, underResolvedRoot: resolvedRoot) else {
            return WebDAVRequestRejection.outsideWorkspace.response
        }
        do {
            try fm.createDirectory(at: targetURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard !fm.fileExists(atPath: targetURL.path) else {
                return plainResponse(status: 412, reason: "Precondition Failed", text: "Destination already exists.")
            }
            if let bodyFileURL, fm.fileExists(atPath: bodyFileURL.path) {
                try fm.moveItem(at: bodyFileURL, to: targetURL)
            } else {
                try Data().write(to: targetURL, options: .atomic)
            }
            return plainResponse(status: 201, reason: "Created", text: "")
        } catch {
            return plainResponse(status: 507, reason: "Insufficient Storage", text: "Write failed.")
        }
    }

    nonisolated private static func fileSize(at url: URL) -> Int? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber else { return nil }
        return size.intValue
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
           let children = try? fm.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
           ) {
            for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                // A link is not listed and therefore not offered: the metadata a
                // client receives describes only what lives in the workspace.
                if let values = try? child.resourceValues(forKeys: [.isSymbolicLinkKey]),
                   values.isSymbolicLink == true {
                    continue
                }
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
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        let base = root.standardizedFileURL.path
        var out: [WebDAVProtocol.ResourceMetadata] = []
        for case let fileURL as URL in enumerator {
            guard let vals = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                  vals.isRegularFile == true,
                  vals.isSymbolicLink != true else { continue }
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
