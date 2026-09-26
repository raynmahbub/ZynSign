import Foundation

/// The library-organization use case: creating, renaming, and deleting
/// collections, putting applications into them and taking them out, and
/// remembering when each application was last opened.
///
/// The organizer owns the relationship between the organization value and
/// its store. Every change is a read-modify-write of the whole value: the
/// current organization is copied, the change is applied to the copy (which
/// enforces the rules and throws a typed error when one is broken), the
/// copy is saved, and only then does it become current. A failed rule or a
/// failed save therefore leaves both the store and the organizer exactly as
/// they were, and the caller receives the error.
///
/// The organizer never touches library records or package files. Adding an
/// application to a collection, removing it from one, and deleting a
/// collection all leave the application in the library; the only
/// connection in the other direction is `forget(_:)`, which the library
/// screen calls after it removed entries so no collection keeps pointing at
/// them.
///
/// The organizer is an actor and its store has no suspension points, so
/// each change runs to completion before the next begins; two changes can
/// never both read the same starting value and lose one another's work.
actor LibraryOrganizer {

    private let store: any LibraryOrganizationStore
    private let now: @Sendable () -> Date

    /// The organization as last read or saved, once it has been loaded.
    private var current: LibraryOrganization?

    /// Creates the organizer over the store the composition root selected.
    /// `now` supplies change times and is injectable for deterministic
    /// tests.
    init(
        store: any LibraryOrganizationStore,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.now = now
    }

    // MARK: - Reading

    /// The current organization. Read from the store the first time and
    /// kept afterwards; a read failure is thrown and retried on the next
    /// call, never replaced with an empty organization.
    func organization() throws -> LibraryOrganization {
        if let current {
            return current
        }
        let loaded = try store.loadOrganization()
        current = loaded
        return loaded
    }

    // MARK: - Collections

    /// Creates a collection named `name` containing `recordIDs` and returns
    /// it with the organization it now belongs to.
    func createCollection(
        named name: String,
        containing recordIDs: [ApplicationRecordIdentifier] = []
    ) throws -> (collection: LibraryCollection, organization: LibraryOrganization) {
        var created: LibraryCollection?
        let organization = try mutate { organization, date in
            created = try organization.createCollection(named: name, containing: recordIDs, at: date)
        }
        guard let created else {
            throw ZynSignError.libraryOrganizationConflict(diagnosticDetail: "The created collection was not produced.")
        }
        return (created, organization)
    }

    /// Renames the collection with `id`.
    @discardableResult
    func renameCollection(_ id: LibraryCollectionIdentifier, to name: String) throws -> LibraryOrganization {
        try mutate { organization, date in
            try organization.renameCollection(id, to: name, at: date)
        }
    }

    /// Deletes the collection with `id`. The applications in it stay in the
    /// library.
    @discardableResult
    func deleteCollection(_ id: LibraryCollectionIdentifier) throws -> LibraryOrganization {
        try mutate { organization, _ in
            try organization.deleteCollection(id)
        }
    }

    /// Adds `recordIDs` to the collection with `id`.
    @discardableResult
    func add(_ recordIDs: [ApplicationRecordIdentifier], to id: LibraryCollectionIdentifier) throws -> LibraryOrganization {
        try mutate { organization, date in
            try organization.add(recordIDs, to: id, at: date)
        }
    }

    /// Removes `recordIDs` from the collection with `id`. The applications
    /// stay in the library and in every other collection.
    @discardableResult
    func remove(_ recordIDs: [ApplicationRecordIdentifier], from id: LibraryCollectionIdentifier) throws -> LibraryOrganization {
        try mutate { organization, date in
            try organization.remove(recordIDs, from: id, at: date)
        }
    }

    /// Moves `recordIDs` from one collection to another as a single change.
    @discardableResult
    func move(
        _ recordIDs: [ApplicationRecordIdentifier],
        from source: LibraryCollectionIdentifier,
        to destination: LibraryCollectionIdentifier
    ) throws -> LibraryOrganization {
        try mutate { organization, date in
            try organization.move(recordIDs, from: source, to: destination, at: date)
        }
    }

    // MARK: - Usage

    /// Records that the application `recordID` was opened now.
    @discardableResult
    func recordOpened(_ recordID: ApplicationRecordIdentifier) throws -> LibraryOrganization {
        try mutate { organization, date in
            organization.recordOpen(of: recordID, at: date)
        }
    }

    // MARK: - Library changes

    /// Forgets every reference to `recordIDs`, after the library removed
    /// them.
    @discardableResult
    func forget(_ recordIDs: Set<ApplicationRecordIdentifier>) throws -> LibraryOrganization {
        try mutate { organization, date in
            organization.forgetRecords(recordIDs, at: date)
        }
    }

    // MARK: - Mutation

    /// Applies `change` to a copy of the current organization and saves the
    /// copy, which then becomes current. An unchanged copy is not saved.
    private func mutate(
        _ change: (inout LibraryOrganization, Date) throws -> Void
    ) throws -> LibraryOrganization {
        let base = try organization()
        var working = base
        try change(&working, now())
        guard working != base else {
            return base
        }
        try store.saveOrganization(working)
        current = working
        return working
    }
}
