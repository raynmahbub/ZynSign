import Foundation

// MARK: - Sorting

/// The orders the library can be listed in.
///
/// Raw values are stored as the user's preferred order. `name` keeps the
/// raw value the first library release stored for its single name order,
/// which is A–Z, so a preference saved then still reads the same way.
enum LibrarySortMode: String, CaseIterable, Identifiable, Codable, Sendable {

    /// Most recently imported first.
    case recentlyImported

    /// Most recently signed first; applications never signed follow, most
    /// recently imported first.
    case recentlySigned

    /// By display name, A to Z, the way a Contacts list sorts.
    case name

    /// By display name, Z to A.
    case nameDescending

    /// By declared version, newest first.
    case version

    /// By package size, largest first.
    case size

    /// Most recently opened first; applications never opened follow, most
    /// recently imported first.
    case lastOpened

    var id: Self { self }

    /// The user-presentable name, shown in the sort menu.
    var displayName: String {
        switch self {
        case .recentlyImported: return "Recently Imported"
        case .recentlySigned: return "Recently Signed"
        case .name: return "Name A–Z"
        case .nameDescending: return "Name Z–A"
        case .version: return "Version"
        case .size: return "Size"
        case .lastOpened: return "Last Opened"
        }
    }

    /// The symbol shown beside the name in the sort menu.
    var systemImage: String {
        switch self {
        case .recentlyImported: return "square.and.arrow.down"
        case .recentlySigned: return "signature"
        case .name: return "textformat"
        case .nameDescending: return "textformat"
        case .version: return "number"
        case .size: return "internaldrive"
        case .lastOpened: return "clock"
        }
    }

    /// Whether the order depends on the signing journal, and so only makes
    /// sense where signing is available.
    var dependsOnSigning: Bool {
        self == .recentlySigned
    }

    /// The orders the first library release offered. Shown on their own
    /// where the library's power features are not yet switched on.
    static let coreModes: [LibrarySortMode] = [.recentlyImported, .name, .version]
}

// MARK: - Filtering

/// Which declared versions of an application a filter keeps.
enum LibraryVersionFilter: String, CaseIterable, Codable, Sendable {

    /// Entries carrying the highest declared version held for their bundle
    /// identifier. Several entries can tie for it.
    case latest

    /// Entries whose declared version is lower than another entry held for
    /// the same bundle identifier.
    case older

    var displayName: String {
        switch self {
        case .latest: return "Latest Version"
        case .older: return "Older Versions"
        }
    }
}

/// One condition the library can be narrowed by.
///
/// Filters stack the way people expect: conditions on *different* facets
/// must all hold, and conditions on the *same* facet are alternatives. So
/// "Favorites + Unsigned + Recently Imported" lists favourite applications
/// that are unsigned and were imported recently, while choosing two
/// collections lists what is in either, and choosing both Signed and
/// Unsigned lists everything. The rule lives in `Facet`, so a new filter
/// only has to say which facet it belongs to.
enum LibraryFilter: Hashable, Codable, Sendable {

    /// Marked as a favourite.
    case favorites

    /// ZynSign's signing journal holds a successful signing of the entry.
    case signed

    /// ZynSign's signing journal holds no successful signing of the entry.
    case unsigned

    /// Imported within the recent window.
    case recentlyImported

    /// Successfully signed within the recent window.
    case recentlySigned

    /// The provisioning profile or certificate the entry was last signed
    /// with expires within the expiry window, or already has.
    case expiringSoon

    /// A member of the collection.
    case collection(LibraryCollectionIdentifier)

    /// Keeps the latest or the older declared versions.
    case version(LibraryVersionFilter)

    /// The package declares the development team identifier.
    case team(String)

    /// The dimension a filter constrains. Filters on one facet are OR-ed;
    /// facets are AND-ed.
    enum Facet: Hashable, Sendable {
        case favorites
        case signingStatus
        case recentlyImported
        case recentlySigned
        case expiringSoon
        case collection
        case version
        case team
    }

    var facet: Facet {
        switch self {
        case .favorites: return .favorites
        case .signed, .unsigned: return .signingStatus
        case .recentlyImported: return .recentlyImported
        case .recentlySigned: return .recentlySigned
        case .expiringSoon: return .expiringSoon
        case .collection: return .collection
        case .version: return .version
        case .team: return .team
        }
    }

    /// Whether the filter reads the signing journal, and so only makes
    /// sense where signing is available.
    var dependsOnSigning: Bool {
        switch self {
        case .signed, .unsigned, .recentlySigned, .expiringSoon: return true
        case .favorites, .recentlyImported, .collection, .version, .team: return false
        }
    }
}

/// The time windows the recency and expiry conditions use.
enum LibraryWindows {

    /// How far back "recently imported" and "recently signed" reach.
    static let recent: TimeInterval = 7 * 86_400

    /// How far ahead "expiring soon" looks. Matches the window the Profiles
    /// area uses for its expiring-soon badge.
    static let expiringSoon: TimeInterval = 30 * 86_400
}

// MARK: - Smart collections

