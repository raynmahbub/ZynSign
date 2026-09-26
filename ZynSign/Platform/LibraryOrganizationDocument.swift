import Foundation

/// The persisted form of the library's organization: collections, their
/// memberships, and per-application usage.
///
/// The document is versioned independently of the library catalog and of
/// the signing journal. Every reference is an identifier string, every
/// time is a number of seconds, and every collection keeps its kind — so
/// the document can grow new kinds and new optional fields without a
/// different shape.
///
/// Version history:
/// - **1** — collections (identifier, name, kind, creation and change
///   times, members with the time each was added) and usage (last opened).
struct LibraryOrganizationDocument: Codable {

    /// The schema version this build reads and writes.
    static let currentSchemaVersion = 1

    /// Decodes only the version, so a document from a newer build can be
    /// recognised before its contents are interpreted.
    struct VersionEnvelope: Decodable {
        let schemaVersion: Int
    }

    struct StoredMembership: Codable {
        let recordID: String
        let addedAt: Date
    }

    struct StoredCollection: Codable {
        let id: String
        let name: String
        let kind: String
        let createdAt: Date
        let updatedAt: Date
        let members: [StoredMembership]
    }

    struct StoredUsage: Codable {
        let recordID: String
        let lastOpenedAt: Date
    }

    let schemaVersion: Int
    let collections: [StoredCollection]
    let usage: [StoredUsage]

    /// The document for `organization`, in the current schema. Usage is
    /// written in a stable order so an unchanged organization produces an
    /// unchanged file.
    init(_ organization: LibraryOrganization) {
        self.schemaVersion = Self.currentSchemaVersion
        self.collections = organization.collections.map { collection in
            StoredCollection(
                id: collection.id.rawValue,
                name: collection.name,
                kind: collection.kind.rawValue,
                createdAt: collection.createdAt,
                updatedAt: collection.updatedAt,
                members: collection.memberships.map {
                    StoredMembership(recordID: $0.recordID.rawValue, addedAt: $0.addedAt)
                }
            )
        }
        self.usage = organization.lastOpened
            .map { StoredUsage(recordID: $0.key.rawValue, lastOpenedAt: $0.value) }
            .sorted { $0.recordID < $1.recordID }
    }

    /// The organization this document describes. Fails with a typed error
    /// when any value is one the domain rejects: an identifier that is not
    /// one, a name that does not normalise to itself, two collections with
    /// one identifier, two collections of one kind with one name, or a
    /// record listed twice in a collection.
    /// Nothing is dropped or repaired silently.
    func organization() throws -> LibraryOrganization {
        var collections: [LibraryCollection] = []
        var seenIdentifiers: Set<LibraryCollectionIdentifier> = []
        var seenNames: Set<String> = []
        for stored in self.collections {
            guard let id = LibraryCollectionIdentifier(rawValue: stored.id) else {
                throw ZynSignError.libraryOrganizationUnreadable(
                    diagnosticDetail: "A stored collection carries an identifier that is not one."
                )
            }
            guard seenIdentifiers.insert(id).inserted else {
                throw ZynSignError.libraryOrganizationUnreadable(
                    diagnosticDetail: "Collection identifier '\(id.rawValue)' is stored more than once."
                )
            }
            guard LibraryCollection.normalizedName(stored.name) == stored.name else {
                throw ZynSignError.libraryOrganizationUnreadable(
                    diagnosticDetail: "Collection '\(id.rawValue)' carries a name that is empty, too long, or not normalised."
                )
            }
            guard seenNames.insert(stored.kind + "\u{0}" + LibraryCollection.comparableName(stored.name)).inserted else {
                throw ZynSignError.libraryOrganizationUnreadable(
                    diagnosticDetail: "Two stored collections of one kind share one name."
                )
            }
            var members: [LibraryCollectionMembership] = []
            var seenMembers: Set<ApplicationRecordIdentifier> = []
            for storedMember in stored.members {
                guard let recordID = ApplicationRecordIdentifier(rawValue: storedMember.recordID) else {
                    throw ZynSignError.libraryOrganizationUnreadable(
                        diagnosticDetail: "Collection '\(id.rawValue)' lists a member identifier that is not one."
                    )
                }
                guard seenMembers.insert(recordID).inserted else {
                    throw ZynSignError.libraryOrganizationUnreadable(
                        diagnosticDetail: "Collection '\(id.rawValue)' lists record '\(recordID.rawValue)' more than once."
                    )
                }
                members.append(LibraryCollectionMembership(recordID: recordID, addedAt: storedMember.addedAt))
            }
            collections.append(LibraryCollection(
                id: id,
                name: stored.name,
                kind: LibraryCollectionKind(rawValue: stored.kind),
                memberships: members,
                createdAt: stored.createdAt,
                updatedAt: stored.updatedAt
            ))
        }

        var lastOpened: [ApplicationRecordIdentifier: Date] = [:]
        for stored in usage {
            guard let recordID = ApplicationRecordIdentifier(rawValue: stored.recordID) else {
                throw ZynSignError.libraryOrganizationUnreadable(
                    diagnosticDetail: "Usage lists a record identifier that is not one."
                )
            }
            lastOpened[recordID] = stored.lastOpenedAt
        }
        return LibraryOrganization(collections: collections, lastOpened: lastOpened)
    }
}
