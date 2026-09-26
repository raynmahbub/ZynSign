import Foundation

/// The platform implementation of `LibraryOrganizationStore`: one versioned
/// document beside the library catalog, replaced atomically on every save.
///
/// The organization is small — a few collections, their member identifiers,
/// and one timestamp per opened application — so, like the catalog, it is
/// read whole and written whole. It lives in its own file so that opening
/// an application or rearranging collections never rewrites the catalog.
///
/// Behaviour:
///
/// - **Missing is empty.** No document means no collections and no usage.
/// - **Atomic replacement.** The document is written to a temporary file
///   and renamed into place, so an interrupted write cannot leave a
///   truncated document behind.
/// - **Fail closed on damage.** A document that cannot be decoded, records
///   a newer schema, or carries a value the domain rejects makes the read
///   fail with a typed error. The file is never reset or partially loaded.
///
/// The type holds no mutable state; the organizer that owns it caches the
/// value and serialises access. Nothing sensitive is stored: collection
/// names the user typed, record identifiers, and timestamps.
final class FileLibraryOrganizationStore: LibraryOrganizationStore, Sendable {

    /// The location of the document. Its directory is created on the first
    /// save; nothing is created at construction time.
    let documentLocation: URL

    init(documentLocation: URL) {
        self.documentLocation = documentLocation
    }

    // MARK: - LibraryOrganizationStore

    func loadOrganization() throws -> LibraryOrganization {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: documentLocation.path, isDirectory: &isDirectory) else {
            return .empty
        }
        guard !isDirectory.boolValue else {
            throw ZynSignError.libraryOrganizationUnreadable(
                diagnosticDetail: "The organization document location is a directory rather than a file."
            )
        }

        let data: Data
        do {
            data = try Data(contentsOf: documentLocation)
        } catch {
            throw ZynSignError.libraryOrganizationUnreadable(
                diagnosticDetail: "The organization document could not be read.",
                underlyingError: error
            )
        }

        let decoder = JSONDecoder()
        let envelope: LibraryOrganizationDocument.VersionEnvelope
        do {
            envelope = try decoder.decode(LibraryOrganizationDocument.VersionEnvelope.self, from: data)
        } catch {
            throw ZynSignError.libraryOrganizationUnreadable(
                diagnosticDetail: "The organization document is not a document this build recognises.",
                underlyingError: error
            )
        }
        guard envelope.schemaVersion <= LibraryOrganizationDocument.currentSchemaVersion else {
            throw ZynSignError.libraryOrganizationUnsupported(
                diagnosticDetail: "The organization document declares schema version \(envelope.schemaVersion); this build reads up to version \(LibraryOrganizationDocument.currentSchemaVersion)."
            )
        }
        guard envelope.schemaVersion >= 1 else {
            throw ZynSignError.libraryOrganizationUnreadable(
                diagnosticDetail: "The organization document declares schema version \(envelope.schemaVersion), which no build of ZynSign has written."
            )
        }

        let document: LibraryOrganizationDocument
        do {
            document = try decoder.decode(LibraryOrganizationDocument.self, from: data)
        } catch {
            throw ZynSignError.libraryOrganizationUnreadable(
                diagnosticDetail: "The organization document's contents could not be decoded.",
                underlyingError: error
            )
        }
        return try document.organization()
    }

    func saveOrganization(_ organization: LibraryOrganization) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data: Data
        do {
            data = try encoder.encode(LibraryOrganizationDocument(organization))
        } catch {
            throw ZynSignError.libraryOrganizationStorageFailure(
                diagnosticDetail: "The organization document could not be encoded.",
                underlyingError: error
            )
        }

        do {
            try FileManager.default.createDirectory(
                at: documentLocation.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch {
            throw ZynSignError.libraryOrganizationStorageFailure(
                diagnosticDetail: "The library directory could not be created.",
                underlyingError: error
            )
        }

        do {
            try data.write(to: documentLocation, options: [.atomic])
        } catch {
            throw ZynSignError.libraryOrganizationStorageFailure(
                diagnosticDetail: "The organization document could not be written.",
                underlyingError: error
            )
        }
    }
}
