import Foundation

/// A character range in a display name, stored as offsets so it does not
/// borrow another string's indices.
struct ExplorerHighlight: Equatable, Hashable {

    /// The index of the first matching character.
    let start: Int

    /// The number of matching characters.
    let length: Int

    /// The range in `name`, or `nil` when the offsets do not fit that string.
    func range(in name: String) -> Range<String.Index>? {
        guard start >= 0, length > 0, start <= name.count, start + length <= name.count else { return nil }
        let lower = name.index(name.startIndex, offsetBy: start)
        let upper = name.index(lower, offsetBy: length)
        return lower..<upper
    }
}

/// Where a search hit came from.
enum BundleSearchField: String, Equatable, Hashable {
    /// The entry's own name contains the query.
    case name
    /// An immediate parent folder's name contains the query.
    case folder
}

/// One search hit. The path is bundle-relative; `locationText` is the
/// package-relative text the explorer copies.
struct BundleSearchMatch: Equatable, Hashable, Identifiable {

    let path: BundlePath
    let name: String
    let locationText: String
    let field: BundleSearchField
    let highlight: ExplorerHighlight?
    /// The parent folder named in a folder hit, otherwise `nil`.
    let folderName: String?

    var id: BundlePath { path }
}

/// The outcome of one search. `matches` is capped; `totalMatchCount` is not,
/// so the explorer can say how many hits it did not render.
struct BundleSearchResult: Equatable {

    let matches: [BundleSearchMatch]
    let totalMatchCount: Int
    let isTruncated: Bool

    static let empty = BundleSearchResult(matches: [], totalMatchCount: 0, isTruncated: false)
}

/// An in-memory index of one bundle, built once from `BundleContents`.
///
/// Search does not read file bytes and does not allocate a second copy of
/// file contents. Matching is a scan of names the entry table already holds.
/// An empty query matches nothing, so a large bundle is not rendered as a
/// search result list until the user types.
struct BundleSearchIndex: Equatable {

    /// How many hits a search returns before telling the caller the rest were
    /// not rendered. The total count still includes them.
    static let defaultLimit = 200

    private struct Item: Equatable {
        let path: BundlePath
        let name: String
        let parentName: String
        let isDirectory: Bool
    }

    private let bundleName: String
    private let items: [Item]

    /// Indexes every entry `contents` can list. Implied directories are
    /// included because `BundleContents` already materialised them.
    init(contents: BundleContents) {
        self.bundleName = contents.bundleName
        var collected: [Item] = []
        func walk(_ directory: BundlePath) {
            for entry in contents.entries(in: directory) ?? [] {
                collected.append(Item(
                    path: entry.path,
                    name: entry.name,
                    parentName: entry.path.parent?.name ?? "",
                    isDirectory: entry.isDirectory
                ))
                if entry.isDirectory {
                    walk(entry.path)
                }
            }
        }
        walk(.root)
        self.items = collected
    }

    /// How many entries the index holds.
    var count: Int { items.count }

    /// Searches by filename, extension, and immediate folder name.
    ///
    /// Extension queries are filename queries in practice — `png` occurs in
    /// `Icon.PNG` — and are matched without case. A folder hit is the folder
    /// itself plus the entries directly inside it, not every descendant, so a
    /// short query cannot force the explorer to materialise a whole subtree.
    /// Results are ordered by match quality and then by path, compared as
    /// Unicode scalars, and capped at `limit`.
    func search(_ query: String, limit: Int = defaultLimit) -> BundleSearchResult {
        let trimmed = String(query.trimmingCharacters(in: .whitespacesAndNewlines).prefix(256))
        guard !trimmed.isEmpty else { return .empty }
        let capped = max(1, limit)

        struct Candidate {
            let rank: Int
            let match: BundleSearchMatch
        }
        var candidates: [Candidate] = []
        candidates.reserveCapacity(min(items.count, capped))

        for item in items {
            guard let found = Self.candidate(item, query: trimmed, bundleName: bundleName) else { continue }
            candidates.append(Candidate(rank: found.rank, match: found.match))
        }
        candidates.sort { lhs, rhs in
            if lhs.rank != rhs.rank { return lhs.rank < rhs.rank }
            return lhs.match.path.rawValue.unicodeScalars.lexicographicallyPrecedes(
                rhs.match.path.rawValue.unicodeScalars
            )
        }
        let shown = candidates.prefix(capped).map(\.match)
        return BundleSearchResult(
            matches: Array(shown),
            totalMatchCount: candidates.count,
            isTruncated: candidates.count > shown.count
        )
    }

    private static func candidate(_ item: Item, query: String, bundleName: String) -> (rank: Int, match: BundleSearchMatch)? {
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        let locale = Locale(identifier: "en_US_POSIX")
        if let range = item.name.range(of: query, options: options, locale: locale) {
            let start = item.name.distance(from: item.name.startIndex, to: range.lowerBound)
            let length = item.name.distance(from: range.lowerBound, to: range.upperBound)
            let exact = range.lowerBound == item.name.startIndex && range.upperBound == item.name.endIndex
            let prefix = range.lowerBound == item.name.startIndex
            let rank = exact ? 0 : (prefix ? 1 : 2)
            return (rank, BundleSearchMatch(
                path: item.path,
                name: item.name,
                locationText: ExplorerLocation.displayPath(bundleName: bundleName, entry: item.path),
                field: .name,
                highlight: ExplorerHighlight(start: start, length: length),
                folderName: nil
            ))
        }
        guard !item.parentName.isEmpty,
              item.parentName.range(of: query, options: options, locale: locale) != nil else {
            return nil
        }
        return (3, BundleSearchMatch(
            path: item.path,
            name: item.name,
            locationText: ExplorerLocation.displayPath(bundleName: bundleName, entry: item.path),
            field: .folder,
            highlight: nil,
            folderName: item.parentName
        ))
    }
}
