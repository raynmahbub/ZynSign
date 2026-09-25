import Foundation

/// The file-backed implementation of `IdentityAnnotationsStore`: a versioned
/// catalog document in the user's container, replaced atomically on every
/// change.
///
/// Behaviour mirrors `FileSigningPresetStore`:
/// - **Lazy, cached load.** The catalog is read on the first operation and
///   kept in memory; every mutation writes the whole catalog and updates
///   the cache only after the write succeeded.
/// - **Atomic replacement.** The catalog is written to a temporary file and
///   renamed into place.
/// - **Fail closed on damage.** A catalog that cannot be decoded, that
///   declares an unsupported schema, or that records a value the annotation
///   boundary refuses is left in place and reported as unreadable; nothing
///   is reset or partially loaded.
///
/// The catalog contents are pure display values — user-chosen labels, import
/// dates, and a default mark keyed by public certificate fingerprints — and
/// hold no secrets. A default that no longer names a recorded annotation is
/// dropped on read: it is stale state, and keeping it would let a removed
/// identity stay "default" forever.
final class FileIdentityAnnotationsStore: IdentityAnnotationsStore, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {

    /// The schema version this build reads and writes.
    static let currentSchemaVersion = 1

    /// The location of the catalog file.
    let catalogLocation: URL

    /// The annotations as last read from or written to the catalog, keyed by
    /// fingerprint, once the catalog has been loaded.
    private var loaded: (annotations: [String: IdentityAnnotation], defaultFingerprint: String?)?

    /// Serialises catalog access. The store is a synchronous port, so every
    /// operation is short, but read-modify-write still must not interleave
    /// with itself.
    private let access = NSLock()

    init(catalogLocation: URL) {
        self.catalogLocation = catalogLocation
    }

    // MARK: - IdentityAnnotationsStore

    func annotations() throws -> [String: IdentityAnnotation] {
        access.lock()
        defer { access.unlock() }
        return try loadedOrRead().annotations
    }

    func setAnnotation(
        _ annotation: IdentityAnnotation,
        forFingerprint fingerprint: String
    ) throws {
        try Self.validateFingerprint(fingerprint)
        guard annotation.hasValidLabelLength else {
            throw ZynSignError.identityAnnotationsStorageFailure(
                diagnosticDetail: "A display label longer than the catalog boundary was offered."
            )
        }
        access.lock()
        defer { access.unlock() }
        var state = try loadedOrRead()
        state.annotations[fingerprint] = annotation
        try persist(state)
    }

    func removeAnnotation(forFingerprint fingerprint: String) throws {
        try Self.validateFingerprint(fingerprint)
        access.lock()
        defer { access.unlock() }
        var state = try loadedOrRead()
        state.annotations[fingerprint] = nil
        try persist(state)
    }

    func defaultIdentityFingerprint() throws -> String? {
        access.lock()
        defer { access.unlock() }
        return try loadedOrRead().defaultFingerprint
    }

    func setDefaultIdentityFingerprint(_ fingerprint: String?) throws {
        access.lock()
        defer { access.unlock() }
        var state = try loadedOrRead()
        if let fingerprint {
            try Self.validateFingerprint(fingerprint)
            // A default must name a recorded annotation, because a cold read
            // drops a default that names nothing. When the identity carries
            // no annotation yet, an empty one is recorded so the default
            // survives a relaunch.
            if state.annotations[fingerprint] == nil {
                state.annotations[fingerprint] = IdentityAnnotation()
            }
        }
        state.defaultFingerprint = fingerprint
        try persist(state)
    }

    // MARK: - Storage helpers

    private static func validateFingerprint(_ fingerprint: String) throws {
        guard CertificateFingerprint(hexDigest: fingerprint) != nil else {
            throw ZynSignError.identityAnnotationsStorageFailure(
                diagnosticDetail: "An annotation was offered for a value that is not a certificate fingerprint."
            )
        }
    }

