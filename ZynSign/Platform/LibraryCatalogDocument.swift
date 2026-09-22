import Foundation

/// The on-disk form of the application library: one document holding every
/// record, in an explicitly versioned schema.
///
/// The document is the storage representation, deliberately separate from
/// the domain's `ApplicationRecord`. The domain model can evolve without the
/// stored form drifting silently, and the stored form is checked on the way
/// back in: every value is validated through the domain's own rules before a
/// record is rehydrated, so a damaged or hand-edited catalog produces a typed
/// failure rather than a record the domain would never have constructed.
///
/// **Schema version 1.** The document is a JSON object with two keys:
/// `schemaVersion`, the integer `1`; and `records`, an array of record
/// objects. Each record object carries string identifiers for the record and
/// its artifact, the declared identity values exactly as declared (absent
/// values are omitted), the executable and source-file names when known, the
/// artifact's byte count and fingerprint (algorithm name plus lowercase
/// hexadecimal digest), the inspection classification and warning codes by
/// their stable raw values, and the two timestamps as seconds since the
/// reference date, stored as numbers so that they round-trip exactly.
///
/// A catalog whose version is newer than `currentSchemaVersion` is refused
/// as unsupported rather than guessed at; a catalog whose version is unknown
/// or whose content this build cannot interpret is refused as unreadable. In
/// both cases the file is left untouched. When the schema next changes, the
/// version is incremented and a conversion from the previous version is
/// added at the read boundary; no conversion exists yet because none is
/// needed.
struct LibraryCatalogDocument: Codable, Equatable {

    /// The schema version this build reads and writes.
    static let currentSchemaVersion = 1

    /// The schema version the document was written in.
    var schemaVersion: Int

    /// The stored records, in library order.
    var records: [StoredApplicationRecord]

    init(records: [StoredApplicationRecord] = [], schemaVersion: Int = LibraryCatalogDocument.currentSchemaVersion) {
        self.schemaVersion = schemaVersion
        self.records = records
    }

    /// The part of a catalog that is read before anything else, so that the
    /// version can be checked before the record shape is assumed.
    struct VersionEnvelope: Decodable {
        let schemaVersion: Int
    }
}

/// The stored form of one `ApplicationRecord`.
struct StoredApplicationRecord: Codable, Equatable {

    var recordID: String
    var bundleIdentifier: String
    var declaredDisplayName: String?
    var declaredBundleName: String?
    var shortVersion: String?
    var buildVersion: String?
    var executableName: String?
    var sourceFileName: String?
    var artifactID: String
    var artifactByteCount: Int
    var fingerprintAlgorithm: String
    var fingerprintDigest: String
    var inspectionClassification: String
    var inspectionWarningCodes: [String]
    var importedAt: Double
    var updatedAt: Double

    /// Captures a domain record for storage.
    init(_ record: ApplicationRecord) {
        recordID = record.id.rawValue
        bundleIdentifier = record.identity.bundleIdentifier.rawValue
        declaredDisplayName = record.identity.declaredDisplayName
        declaredBundleName = record.identity.declaredBundleName
        shortVersion = record.identity.shortVersionString
        buildVersion = record.identity.buildVersion
        executableName = record.executableName
        sourceFileName = record.sourceFileName
        artifactID = record.artifact.artifactID.rawValue
        artifactByteCount = record.artifact.byteCount
        fingerprintAlgorithm = record.artifact.fingerprint.algorithm.rawValue
        fingerprintDigest = record.artifact.fingerprint.hexDigest
        inspectionClassification = record.inspection.classification.rawValue
        inspectionWarningCodes = record.inspection.warningCodes.map { $0.rawValue }
        importedAt = record.importedAt.timeIntervalSinceReferenceDate
        updatedAt = record.updatedAt.timeIntervalSinceReferenceDate
    }

    /// Rehydrates the domain record, validating every stored value through
    /// the domain's own rules. Fails with a typed error naming the offending
    /// field — never echoing its content — when a value cannot be
    /// interpreted.
    func applicationRecord() throws -> ApplicationRecord {
        guard let id = ApplicationRecordIdentifier(rawValue: recordID) else {
            throw Self.unreadable("recordID")
        }
        guard let bundleIdentifier = BundleIdentifier(rawValue: bundleIdentifier) else {
            throw Self.unreadable("bundleIdentifier", recordID: recordID)
        }
        guard let artifactID = ArtifactIdentifier(rawValue: artifactID) else {
            throw Self.unreadable("artifactID", recordID: recordID)
        }
        guard let algorithm = ArtifactFingerprint.Algorithm(rawValue: fingerprintAlgorithm) else {
            throw Self.unreadable("fingerprintAlgorithm", recordID: recordID)
        }
        guard let fingerprint = ArtifactFingerprint(algorithm: algorithm, hexDigest: fingerprintDigest) else {
            throw Self.unreadable("fingerprintDigest", recordID: recordID)
        }
        guard artifactByteCount >= 0 else {
            throw Self.unreadable("artifactByteCount", recordID: recordID)
        }
        guard let classification = ValidationClassification(rawValue: inspectionClassification) else {
            throw Self.unreadable("inspectionClassification", recordID: recordID)
        }
        var warningCodes: [ValidationIssueCode] = []
        for rawCode in inspectionWarningCodes {
            guard let code = ValidationIssueCode(rawValue: rawCode) else {
                throw Self.unreadable("inspectionWarningCodes", recordID: recordID)
            }
            warningCodes.append(code)
        }
        guard importedAt.isFinite, updatedAt.isFinite else {
            throw Self.unreadable("timestamps", recordID: recordID)
        }

        return ApplicationRecord(
            id: id,
            identity: ApplicationIdentity(
                bundleIdentifier: bundleIdentifier,
                declaredDisplayName: declaredDisplayName,
                declaredBundleName: declaredBundleName,
                shortVersionString: shortVersion,
                buildVersion: buildVersion
            ),
            executableName: executableName,
            sourceFileName: sourceFileName,
            artifact: ArtifactReference(
                artifactID: artifactID,
                byteCount: artifactByteCount,
                fingerprint: fingerprint
            ),
            inspection: ApplicationRecord.InspectionSummary(
                classification: classification,
                warningCodes: warningCodes
            ),
            importedAt: Date(timeIntervalSinceReferenceDate: importedAt),
            updatedAt: Date(timeIntervalSinceReferenceDate: updatedAt)
        )
    }

    private static func unreadable(_ field: String, recordID: String? = nil) -> ZynSignError {
        if let recordID {
            return ZynSignError.libraryCatalogUnreadable(
                diagnosticDetail: "The stored record '\(recordID)' carries a '\(field)' value this build cannot interpret."
            )
        }
        return ZynSignError.libraryCatalogUnreadable(
            diagnosticDetail: "A stored record carries a '\(field)' value this build cannot interpret."
        )
    }
}
