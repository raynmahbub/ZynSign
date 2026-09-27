import Foundation

/// A catalog identity always includes the repository. Bundle IDs are claims, not global keys.
struct CatalogApp: Codable, Hashable, Identifiable, Sendable {
    let sourceID: UUID
    let bundleID: String
    let name: String
    let developer: String
    let developerIconURL: URL?
    let keywords: [String]?
    let subtitle: String?
    let description: String
    let iconURL: URL?
    let screenshots: [URL]
    let category: String
    let releases: [CatalogRelease]
    let featured: Bool
    var id: String { sourceID.uuidString + ":" + bundleID }
    var latest: CatalogRelease { releases[0] } // validator guarantees nonempty, newest-first
}

struct CatalogRelease: Codable, Hashable, Identifiable, Sendable {
    let version: String
    let date: Date?
    let notes: String?
    let downloadURL: URL
    let size: Int64?
    let minOSVersion: String?
    let maxOSVersion: String?
    var id: String { version }
}

struct CatalogSource: Codable, Hashable, Identifiable, Sendable {
    enum Health: String, Codable, Sendable { case healthy, warning, offline }
    let id: UUID
    let url: URL
    var name: String
    var identifier: String?
    var iconURL: URL?
    var summary: String?
    var enabled = true
    var apps: [CatalogApp]
    var refreshedAt: Date?
    var attemptedAt: Date?
    var health: Health = .healthy
    var problem: String?
    var etag: String?
    var modified: String?
    func status(at now: Date = Date()) -> Health {
        if health == .offline { return .offline }
        if health == .warning || apps.isEmpty || now.timeIntervalSince(refreshedAt ?? .distantPast) > 7 * 86400 {
            return .warning
        }
        return .healthy
    }
}

struct StoreSnapshot: Codable, Sendable {
    var schema = 1
    var revision: UInt64 = 0
    var sources: [CatalogSource] = []
    var preferredSources: [String: UUID] = [:]
    var ignoredVersions: [String: String] = [:] // source-scoped app ID
    var recentSearches: [String] = []
    var browsing: [String] = []
    var visits: [String: Int] = [:]
    /// Source-scoped app IDs saved locally. Optional to decode pre-discovery snapshots.
    var savedAppIDs: [String]? = nil
}

enum StoreFailure: LocalizedError, Equatable {
    case invalid(String)
    var errorDescription: String? { switch self { case .invalid(let message): return message } }
}

/// HTTPS only, no embedded credentials, fragments or ambiguous relative URLs.
/// URLs are never turned into filenames or executable content.
enum StoreURLPolicy {
    static func validate(_ raw: String) throws -> URL {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count <= 4096, !value.contains(where: { $0.isWhitespace }),
              var parts = URLComponents(string: value), parts.scheme?.lowercased() == "https",
              let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil,
              parts.fragment == nil, parts.port == nil || parts.port == 443 else {
            throw StoreFailure.invalid("Use an absolute HTTPS URL without credentials, fragments, or a custom port.")
        }
        parts.scheme = "https"
        parts.host = host.lowercased()
        parts.port = nil
        if parts.path.isEmpty { parts.path = "/" }
        guard let url = parts.url else { throw StoreFailure.invalid("The URL could not be parsed.") }
        return url
    }
}

/// Deliberately conservative: arbitrary marketing strings are not ordered as versions.
enum CatalogVersion {
    static func components(_ value: String) -> [Int]? {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.count <= 8 else { return nil }
        var result: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.allSatisfy({ $0.isASCII && $0.isNumber }), let number = Int(part) else { return nil }
            result.append(number)
        }
        return result
    }
    static func isNewer(_ candidate: String, than installed: String) -> Bool {
        guard let a = components(candidate), let b = components(installed) else { return false }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}

struct CatalogSearchIndex {
    private let entries: [(app: CatalogApp, text: String, words: [String])]
    init(sources: [CatalogSource]) {
        entries = sources.filter(\.enabled).flatMap { source in
            source.apps.map { app in
                let text = Self.fold([
                    app.name, app.developer, app.bundleID, app.category, app.description,
                    source.name, source.url.absoluteString, app.keywords?.joined(separator: " ") ?? ""
                ].joined(separator: " "))
                return (app, text, text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
            }
        }.sorted { $0.0.name.localizedStandardCompare($1.0.name) == .orderedAscending }
    }
    static func fold(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
    func search(_ query: String, category: String? = nil, sourceID: UUID? = nil) -> [CatalogApp] {
        let tokens = Self.fold(String(query.prefix(200))).split(whereSeparator: \.isWhitespace).prefix(16).map(String.init)
        return entries.compactMap { app, text, words in
            guard category == nil || Self.fold(app.category) == Self.fold(category!),
                  sourceID == nil || app.sourceID == sourceID else { return nil }
            return tokens.allSatisfy { token in
                text.contains(token) || (token.count >= 4 && words.contains { Self.oneEditApart(token, $0) })
            } ? app : nil
        }
    }
    // Bounded one-character insertion/deletion/substitution, not an unbounded fuzzy scan.
    static func oneEditApart(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs), b = Array(rhs)
        guard abs(a.count - b.count) <= 1 else { return false }
        var i = 0, j = 0, edits = 0
        while i < a.count && j < b.count {
            if a[i] == b[j] { i += 1; j += 1; continue }
            edits += 1
            if edits > 1 { return false }
            if a.count >= b.count { i += 1 }
            if b.count >= a.count { j += 1 }
        }
        return edits + (a.count - i) + (b.count - j) <= 1
    }
}

struct CatalogUpdate: Identifiable {
    let app: CatalogApp
    let installed: String
    var id: String { app.id }
}
enum CatalogUpdatePolicy {
    static func updates(in snapshot: StoreSnapshot, installed: [String: String]) -> [CatalogUpdate] {
        snapshot.sources.filter(\.enabled).flatMap(\.apps).compactMap { app in
            guard let version = installed[app.bundleID], snapshot.preferredSources[app.bundleID] == app.sourceID,
                  snapshot.ignoredVersions[app.id] != app.latest.version,
                  CatalogVersion.isNewer(app.latest.version, than: version) else { return nil }
            return CatalogUpdate(app: app, installed: version)
        }.sorted { $0.app.name.localizedStandardCompare($1.app.name) == .orderedAscending }
    }
}
