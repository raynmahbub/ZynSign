import Foundation

/// The stable identity of one collection in the library's organization.
///
/// Collections are referred to by identifier everywhere — in scopes, in
/// filters, in saved queries — and never by name, so renaming a collection
/// changes nothing that points at it. The identifier is also what a future
/// synchronised copy of the organization merges on: two devices that both
/// know a collection agree on its identifier even when they disagree on its
/// name.
struct LibraryCollectionIdentifier: Hashable, Sendable, Codable, CustomStringConvertible {

    /// The underlying uniqueness value.
    let uuid: UUID

    /// Mints a fresh identifier for a newly created collection.
    init() {
        self.uuid = UUID()
    }

    /// Reuses a previously minted identifier.
    init(uuid: UUID) {
        self.uuid = uuid
    }

    /// Rehydrates an identifier from its string form, or returns `nil` when
    /// the string is not an identifier.
    init?(rawValue: String) {
        guard let uuid = UUID(uuidString: rawValue) else { return nil }
        self.uuid = uuid
    }

    /// The canonical string form, used as the persisted value.
    var rawValue: String { uuid.uuidString }

    var description: String { rawValue }

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let uuid = UUID(uuidString: raw) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "The value is not a collection identifier."
            )
        }
        self.uuid = uuid
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// What kind of grouping a collection is.
///
/// Today every collection is one the user curates by hand. The kind is part
/// of the stored shape from the first version so that later groupings with
/// the same structure — a named, identified set of library records — arrive
/// as new values rather than as a new model: lightweight tags, or
/// collections shared from another person, are exactly that shape with a
/// different kind. A kind this build does not know is preserved verbatim
/// when the organization is read and written, and is not shown as a
/// collection, so an older build never destroys or misrepresents data a
/// newer one wrote.
struct LibraryCollectionKind: RawRepresentable, Hashable, Sendable, Codable {

    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// A collection the user creates, names, and fills by hand.
    static let collection = LibraryCollectionKind(rawValue: "collection")
}

/// One library record's place in a collection, and when it was put there.
///
/// The membership records the time it was made so that ordering within a
/// collection is stable and so that a future merge of two copies of the
/// organization can reconcile additions made on different devices.
struct LibraryCollectionMembership: Hashable, Sendable {

    /// The library record that is a member.
    let recordID: ApplicationRecordIdentifier

    /// When the record was added to the collection.
    let addedAt: Date
}

/// A named, user-curated set of library records.
///
/// A collection refers to records by identifier and owns nothing else: the
/// records stay in the library whatever happens to the collection, a record
/// can belong to any number of collections, and removing a record from a
/// collection never touches the record or its package. Deleting a
/// collection deletes only the grouping.
///
/// Collections are values. Every change produces a new value with the same
/// identifier and a later `updatedAt`; the organization decides whether the
/// change is allowed (unique names, known identifiers).
struct LibraryCollection: Hashable, Sendable, Identifiable {

    /// The longest collection name accepted, in characters.
    static let maximumNameLength = 60

    /// The collection's stable identity.
    let id: LibraryCollectionIdentifier

    /// The name the user gave the collection, already normalised.
    let name: String

    /// What kind of grouping this is.
    let kind: LibraryCollectionKind

    /// The member records, in the order they were added.
    let memberships: [LibraryCollectionMembership]

    /// When the collection was created.
    let createdAt: Date

    /// When the collection's name or membership last changed.
    let updatedAt: Date

    init(
        id: LibraryCollectionIdentifier = LibraryCollectionIdentifier(),
        name: String,
        kind: LibraryCollectionKind = .collection,
        memberships: [LibraryCollectionMembership] = [],
        createdAt: Date,
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.memberships = memberships
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
    }

    /// The member record identifiers, in the order they were added.
    var memberIDs: [ApplicationRecordIdentifier] {
        memberships.map(\.recordID)
    }

    /// Whether `recordID` is a member.
    func contains(_ recordID: ApplicationRecordIdentifier) -> Bool {
        memberships.contains { $0.recordID == recordID }
    }

    /// Whether this is a collection the user curates, as opposed to a kind
    /// of grouping a later version of ZynSign introduced.
    var isUserCollection: Bool {
        kind == .collection
    }

    /// Returns the collection with its name replaced. The caller has
    /// already normalised and validated the name.
    func renamed(_ newName: String, at date: Date) -> LibraryCollection {
        guard newName != name else { return self }
        return LibraryCollection(
            id: id,
            name: newName,
            kind: kind,
            memberships: memberships,
            createdAt: createdAt,
            updatedAt: date
        )
    }

    /// Returns the collection with `recordIDs` added after the existing
    /// members. Records already present, and repeats within `recordIDs`,
    /// are skipped, so adding is idempotent and never reorders anything.
    /// When nothing is added the collection is returned unchanged.
    func adding(_ recordIDs: [ApplicationRecordIdentifier], at date: Date) -> LibraryCollection {
        var present = Set(memberIDs)
        var additions: [LibraryCollectionMembership] = []
        for recordID in recordIDs where present.insert(recordID).inserted {
            additions.append(LibraryCollectionMembership(recordID: recordID, addedAt: date))
        }
        guard !additions.isEmpty else { return self }
        return LibraryCollection(
            id: id,
            name: name,
            kind: kind,
            memberships: memberships + additions,
            createdAt: createdAt,
            updatedAt: date
        )
    }

    /// Returns the collection without the members in `recordIDs`. When none
    /// of them is a member the collection is returned unchanged.
    func removing(_ recordIDs: Set<ApplicationRecordIdentifier>, at date: Date) -> LibraryCollection {
        let remaining = memberships.filter { !recordIDs.contains($0.recordID) }
        guard remaining.count != memberships.count else { return self }
        return LibraryCollection(
            id: id,
            name: name,
            kind: kind,
            memberships: remaining,
            createdAt: createdAt,
            updatedAt: date
        )
    }

    /// Normalises a name the user typed: surrounding whitespace is removed,
    /// runs of whitespace and line breaks become one space, and control
    /// characters are dropped. Returns `nil` when nothing is left or the
    /// result is longer than `maximumNameLength` characters.
    static func normalizedName(_ raw: String) -> String? {
        let words = raw.split(whereSeparator: { $0.isWhitespace })
        let joined = words.joined(separator: " ")
        var scalars = String.UnicodeScalarView()
        scalars.append(contentsOf: joined.unicodeScalars.filter { $0.properties.generalCategory != .control })
        let cleaned = String(scalars)
        guard !cleaned.isEmpty, cleaned.count <= maximumNameLength else {
            return nil
        }
        return cleaned
    }

    /// The form two names are compared in when deciding whether they
    /// collide: case, diacritics, and width are ignored, so "Games",
    /// "games", and "GÄMES" cannot coexist.
    static func comparableName(_ name: String) -> String {
        name.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }
}