    private func loadedOrRead() throws -> (annotations: [String: IdentityAnnotation], defaultFingerprint: String?) {
        if let loaded { return loaded }
        let state = try Self.readCatalog(at: catalogLocation)
        loaded = state
        return state
    }

    private func persist(_ state: (annotations: [String: IdentityAnnotation], defaultFingerprint: String?)) throws {
        try Self.writeCatalog(
            annotations: state.annotations,
            defaultFingerprint: state.defaultFingerprint,
            to: catalogLocation
        )
        loaded = state
    }

    private struct Envelope: Codable {
        var schemaVersion: Int
        var defaultFingerprint: String?
        var annotations: [String: IdentityAnnotation]
    }

    static func readCatalog(at location: URL) throws
        -> (annotations: [String: IdentityAnnotation], defaultFingerprint: String?) {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: location.path, isDirectory: &isDirectory) else {
            return ([], nil)
        }
        guard !isDirectory.boolValue else {
            throw ZynSignError.identityAnnotationsStorageFailure(
                diagnosticDetail: "The annotation catalog location is a directory rather than a file."
            )
        }
        let data: Data
        do {
            data = try Data(contentsOf: location)
        } catch {
            throw ZynSignError.identityAnnotationsStorageFailure(
                diagnosticDetail: "The annotation catalog could not be read.",
                underlyingError: error
            )
        }
        let envelope: Envelope
        do {
            envelope = try JSONDecoder().decode(Envelope.self, from: data)
        } catch {
            throw ZynSignError.identityAnnotationsUnreadable(
                diagnosticDetail: "The annotation catalog is not a catalog document this build recognises.",
                underlyingError: error
            )
        }
        guard envelope.schemaVersion <= currentSchemaVersion else {
            throw ZynSignError.identityAnnotationsUnreadable(
                diagnosticDetail: "The annotation catalog declares schema version \(envelope.schemaVersion); this build reads up to version \(currentSchemaVersion)."
            )
        }
        var annotations: [String: IdentityAnnotation] = [:]
        for (fingerprint, annotation) in envelope.annotations {
            guard CertificateFingerprint(hexDigest: fingerprint) != nil,
                  annotation.hasValidLabelLength else {
                throw ZynSignError.identityAnnotationsUnreadable(
                    diagnosticDetail: "The annotation catalog records a value outside the annotation boundary."
                )
            }
            annotations[fingerprint] = annotation
        }
        // A default that names no recorded annotation is stale, not damage:
        // drop it so a removed identity cannot remain "default".
        let defaultFingerprint: String?
        if let candidate = envelope.defaultFingerprint {
            defaultFingerprint = annotations[candidate] == nil ? nil : candidate
        } else {
            defaultFingerprint = nil
        }
        return (annotations, defaultFingerprint)
    }

    static func writeCatalog(
        annotations: [String: IdentityAnnotation],
        defaultFingerprint: String?,
        to location: URL
    ) throws {
        let envelope = Envelope(
            schemaVersion: currentSchemaVersion,
            defaultFingerprint: defaultFingerprint,
            annotations: annotations
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data: Data
        do {
            data = try encoder.encode(envelope)
        } catch {
            throw ZynSignError.identityAnnotationsStorageFailure(
                diagnosticDetail: "The annotation catalog could not be encoded.",
                underlyingError: error
            )
        }
        do {
            try FileManager.default.createDirectory(
                at: location.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch {
            throw ZynSignError.identityAnnotationsStorageFailure(
                diagnosticDetail: "The annotation catalog directory could not be created.",
                underlyingError: error
            )
        }
        do {
            try data.write(to: location, options: [.atomic])
        } catch {
            throw ZynSignError.identityAnnotationsStorageFailure(
                diagnosticDetail: "The annotation catalog could not be written.",
                underlyingError: error
            )
        }
    }

    var description: String { "FileIdentityAnnotationsStore(redacted)" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: [:]) }
}