/// A collection the library keeps up to date by itself.
///
/// A smart collection is a rule, not a list: it stores nothing, and its
/// members are whichever entries satisfy its filter at the moment it is
/// shown. Importing, signing, favouriting, or the passage of time changes
/// its contents without anyone editing it.
enum LibrarySmartCollection: String, CaseIterable, Identifiable, Codable, Sendable {
    case favorites
    case recentlyImported
    case recentlySigned
    case unsigned
    case expiringSoon

    var id: Self { self }

    /// The condition that decides membership.
    var filter: LibraryFilter {
        switch self {
        case .favorites: return .favorites
        case .recentlyImported: return .recentlyImported
        case .recentlySigned: return .recentlySigned
        case .unsigned: return .unsigned
        case .expiringSoon: return .expiringSoon
        }
    }

    var title: String {
        switch self {
        case .favorites: return "Favorites"
        case .recentlyImported: return "Recently Imported"
        case .recentlySigned: return "Recently Signed"
        case .unsigned: return "Unsigned"
        case .expiringSoon: return "Expiring Soon"
        }
    }

    var systemImage: String {
        switch self {
        case .favorites: return "star"
        case .recentlyImported: return "square.and.arrow.down"
        case .recentlySigned: return "signature"
        case .unsigned: return "circle.dashed"
        case .expiringSoon: return "clock.badge.exclamationmark"
        }
    }

    /// The rule in words, shown where the collection is empty so the user
    /// knows what would appear.
    var ruleDescription: String {
        switch self {
        case .favorites:
            return "Star your favorite apps to find them quickly."
        case .recentlyImported:
            return "Apps imported in the last 7 days appear here."
        case .recentlySigned:
            return "Apps ZynSign signed successfully in the last 7 days appear here, newest signing first when sorted by Recently Signed."
        case .unsigned:
            return "Apps ZynSign has never signed successfully appear here."
        case .expiringSoon:
            return "Apps whose last signing used a provisioning profile or certificate that expires within 30 days — or already has — appear here."
        }
    }

    /// The title of the collection's empty state.
    var emptyTitle: String {
        switch self {
        case .favorites: return "No Favorites"
        case .recentlyImported: return "Nothing Imported Recently"
        case .recentlySigned: return "Nothing Signed Recently"
        case .unsigned: return "No Unsigned Apps"
        case .expiringSoon: return "Nothing Expiring Soon"
        }
    }

    /// Whether the collection reads the signing journal.
    var dependsOnSigning: Bool {
        filter.dependsOnSigning
    }
}

// MARK: - Scope

/// Where in the library the user is looking: everything, one smart
/// collection, or one collection they made.
///
/// A scope is the starting set; filters and search narrow it further. The
/// scope has a stable text form so it can be remembered between launches,
/// handed from one screen to another, and — later — pinned or named by an
/// automation, without any of those needing to know how scopes work.
enum LibraryScope: Hashable, Sendable {
    case all
    case smart(LibrarySmartCollection)
    case collection(LibraryCollectionIdentifier)

    /// The stable text form: `all`, `smart:<name>`, or `collection:<id>`.
    var storageValue: String {
        switch self {
        case .all: return "all"
        case .smart(let smart): return "smart:\(smart.rawValue)"
        case .collection(let id): return "collection:\(id.rawValue)"
        }
    }

    /// Reads a scope from its text form, or returns `nil` when the text is
    /// not one.
    init?(storageValue: String) {
        if storageValue == "all" {
            self = .all
            return
        }
        let parts = storageValue.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        switch parts[0] {
        case "smart":
            guard let smart = LibrarySmartCollection(rawValue: parts[1]) else { return nil }
            self = .smart(smart)
        case "collection":
            guard let id = LibraryCollectionIdentifier(rawValue: parts[1]) else { return nil }
            self = .collection(id)
        default:
            return nil
        }
    }

    /// The collection the scope shows, when it is a collection.
    var collectionID: LibraryCollectionIdentifier? {
        if case .collection(let id) = self { return id }
        return nil
    }
}

// MARK: - Query

/// A complete description of what the library should list: search text,
/// stacked filters, and an order.
///
/// A query is a plain value with a codable form. The library screen builds
/// one from its controls; the same value is what a saved search, a pinned
/// view, or an automation would store and run later, so none of those
/// needs its own way of describing "which apps".
struct LibraryQuery: Hashable, Codable, Sendable {

    /// The text the user typed. Every whitespace-separated word must match
    /// somewhere; an empty text matches everything.
    var searchText: String

    /// The stacked filters. See `LibraryFilter` for how they combine.
    var filters: Set<LibraryFilter>

    /// The order results are listed in.
    var sort: LibrarySortMode

    init(
        searchText: String = "",
        filters: Set<LibraryFilter> = [],
        sort: LibrarySortMode = .recentlyImported
    ) {
        self.searchText = searchText
        self.filters = filters
        self.sort = sort
    }

    /// The search words as typed, in order, without empty words.
    var searchTerms: [String] {
        Self.terms(in: searchText)
    }

    /// The search words in the folded form the index compares.
    var foldedSearchTerms: [String] {
        searchTerms.map(Self.fold)
    }

    /// Splits text into search words on whitespace.
    static func terms(in text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    /// The comparison form of text: case, diacritics, and character width
    /// are ignored, so "cafe" finds "Café" and "ＡＢＣ" finds "abc".
    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }
}
