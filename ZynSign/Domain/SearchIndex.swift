import Foundation

/// A substring search index over short text documents.
///
/// **Why an inverted index.** The library screen answers every keystroke by
/// asking which entries contain every typed word somewhere in their
/// searchable text. Scanning every document for every keystroke is linear
/// in the library and in the text; at a few hundred entries that is
/// invisible, at a few thousand it is a dropped frame per character. This
/// index answers the same question from precomputed character trigrams:
/// each folded document is cut into overlapping three-character windows,
/// and each window maps to the identifiers of the documents that contain
/// it. A term of three characters or more is then reduced to the
/// intersection of a handful of small posting lists, and only those
/// candidates are verified with a real substring test — so the answer is
/// exactly the substring answer, reached in time proportional to the
/// matches rather than to the library.
///
/// **Semantics preserved.** The index never changes what matches. A term
/// occurs in a document exactly when the folded term is a substring of any
/// of the document's folded fields — the same rule the library has always
/// used. Trigrams only *narrow*; the verification step decides. Terms
/// shorter than three characters have no trigram to narrow by and fall
/// back to a scan of the documents, which remains cheap because the
/// folded text is already computed and short.
///
/// **Incremental.** Adding, replacing, and removing one document touches
/// only that document's trigrams. Rebuilding everything is O(total text).
/// The index is a value: it can be copied, compared by generation, and
/// replaced atomically by whoever owns it.
///
/// **Generic.** The identifier type is the caller's; fields are named by a
/// caller-supplied `Hashable` key, so the same index serves the library
/// today and any other catalogue later without a new implementation.
struct SearchIndex<ID: Hashable, Field: Hashable>: Equatable {

    /// One document's folded text, by field. Fields hold text that has
    /// already been folded with `SearchIndex.fold`; the index folds
    /// nothing itself, so callers control the comparison form exactly.
    struct Document: Equatable {
        var fields: [Field: String]

        init(fields: [Field: String] = [:]) {
            self.fields = fields
        }

        /// Whether the folded `term` occurs in any field.
        func contains(_ term: String) -> Bool {
            for text in fields.values where !text.isEmpty && text.contains(term) {
                return true
            }
            return false
        }

        /// The fields the folded `term` occurs in, in no particular order.
        func fields(containing term: String) -> [Field] {
            fields.compactMap { field, text in
                (!text.isEmpty && text.contains(term)) ? field : nil
            }
        }
    }

    /// The width of one indexed character window.
    static var gramLength: Int { 3 }

    /// Every document, by identifier.
    private(set) var documents: [ID: Document] = [:]

    /// The identifiers of the documents containing each trigram.
    private var postings: [String: Set<ID>] = [:]

    /// The trigrams each document contributed, so removal is exact.
    private var gramsByDocument: [ID: Set<String>] = [:]

    /// Increments on every mutation; lets an owner tell two states apart
    /// without comparing the whole index.
    private(set) var generation: UInt64 = 0

    /// An empty index.
    init() {}

    /// An index over `documents`.
    init(documents: [ID: Document]) {
        replaceAll(documents)
    }

    // MARK: - Reading

    /// How many documents the index holds.
    var count: Int { documents.count }

    /// Whether the index holds a document for `id`.
    func contains(_ id: ID) -> Bool { documents[id] != nil }

    /// The document for `id`, or `nil`.
    func document(for id: ID) -> Document? { documents[id] }

    /// How many distinct trigrams the index holds. A diagnostic figure.
    var postingCount: Int { postings.count }

    /// The identifiers of every document in which *every* folded term
    /// occurs, restricted to `candidates` when given. Order is unspecified.
    ///
    /// Terms are applied most selective first, so the candidate set shrinks
    /// as quickly as possible; an empty term list matches everything.
    func matches(allOf foldedTerms: [String], among candidates: Set<ID>? = nil) -> Set<ID> {
        var survivors: Set<ID>? = candidates
        let ordered = foldedTerms.filter { !$0.isEmpty }.sorted { $0.count > $1.count }
        for term in ordered {
            let narrowed = narrow(term, within: survivors)
            let verified = narrowed.filter { id in documents[id]?.contains(term) ?? false }
            survivors = verified
            if verified.isEmpty { break }
        }
        return survivors ?? Set(documents.keys)
    }

    /// Whether the document for `id` contains every folded term.
    func document(_ id: ID, matchesAllOf foldedTerms: [String]) -> Bool {
        guard let document = documents[id] else { return false }
        return foldedTerms.allSatisfy { $0.isEmpty || document.contains($0) }
    }

