/// How a candidate import relates to the records already in the library.
///
/// Only records sharing the candidate's bundle identifier are related; the
/// relation says how closely. It is reported so that the outcome of an import
/// can be explained, and it never prevents a record from being created — a
/// bundle identifier alone does not identify an artifact, and neither does a
/// declared version.
enum ApplicationRecordRelation: Equatable, Hashable {

    /// No record shares the candidate's bundle identifier.
    case unrelated

    /// Records share the bundle identifier but declare a different version
    /// or build. Listed in library order.
    case otherVersions([ApplicationRecord])

    /// Records share the bundle identifier and declare the same version and
    /// build, yet hold different bytes — a rebuilt or modified package with
    /// unchanged metadata. Listed in library order. Both are kept: the
    /// library never silently replaces one with the other.
    case sameDeclaredVersion([ApplicationRecord])
}

/// ZynSign's policy for recognising an already-imported package.
///
/// The policy is deterministic and pure: given the candidate's content
/// reference, its declared identity, the existing records, and which of
/// those records' artifacts are actually held, it always reaches the same
/// verdict, independent of the order the records arrive in.
///
/// Identity is decided by bytes, never by metadata. A candidate whose
/// fingerprint and size match the artifact of a record whose artifact is
/// held is the same package, whatever it declares, and is not recorded
/// again. A candidate whose bytes differ is a distinct artifact, even when
/// its bundle identifier, version, and build all match an existing record —
/// a rebuilt package is a different package, and pretending otherwise would
/// hide exactly the difference a user might need to see. Such a candidate is
/// recorded, with the relation reported so the outcome can be explained.
///
/// A record whose artifact is missing or inconsistent does not hold its
/// content, so it cannot make a candidate a duplicate: importing the same
/// bytes again produces a new record with its own artifact, and the record
/// whose artifact went missing is kept, and related, rather than repaired
/// behind the user's back. Relations consider every record, held or not.
///
/// Byte identity is all the fingerprint contributes. The policy makes no
/// authenticity or trust claim about any artifact, matching or not.
enum ApplicationRecordDuplicatePolicy {

    /// The policy's decision for one candidate.
    enum Verdict: Equatable, Hashable {

        /// A record already holds byte-identical content. No new record is
        /// created; the existing record — the earliest in library order if
        /// several match — is the one to report.
        case identical(existing: ApplicationRecord)

        /// The candidate holds content no record has. A new record is
        /// created; the relation describes any records that share its
        /// bundle identifier.
        case distinct(ApplicationRecordRelation)

        /// Whether the verdict permits creating a record for the candidate.
        var permitsNewRecord: Bool {
            if case .identical = self {
                return false
            }
            return true
        }
    }

    /// Evaluates a candidate against the existing records.
    ///
    /// `isHeld` reports whether a record's artifact is currently held as
    /// recorded; only held records can make the candidate a duplicate. The
    /// default treats every record as held, which is the pure comparison of
    /// references with no storage in the picture.
    ///
    /// `allowingDuplicateContent` skips the byte-identity check entirely, so
    /// a candidate the library already holds is treated as a distinct
    /// artifact and every record sharing its bundle identifier is related
    /// instead. It exists for the one case where the answer is "store it
    /// anyway" — a user who was shown the duplicate and chose to keep both.
    static func evaluate(
        candidate: ArtifactReference,
        identity: ApplicationIdentity,
        against records: [ApplicationRecord],
        holding isHeld: (ApplicationRecord) -> Bool = { _ in true },
        allowingDuplicateContent: Bool = false
    ) -> Verdict {
        let ordered = records.sorted(by: ApplicationRecord.libraryOrder)

        if !allowingDuplicateContent,
           let identical = ordered.first(where: { isHeld($0) && $0.artifact.describesSameContent(as: candidate) }) {
            return .identical(existing: identical)
        }

        let sameApplication = ordered.filter { $0.identity.bundleIdentifier == identity.bundleIdentifier }
        guard !sameApplication.isEmpty else {
            return .distinct(.unrelated)
        }

        let sameVersion = sameApplication.filter { $0.identity.declaresSameVersion(as: identity) }
        if !sameVersion.isEmpty {
            return .distinct(.sameDeclaredVersion(sameVersion))
        }
        return .distinct(.otherVersions(sameApplication))
    }
}

extension ApplicationIdentity {

    /// Whether two identities declare the same application version: the
    /// same bundle identifier, the same marketing version, and the same
    /// build version, compared exactly as declared. Two undeclared values
    /// count as the same.
    func declaresSameVersion(as other: ApplicationIdentity) -> Bool {
        bundleIdentifier == other.bundleIdentifier
            && shortVersionString == other.shortVersionString
            && buildVersion == other.buildVersion
    }
}
