import Foundation

/// The user's own organization of the library: the collections they made
/// and when they last opened each application.
///
/// The organization is kept apart from the library catalog on purpose. The
/// catalog describes packages — what each one declared, where its bytes
/// are, what inspection concluded — and changes when packages arrive or
/// leave. The organization describes how one person arranges and uses
/// those packages, and changes far more often: every time a detail screen
/// opens, a collection is renamed, or apps are moved around. Keeping the
/// two apart means none of that churn rewrites the catalog, and it keeps
/// the parts a future synchronisation would treat differently (package
/// facts versus personal arrangement) in separate documents.
///
/// **Model.** Everything here refers to library records by identifier and
/// to collections by identifier; nothing is keyed by a name, a path, or a
/// position. Every collection carries its creation and change times and
/// every membership carries the time it was made. That is the whole data
/// model, and it is deliberately general: tags and shared collections are
/// collections of another `LibraryCollectionKind`; pinned workflows and
/// automations name a `LibraryScope` or a `LibraryQuery`, which already
/// have stable, codable forms; synchronisation merges by identifier using
/// the timestamps. None of those needs a different shape.
///
/// **Integrity.** Collection names are normalised and unique (ignoring
/// case, diacritics, and width), identifiers are unique, and a record
/// appears at most once per collection. The mutating operations enforce
/// this and fail with typed errors; a failed operation leaves the value
/// exactly as it was. References to records the library no longer holds
/// are harmless — readers intersect with the records they have — and are
/// pruned by `forgetRecords(_:)` when the library removes an entry.
struct LibraryOrganization: Hashable, Sendable {

    /// Every collection, in the order it was created. Includes groupings of
    /// kinds this build does not present, so they survive a round trip.
    private(set) var collections: [LibraryCollection]

    /// When each application was last opened, by record.
    private(set) var lastOpened: [ApplicationRecordIdentifier: Date]

    /// An organization with no collections and no usage.
    static let empty = LibraryOrganization(collections: [], lastOpened: [:])

    init(collections: [LibraryCollection], lastOpened: [ApplicationRecordIdentifier: Date]) {
        self.collections = collections
        self.lastOpened = lastOpened
    }

    // MARK: - Reading

    /// The collections the user curates, in creation order.
    var userCollections: [LibraryCollection] {
        collections.filter(\.isUserCollection)
    }

    /// The collection with `id`, or `nil` when there is none.
    func collection(withID id: LibraryCollectionIdentifier) -> LibraryCollection? {
        collections.first { $0.id == id }
    }

    /// The user collections that contain `recordID`, in creation order.
    func collectionsHolding(_ recordID: ApplicationRecordIdentifier) -> [LibraryCollection] {
        userCollections.filter { $0.contains(recordID) }
    }

    /// Validates a name the user typed for a collection, returning the
    /// normalised name. Names are unique among groupings of the same kind.
    /// `excluding` names the collection being renamed, so renaming a
    /// collection to its own name (or a different spelling of it) is
    /// allowed.
    func validatedName(
        _ raw: String,
        kind: LibraryCollectionKind = .collection,
        excluding excludedID: LibraryCollectionIdentifier? = nil
    ) throws -> String {
        guard let name = LibraryCollection.normalizedName(raw) else {
            throw ZynSignError.libraryCollectionNameInvalid(
                diagnosticDetail: "The collection name was empty or longer than \(LibraryCollection.maximumNameLength) characters after normalisation."
            )
        }
        let comparable = LibraryCollection.comparableName(name)
        let collides = collections.contains { existing in
            existing.id != excludedID
                && existing.kind == kind
                && LibraryCollection.comparableName(existing.name) == comparable
        }
        guard !collides else {
            throw ZynSignError.libraryCollectionNameTaken(
                diagnosticDetail: "Another collection already uses the requested name."
            )
        }
        return name
    }

    // MARK: - Collections

