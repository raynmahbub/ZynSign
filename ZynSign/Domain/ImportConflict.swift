import Foundation

/// What the user chose to do about an incoming package that relates to an
/// application already in the library.
///
/// The raw values are persisted nowhere today, but they name the choice in
/// diagnostics and must stay stable.
enum ConflictResolution: String, CaseIterable, Hashable, Sendable, Codable {

    /// Add the incoming package and keep every existing entry.
    case keepBoth

    /// Add the incoming package, then remove the existing entries the
    /// conflict listed. The new entry is always stored first, so a failure
    /// can never leave the library with neither.
    case replaceExisting

    /// Store nothing for the incoming package. Its working copy is
    /// discarded; the file the user chose is not changed.
    case skip

    /// The label on the choice.
    var displayName: String {
        switch self {
        case .keepBoth: return "Keep Both"
        case .replaceExisting: return "Replace Existing"
        case .skip: return "Skip"
        }
    }

    /// A one-line statement of what the choice will do.
    var explanation: String {
        switch self {
        case .keepBoth:
            return "Add this package and keep what is already in the library."
        case .replaceExisting:
            return "Add this package, then remove the library entries it conflicts with."
        case .skip:
            return "Don't import this package. Nothing in the library changes."
        }
    }

    /// The SF Symbol shown beside the choice.
    var symbolName: String {
        switch self {
        case .keepBoth: return "plus.square.on.square"
        case .replaceExisting: return "arrow.triangle.2.circlepath"
        case .skip: return "arrow.uturn.forward"
        }
    }

    /// Whether the choice removes anything from the library.
    var isDestructive: Bool {
        self == .replaceExisting
    }
}

/// An incoming package that shares its bundle identifier with one or more
/// applications already in the library, and what the Import Hub's rules
/// make of that.
///
/// A conflict is a *question*, never an action. It carries a suggestion
/// when the rules can make one, but nothing is stored, kept, or removed
/// until the user has chosen a `ConflictResolution` for it — the Import Hub
/// never overwrites a library entry silently.
struct ImportConflict: Equatable, Hashable, Sendable {

    /// How the incoming package relates to the library entry it is
    /// compared with.
    enum Relation: Equatable, Hashable, Sendable {

        /// The library already holds these exact bytes.
        case identicalContent

        /// The same declared version and build, but different bytes — a
        /// rebuild, a re-signed copy, or a modified package.
        case sameVersion

        /// The incoming package declares a newer version than every
        /// existing entry for the application.
        case newerVersion

        /// The incoming package declares an older version than the newest
        /// existing entry.
        case olderVersion

        /// The declared versions cannot be ordered (for example, one side
        /// declares none).
        case undeterminedVersion
    }

    /// The identity the incoming package declares.
    let incomingIdentity: ApplicationIdentity

    /// The size of the incoming package's working copy, in bytes.
    let incomingByteCount: Int

    /// Every library entry with the same bundle identifier, oldest first.
    /// These — and only these — are what “Replace Existing” removes.
    let existingRecords: [ApplicationRecord]

    /// The single existing entry the comparison is shown against: the
    /// identical one, the one declaring the same version, or otherwise the
    /// newest declared version.
    let comparedRecord: ApplicationRecord

    /// How the incoming package relates to `comparedRecord`.
    let relation: Relation

    /// The resolution the rules suggest, or `nil` when the user has to
    /// decide unaided. A suggestion is only ever applied by an explicit
    /// user action.
    let suggestion: ConflictResolution?

    /// The resolutions offered for this conflict. Every conflict offers all
    /// three; the order is the order they are presented in.
    var offeredResolutions: [ConflictResolution] {
        ConflictResolution.allCases
    }
}

/// The Import Hub's smart import rules.
///
/// | Incoming vs library                        | Outcome                         |
/// |--------------------------------------------|---------------------------------|
/// | No entry with the bundle identifier        | No conflict — import            |
/// | Byte-identical entry exists                | Conflict, suggest Skip          |
/// | Same version and build, different bytes    | Conflict, no suggestion (ask)   |
/// | Newer than every existing version          | Conflict, suggest Replace       |
/// | Older than the newest existing version     | Conflict, suggest Keep Both     |
/// | Versions cannot be ordered                 | Conflict, no suggestion (ask)   |
///
/// A corrupted archive or an unsupported layout never reaches these rules:
/// it is refused, with an explanation, before any comparison is made.
enum ImportRules {

    /// The conflict an incoming package raises against the library, or
    /// `nil` when the library holds no application with its bundle
    /// identifier.
    static func conflict(
        for report: DuplicateReport,
        incoming identity: ApplicationIdentity
    ) -> ImportConflict? {
        guard !report.matches.isEmpty else { return nil }
        let existing = report.matches.map(\.record).sorted(by: ApplicationRecord.libraryOrder)

        let compared: ApplicationRecord
        let relation: ImportConflict.Relation

        if let identical = report.matches.first(where: { $0.kind == .identicalContent }) {
            compared = identical.record
            relation = .identicalContent
        } else if let sameVersion = report.matches.first(where: { $0.kind == .sameVersionAndBuild }) {
            compared = sameVersion.record
            relation = .sameVersion
        } else {
            let newest = newestDeclaredVersion(in: existing)
            compared = newest
            switch DeclaredVersionOrder.compare(
                version: identity.shortVersionString,
                build: identity.buildVersion,
                with: newest.identity.shortVersionString,
                build: newest.identity.buildVersion
            ) {
            case .some(.orderedDescending):
                relation = .newerVersion
            case .some(.orderedAscending):
                relation = .olderVersion
            case .some(.orderedSame):
                // Declarations that read the same once normalized (`1.2`
                // and `1.2.0`) but were not byte-for-byte equal.
                relation = .sameVersion
            case .none:
                relation = .undeterminedVersion
            }
        }

        return ImportConflict(
            incomingIdentity: identity,
            incomingByteCount: report.candidateByteCount,
            existingRecords: existing,
            comparedRecord: compared,
            relation: relation,
            suggestion: suggestion(for: relation)
        )
    }

    /// The resolution the rules suggest for a relation, if any.
    static func suggestion(for relation: ImportConflict.Relation) -> ConflictResolution? {
        switch relation {
        case .identicalContent: return .skip
        case .newerVersion: return .replaceExisting
        case .olderVersion: return .keepBoth
        case .sameVersion, .undeterminedVersion: return nil
        }
    }

    /// The existing entry with the newest declared version. Entries whose
    /// versions cannot be ordered against each other fall back to the most
    /// recently imported, so the choice is always deterministic.
    private static func newestDeclaredVersion(in records: [ApplicationRecord]) -> ApplicationRecord {
        // `records` is oldest first and never empty here.
        var newest = records[records.count - 1]
        for candidate in records.reversed().dropFirst() {
            let order = DeclaredVersionOrder.compare(
                version: candidate.identity.shortVersionString,
                build: candidate.identity.buildVersion,
                with: newest.identity.shortVersionString,
                build: newest.identity.buildVersion
            )
            if order == .orderedDescending {
                newest = candidate
            }
        }
        return newest
    }
}
