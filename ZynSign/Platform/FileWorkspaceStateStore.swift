import Foundation

/// The file-backed `WorkspaceStateStore`: one small versioned JSON document
/// under Application Support, replaced atomically on every change.
///
/// The document holds widget open counts and the last-session record —
/// display state only. A document that cannot be decoded is treated as
/// absent rather than repaired: the workspace simply starts from its
/// defaults, and the next write replaces the damaged file.
final class FileWorkspaceStateStore: WorkspaceStateStore, @unchecked Sendable {

    static let currentSchemaVersion = 1

    private struct Document: Codable {
        var schemaVersion: Int
        var usage: [WorkspaceUsageSignal]
        var lastSession: WorkspaceSession?
    }

    let documentLocation: URL
    private let access = NSLock()
    private var cached: Document?

    init(documentLocation: URL) {
        self.documentLocation = documentLocation
    }

    // MARK: - WorkspaceStateStore

    func usage() throws -> [WorkspaceUsageSignal] {
        access.lock(); defer { access.unlock() }
        return load().usage
    }

    func recordOpen(of widget: WorkspaceWidget, at date: Date) throws {
        access.lock(); defer { access.unlock() }
        var document = load()
        if let index = document.usage.firstIndex(where: { $0.widget == widget }) {
            document.usage[index].openCount += 1
            document.usage[index].lastOpenedAt = date
        } else {
            document.usage.append(WorkspaceUsageSignal(widget: widget, openCount: 1, lastOpenedAt: date))
        }
        try persist(document)
    }

    func lastSession() throws -> WorkspaceSession? {
        access.lock(); defer { access.unlock() }
        return load().lastSession
    }

    func setLastSession(_ session: WorkspaceSession?) throws {
        access.lock(); defer { access.unlock() }
        var document = load()
        document.lastSession = session
        try persist(document)
    }

    // MARK: - Storage

    private func load() -> Document {
        if let cached { return cached }
        let fresh = Document(schemaVersion: Self.currentSchemaVersion, usage: [], lastSession: nil)
        guard let data = try? Data(contentsOf: documentLocation) else {
            cached = fresh
            return fresh
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let document = try? decoder.decode(Document.self, from: data),
           document.schemaVersion == Self.currentSchemaVersion {
            cached = document
            return document
        }
        cached = fresh
        return fresh
    }

    private func persist(_ document: Document) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(document)
        let directory = documentLocation.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appendingPathComponent(".\(documentLocation.lastPathComponent).\(UUID().uuidString).tmp")
        try data.write(to: temporary, options: .atomic)
        _ = try FileManager.default.replaceItemAt(documentLocation, withItemAt: temporary)
        cached = document
    }
}