    /// Creates a collection named `name` holding `recordIDs`, appended after
    /// the existing collections, and returns it.
    @discardableResult
    mutating func createCollection(
        named name: String,
        containing recordIDs: [ApplicationRecordIdentifier] = [],
        id: LibraryCollectionIdentifier = LibraryCollectionIdentifier(),
        at date: Date
    ) throws -> LibraryCollection {
        guard collection(withID: id) == nil else {
            throw ZynSignError.libraryOrganizationConflict(
                diagnosticDetail: "A collection already carries identifier '\(id.rawValue)'."
            )
        }
        let validName = try validatedName(name)
        // Members added while creating share the creation instant, so the
        // new collection's change time equals its creation time.
        let collection = LibraryCollection(id: id, name: validName, createdAt: date)
            .adding(recordIDs, at: date)
        collections.append(collection)
        return collection
    }

    /// Renames the collection with `id`.
    mutating func renameCollection(
        _ id: LibraryCollectionIdentifier,
        to name: String,
        at date: Date
    ) throws {
        let position = try indexOfCollection(id)
        let validName = try validatedName(name, kind: collections[position].kind, excluding: id)
        collections[position] = collections[position].renamed(validName, at: date)
    }

    /// Deletes the collection with `id`. Its member records are untouched.
    mutating func deleteCollection(_ id: LibraryCollectionIdentifier) throws {
        let position = try indexOfCollection(id)
        collections.remove(at: position)
    }

    /// Adds `recordIDs` to the collection with `id`. Records already in the
    /// collection stay where they are.
    mutating func add(
        _ recordIDs: [ApplicationRecordIdentifier],
        to id: LibraryCollectionIdentifier,
        at date: Date
    ) throws {
        let position = try indexOfCollection(id)
        collections[position] = collections[position].adding(recordIDs, at: date)
    }

    /// Removes `recordIDs` from the collection with `id`. The records stay
    /// in the library and in every other collection.
    mutating func remove(
        _ recordIDs: [ApplicationRecordIdentifier],
        from id: LibraryCollectionIdentifier,
        at date: Date
    ) throws {
        let position = try indexOfCollection(id)
        collections[position] = collections[position].removing(Set(recordIDs), at: date)
    }

    /// Moves `recordIDs` from the collection `source` to the collection
    /// `destination` as one change: they are added to the destination and
    /// removed from the source. Moving into the collection they are already
    /// in changes nothing.
    mutating func move(
        _ recordIDs: [ApplicationRecordIdentifier],
        from source: LibraryCollectionIdentifier,
        to destination: LibraryCollectionIdentifier,
        at date: Date
    ) throws {
        let sourcePosition = try indexOfCollection(source)
        let destinationPosition = try indexOfCollection(destination)
        guard sourcePosition != destinationPosition else { return }
        collections[destinationPosition] = collections[destinationPosition].adding(recordIDs, at: date)
        collections[sourcePosition] = collections[sourcePosition].removing(Set(recordIDs), at: date)
    }

    // MARK: - Usage

    /// Records that the application `recordID` was opened at `date`.
    mutating func recordOpen(of recordID: ApplicationRecordIdentifier, at date: Date) {
        lastOpened[recordID] = date
    }

    // MARK: - Library changes

    /// Forgets every reference to `recordIDs`: their memberships in every
    /// collection and their usage. Called after the library removed those
    /// records, so nothing points at an entry that no longer exists.
    mutating func forgetRecords(_ recordIDs: Set<ApplicationRecordIdentifier>, at date: Date) {
        guard !recordIDs.isEmpty else { return }
        collections = collections.map { $0.removing(recordIDs, at: date) }
        for recordID in recordIDs {
            lastOpened.removeValue(forKey: recordID)
        }
    }

    // MARK: - Helpers

    private func indexOfCollection(_ id: LibraryCollectionIdentifier) throws -> Int {
        guard let position = collections.firstIndex(where: { $0.id == id }) else {
            throw ZynSignError.libraryCollectionNotFound(
                diagnosticDetail: "No collection carries identifier '\(id.rawValue)'."
            )
        }
        return position
    }
}
