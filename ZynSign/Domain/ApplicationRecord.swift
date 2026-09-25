import Foundation

/// One application in ZynSign's library: the durable record of an accepted
/// import.
///
/// A record holds only what belongs in long-lived library storage — the
/// identity and metadata the package declared, a reference to the artifact
/// ZynSign keeps for it, what inspection concluded when it was imported, and
/// when it arrived. It holds no bytes, no archive handles, no storage
/// locations, and no runtime objects: the transient `IPAArtifact` an import
/// produces is the input a record is made from, never the thing that is
/// stored.
///
/// A record exists only for a package that passed inspection. The admitting
/// initialiser enforces that, so the presence of a record states that the
/// package's structure and declared metadata satisfied ZynSign's rules at
/// import time. It states nothing beyond that: the metadata is what the
/// package declared and remains untrusted, the fingerprint identifies bytes
/// and nothing else, and no record is evidence that an application is
/// signed, genuine, trusted, or installable.
///
/// Records are values. Every change produces a new value with the same
/// identifier; the persistence boundary decides whether a value replaces an
/// existing record or creates a new one, keyed on `id` alone.
struct ApplicationRecord: Equatable, Hashable, Sendable {

    /// What inspection concluded about the package when it was imported.
    ///
    /// The classification and the codes of any non-rejecting findings are
    /// kept; finding details are diagnostics, not library data, and are not
    /// persisted. For a record created through the admitting initialiser the
    /// classification is always `valid`, because nothing else is admitted.
    struct InspectionSummary: Equatable, Hashable, Sendable {

        /// The classification inspection assigned.
        let classification: ValidationClassification

        /// The codes of the non-rejecting findings, in examination order.
        let warningCodes: [ValidationIssueCode]

        /// Records a summary directly.
        init(classification: ValidationClassification, warningCodes: [ValidationIssueCode] = []) {
            self.classification = classification
            self.warningCodes = warningCodes
        }

        /// Summarises a validation outcome.
        init(validation: ValidationResult) {
            self.classification = validation.classification
            self.warningCodes = validation.warnings.map { $0.code }
        }
    }

    /// The record's own stable identity.
    let id: ApplicationRecordIdentifier

    /// The identity the package's application declared: bundle identifier,
    /// declared names, and declared versions. Untrusted metadata, preserved
    /// as declared.
    let identity: ApplicationIdentity

    /// The executable name the application declared, or `nil` when it
    /// declared none. A declaration only, like the rest of the identity.
    let executableName: String?

    /// The provenance label captured at import — the selected file's name —
    /// when one was available. Display and diagnostics only; never a path.
    let sourceFileName: String?

    /// The reference to the artifact ZynSign holds for this record.
    let artifact: ArtifactReference

    /// What inspection concluded at import time.
    let inspection: InspectionSummary

    /// When the record was created.
    let importedAt: Date

    /// When the record last changed. Equal to `importedAt` until the record
    /// is updated.
    let updatedAt: Date

    /// Whether the user has marked this application as a favourite.
    ///
    /// A user preference the library keeps with the record so it has one
    /// durable home. It is a display concern only: it changes nothing about
    /// admission, identity, or the artifact, and a favourite mark is never
    /// a statement about the package itself.
    let isFavorite: Bool

    /// Records a library entry from its stored parts. Used when a persisted
    /// record is rehydrated and when an existing record is revised; a new
    /// entry for an import goes through `init(admitting:reference:importedAt:id:)`.
    init(
        id: ApplicationRecordIdentifier,
        identity: ApplicationIdentity,
        executableName: String?,
        sourceFileName: String?,
        artifact: ArtifactReference,
        inspection: InspectionSummary,
        importedAt: Date,
        updatedAt: Date,
        isFavorite: Bool = false
    ) {
        self.id = id
        self.identity = identity
        self.executableName = executableName
        self.sourceFileName = sourceFileName
        self.artifact = artifact
        self.inspection = inspection
        self.importedAt = importedAt
        self.updatedAt = updatedAt
        self.isFavorite = isFavorite
    }

    /// Creates the record for an accepted import.
    ///
    /// Only an examined artifact whose classification permits later stages
    /// and which carries declared metadata can become a record; anything
    /// else fails with a typed error rather than producing a record for a
    /// package the library must not hold. The reference must name the same
    /// artifact the import produced.
    init(
        admitting artifact: IPAArtifact,
        reference: ArtifactReference,
        importedAt: Date,
        id: ApplicationRecordIdentifier = ApplicationRecordIdentifier()
    ) throws {
        guard let validation = artifact.validation, validation.classification.permitsLaterStages else {
            throw ZynSignError.unrecordableArtifact(
                diagnosticDetail: "Artifact '\(artifact.id.rawValue)' has not passed inspection and cannot become a library record."
            )
        }
        guard let metadata = artifact.metadata else {
            throw ZynSignError.unrecordableArtifact(
                diagnosticDetail: "Artifact '\(artifact.id.rawValue)' carries no declared metadata and cannot become a library record."
            )
        }
        guard reference.artifactID == artifact.id else {
            throw ZynSignError.unrecordableArtifact(
                diagnosticDetail: "The artifact reference names '\(reference.artifactID.rawValue)' but the import produced '\(artifact.id.rawValue)'."
            )
        }
        self.init(
            id: id,
            identity: metadata.identity,
            executableName: metadata.executableName,
            sourceFileName: artifact.sourceFileName,
            artifact: reference,
            inspection: InspectionSummary(validation: validation),
            importedAt: importedAt,
            updatedAt: importedAt
        )
    }

    /// The declared bundle identifier.
    var bundleIdentifier: BundleIdentifier {
        identity.bundleIdentifier
    }

    /// The display name after the identity's deterministic fallback policy,
    /// or `nil` when the package declared no usable name.
    var displayName: String? {
        identity.displayName
    }

    /// The deterministic order records are listed in: by import time, with
    /// ties broken by identifier so that two records imported in the same
    /// instant still list the same way every time.
    static func libraryOrder(_ lhs: ApplicationRecord, _ rhs: ApplicationRecord) -> Bool {
        if lhs.importedAt != rhs.importedAt {
            return lhs.importedAt < rhs.importedAt
        }
        return lhs.id.rawValue < rhs.id.rawValue
    }

    /// Returns a copy of the record with the favourite mark set, keeping the
    /// identifier, identity, artifact, and import time untouched. The caller
    /// supplies the change time, because only the use case that decides a
    /// change happened knows when it happened.
    func with(isFavorite: Bool, updatedAt: Date) -> ApplicationRecord {
        ApplicationRecord(
            id: id,
            identity: identity,
            executableName: executableName,
            sourceFileName: sourceFileName,
            artifact: artifact,
            inspection: inspection,
            importedAt: importedAt,
            updatedAt: updatedAt,
            isFavorite: isFavorite
        )
    }
}