    // MARK: - Updating

    /// Inserts or replaces the document for `id`.
    mutating func upsert(_ id: ID, document: Document) {
        if documents[id] == document { return }
        removeGrams(of: id)
        documents[id] = document
        addGrams(of: id, document: document)
        generation &+= 1
    }

    /// Removes the document for `id`, if any.
    mutating func remove(_ id: ID) {
        guard documents[id] != nil else { return }
        removeGrams(of: id)
        documents[id] = nil
        generation &+= 1
    }

    /// Removes the documents for `ids`.
    mutating func remove<S: Sequence>(_ ids: S) where S.Element == ID {
        for id in ids { remove(id) }
    }

    /// Replaces every document.
    mutating func replaceAll(_ newDocuments: [ID: Document]) {
        documents = newDocuments
        postings = [:]
        gramsByDocument = [:]
        postings.reserveCapacity(newDocuments.count * 8)
        for (id, document) in newDocuments {
            addGrams(of: id, document: document)
        }
        generation &+= 1
    }

    // MARK: - Folding

    /// The comparison form of text: case, diacritics, and character width
    /// are ignored, so "cafe" finds "Café" and "ＡＢＣ" finds "abc". The
    /// same rule `LibraryQuery.fold` applies, restated here so the domain
    /// index needs nothing from the library.
    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    /// The trigrams of `text`. Text shorter than one gram yields none.
    static func grams(of text: String) -> Set<String> {
        let characters = Array(text)
        guard characters.count >= gramLength else { return [] }
        var result: Set<String> = []
        var start = 0
        while start + gramLength <= characters.count {
            result.insert(String(characters[start..<(start + gramLength)]))
            start += 1
        }
        return result
    }

    // MARK: - Private

    /// The candidates that could contain `term`: the intersection of its
    /// trigram postings, further restricted to `within` when given. Terms
    /// too short for a trigram return every candidate.
    private func narrow(_ term: String, within candidates: Set<ID>?) -> Set<ID> {
        let grams = Self.grams(of: term)
        guard !grams.isEmpty else {
            return candidates ?? Set(documents.keys)
        }
        // Smallest posting list first keeps the intersection cheap.
        let lists = grams.map { postings[$0] ?? [] }.sorted { $0.count < $1.count }
        guard var result = lists.first else { return [] }
        if let candidates {
            result = result.intersection(candidates)
        }
        for list in lists.dropFirst() {
            if result.isEmpty { break }
            result.formIntersection(list)
        }
        return result
    }

    private mutating func addGrams(of id: ID, document: Document) {
        var grams: Set<String> = []
        for text in document.fields.values where !text.isEmpty {
            grams.formUnion(Self.grams(of: text))
        }
        for gram in grams {
            postings[gram, default: []].insert(id)
        }
        gramsByDocument[id] = grams
    }

    private mutating func removeGrams(of id: ID) {
        guard let grams = gramsByDocument.removeValue(forKey: id) else { return }
        for gram in grams {
            guard var list = postings[gram] else { continue }
            list.remove(id)
            if list.isEmpty {
                postings[gram] = nil
            } else {
                postings[gram] = list
            }
        }
    }
}

/// How ready a search index is to answer.
enum SearchIndexStatus: Equatable, Sendable {

    /// Nothing has been indexed yet.
    case empty

    /// The index is being (re)built; answers come from the previous state.
    case building(indexed: Int, total: Int)

    /// The index answers for every document it was given.
    case ready(indexed: Int)

    /// The index is older than the data it describes and will be rebuilt.
    case stale(indexed: Int)

    /// A user-presentable one-line description.
    var displayText: String {
        switch self {
        case .empty:
            return "Empty"
        case .building(let indexed, let total):
            return total > 0 ? "Building · \(indexed) of \(total)" : "Building"
        case .ready(let indexed):
            return indexed == 1 ? "Ready · 1 app" : "Ready · \(indexed) apps"
        case .stale(let indexed):
            return indexed == 1 ? "Stale · 1 app" : "Stale · \(indexed) apps"
        }
    }

    /// Whether the index is answering from a complete, current state.
    var isReady: Bool {
        if case .ready = self { return true }
        return false
    }
}

extension SearchIndex: Sendable where ID: Sendable, Field: Sendable {}
extension SearchIndex.Document: Sendable where ID: Sendable, Field: Sendable {}
