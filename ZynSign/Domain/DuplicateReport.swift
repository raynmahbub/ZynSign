import Foundation

/// One reason an import relates to a record the library already holds.
///
/// Evidence is factual: each case states something observed about the
/// candidate and the existing record — the same declared bundle identifier,
/// the same declared version, the same declared build, or byte-identical
/// content. Listing the evidence separately, rather than collapsing it into a
/// verdict, is what lets the interface say precisely why two packages are
/// considered related: an application can be re-imported with the same
/// version and a different build, or with identical metadata and rebuilt
/// bytes, and those are different situations with different sensible answers.
///
/// None of this is a trust statement. Matching bytes mean the same bytes, not
/// a genuine or safe package.
enum DuplicateEvidence: Equatable, Hashable, Sendable {

    /// Both declare the same bundle identifier.
    case bundleIdentifier(BundleIdentifier)

    /// Both declare the same marketing version.
    case marketingVersion(String)

    /// Neither declares a marketing version.
    case undeclaredMarketingVersion

    /// Both declare the same build version.
    case buildNumber(String)

    /// Neither declares a build version.
    case undeclaredBuildNumber

    /// The library holds byte-identical content for the existing record.
    case contentFingerprint(ArtifactFingerprint)

    /// The label shown beside the evidence.
    var label: String {
        switch self {
        case .bundleIdentifier: return "Bundle ID"
        case .marketingVersion, .undeclaredMarketingVersion: return "Version"
        case .buildNumber, .undeclaredBuildNumber: return "Build"
        case .contentFingerprint: return "File hash"
        }
    }

    /// The observed value, rendered for display. A fingerprint is abbreviated
    /// because a full digest is not readable by a person; the abbreviation is
    /// honest about being one.
    var value: String {
        switch self {
        case .bundleIdentifier(let identifier): return identifier.rawValue
        case .marketingVersion(let version): return version
        case .undeclaredMarketingVersion: return "not declared"
        case .buildNumber(let build): return build
        case .undeclaredBuildNumber: return "not declared"
        case .contentFingerprint(let fingerprint): return Self.abbreviated(fingerprint)
        }
    }

    /// The SF Symbol shown beside the evidence.
    var symbolName: String {
        switch self {
        case .bundleIdentifier: return "app.badge"
        case .marketingVersion, .undeclaredMarketingVersion: return "number"
        case .buildNumber, .undeclaredBuildNumber: return "hammer"
        case .contentFingerprint: return "number.square"
        }
    }

    /// The leading characters of a digest, which is what a person can compare
    /// at a glance. Never presented as the whole digest.
    private static func abbreviated(_ fingerprint: ArtifactFingerprint) -> String {
        let prefix = fingerprint.hexDigest.prefix(12)
        return "\(fingerprint.algorithm.rawValue) · \(prefix)…"
    }
}

/// How closely one existing record relates to an import.
enum DuplicateMatchKind: Equatable, Hashable, Sendable {

    /// The library holds byte-identical content. Importing it again would
    /// store the same bytes twice.
    case identicalContent

    /// The same application declaring the same version and build, with
    /// different bytes — a rebuilt or modified package whose declared
    /// version was not changed.
    case sameVersionAndBuild

    /// The same application declaring a different version or build. The
    /// library keeps every version, so this is information rather than a
    /// collision.
    case otherVersion

    /// Whether this kind of match is a collision the user should decide
    /// about. Version and build were used deliberately to find an application
    /// again, so a differing version is not a conflict; identical content and
    /// an unchanged version are.
    var requiresDecision: Bool {
        switch self {
        case .identicalContent, .sameVersionAndBuild: return true
        case .otherVersion: return false
        }
    }

    /// The user-presentable name of the match.
    var displayName: String {
        switch self {
        case .identicalContent: return "Same package"
        case .sameVersionAndBuild: return "Same version"
        case .otherVersion: return "Other version"
        }
    }

    /// The SF Symbol shown beside the match.
    var symbolName: String {
        switch self {
        case .identicalContent: return "equal.circle"
        case .sameVersionAndBuild: return "arrow.triangle.2.circlepath"
        case .otherVersion: return "clock.arrow.circlepath"
        }
    }
}

/// One record the library holds that relates to an import, with the evidence
/// for the relation.
struct DuplicateMatch: Equatable, Hashable, Sendable {

    /// The record the library already holds.
    let record: ApplicationRecord

    /// How closely it relates.
    let kind: DuplicateMatchKind

    /// The observations behind the relation, in a fixed order: identity
    /// first, then version, then build, then content.
    let evidence: [DuplicateEvidence]
}

/// What ZynSign found when it compared one candidate package against the
/// library, together with what the user can decide about it.
///
/// The report is produced before anything is committed, from the staged
/// archive's own reference — so the duplicate question is answered without
/// the library being touched at all. It is a statement of fact plus a set of
/// offered answers; it decides nothing by itself.
struct DuplicateReport: Equatable, Hashable, Sendable {

    /// The candidate's declared bundle identifier.
    let candidateBundleIdentifier: BundleIdentifier

    /// The candidate's declared marketing version, when it declares one.
    let candidateMarketingVersion: String?

    /// The candidate's declared build version, when it declares one.
    let candidateBuildVersion: String?

    /// The candidate's size, as measured from the staged copy.
    let candidateByteCount: Int

    /// The candidate's content fingerprint, as computed from the staged copy.
    let candidateFingerprint: ArtifactFingerprint

    /// Every record the library holds that relates to the candidate, in
    /// library order.
    let matches: [DuplicateMatch]

    /// Whether any match is a collision the user should decide about.
    var requiresDecision: Bool {
        matches.contains { $0.kind.requiresDecision }
    }

    /// The matches a decision concerns — identical content, or the same
    /// declared version and build. These, and only these, are the records a
    /// replacement would stand in for.
    var decisiveMatches: [DuplicateMatch] {
        matches.filter { $0.kind.requiresDecision }
    }

    /// The match most worth reporting first: the closest relation, or the
    /// earliest record when nothing collides.
    var strongestMatch: DuplicateMatch? {
        decisiveMatches.first ?? matches.first
    }

    /// The answers ZynSign offers for this report, in the order they are
    /// presented. Every report offers every answer: cancelling is always
    /// possible, keeping both is always possible, and replacing is only
    /// meaningful when there is something to replace — for a report with no
    /// decisive match the interface presents the answers it needs and no
    /// more.
    var offeredResolutions: [DuplicateResolution] {
        requiresDecision
            ? [.keepBoth, .replaceExisting, .cancel]
            : [.keepBoth, .cancel]
    }
}

/// What the user decided about a package the library appears to hold already.
enum DuplicateResolution: String, CaseIterable, Hashable, Sendable {

    /// Store this import as a further library entry, leaving every existing
    /// record exactly where it is.
    case keepBoth

    /// Store this import and remove the entries the decision concerns. The
    /// new entry is stored *before* anything is removed, so a failure part
    /// way through leaves the library holding more than the user asked for
    /// rather than less.
    case replaceExisting

    /// Store nothing. The staged copy is discarded and the original file is
    /// left alone.
    case cancel

    /// The button title for the answer.
    var displayName: String {
        switch self {
        case .keepBoth: return "Keep Both"
        case .replaceExisting: return "Replace Existing"
        case .cancel: return "Cancel Import"
        }
    }

    /// The sentence explaining what the answer does.
    var explanation: String {
        switch self {
        case .keepBoth:
            return "Keep this import and every entry already in the library."
        case .replaceExisting:
            return "Add this import, then remove the entries it matches."
        case .cancel:
            return "Store nothing. The file you chose is not changed."
        }
    }

    /// The SF Symbol shown on the answer.
    var symbolName: String {
        switch self {
        case .keepBoth: return "plus.square.on.square"
        case .replaceExisting: return "arrow.triangle.2.circlepath"
        case .cancel: return "xmark.circle"
        }
    }

    /// Whether choosing this answer removes records the library holds.
    var isDestructive: Bool {
        self == .replaceExisting
    }
}

/// The duplicate-detection policy: how a candidate package is compared with
/// the records the library already holds.
///
/// The policy is pure and deterministic. Given the candidate's declared
/// identity, its measured content reference, the records, and which of those
/// records' artifacts are actually held, it always reaches the same report,
/// whatever order the records arrive in.
///
/// It checks exactly the four things a person checks when they wonder whether
/// they already have a package: the bundle identifier, the declared version,
/// the declared build, and — where the bytes are held and can be read — the
/// file hash. Identity is never decided by declared metadata alone: two
/// packages can declare the same version and hold different bytes, which the
/// report states rather than resolves.
///
/// A record whose artifact is missing or unreadable cannot be claimed as
/// byte-identical, because the library cannot read the bytes it would be
/// claiming. Such a record still relates by bundle identifier and version,
/// and is reported as relating.
enum DuplicateDetection {

    /// Compares a candidate against the records the library holds.
    ///
    /// - Parameters:
    ///   - identity: the candidate's declared identity, as read from the
    ///     staged package.
    ///   - reference: the candidate's measured content reference — its size
    ///     and content fingerprint, computed from the staged copy.
    ///   - records: every record the library holds, in any order.
    ///   - isHeld: whether a record's artifact is currently held as
    ///     recorded. The default treats every record as held, which is the
    ///     pure comparison with no storage in the picture.
    static func report(
        identity: ApplicationIdentity,
        reference: ArtifactReference,
        against records: [ApplicationRecord],
        holding isHeld: (ApplicationRecord) -> Bool = { _ in true }
    ) -> DuplicateReport {
        let ordered = records.sorted(by: ApplicationRecord.libraryOrder)

        let matches: [DuplicateMatch] = ordered.compactMap { record in
            guard record.identity.bundleIdentifier == identity.bundleIdentifier else {
                return nil
            }

            var evidence: [DuplicateEvidence] = [.bundleIdentifier(identity.bundleIdentifier)]
            evidence.append(contentsOf: Self.versionEvidence(candidate: identity, existing: record.identity))
            evidence.append(contentsOf: Self.buildEvidence(candidate: identity, existing: record.identity))

            let holdsIdenticalBytes = isHeld(record)
                && record.artifact.describesSameContent(as: reference)
            if holdsIdenticalBytes {
                evidence.append(.contentFingerprint(reference.fingerprint))
            }

            let kind: DuplicateMatchKind
            if holdsIdenticalBytes {
                kind = .identicalContent
            } else if identity.declaresSameVersion(as: record.identity) {
                kind = .sameVersionAndBuild
            } else {
                kind = .otherVersion
            }

            return DuplicateMatch(record: record, kind: kind, evidence: evidence)
        }

        return DuplicateReport(
            candidateBundleIdentifier: identity.bundleIdentifier,
            candidateMarketingVersion: identity.shortVersionString,
            candidateBuildVersion: identity.buildVersion,
            candidateByteCount: reference.byteCount,
            candidateFingerprint: reference.fingerprint,
            matches: matches
        )
    }

    /// The version evidence for one pair: the shared declared version, or the
    /// observation that neither declares one. A pair that declares different
    /// versions contributes nothing, which is what makes the difference
    /// visible in the evidence list.
    private static func versionEvidence(
        candidate: ApplicationIdentity,
        existing: ApplicationIdentity
    ) -> [DuplicateEvidence] {
        switch (candidate.shortVersionString, existing.shortVersionString) {
        case let (candidate?, existing?) where candidate == existing:
            return [.marketingVersion(candidate)]
        case (nil, nil):
            return [.undeclaredMarketingVersion]
        default:
            return []
        }
    }

    /// The build evidence for one pair, on the same rule as the version.
    private static func buildEvidence(
        candidate: ApplicationIdentity,
        existing: ApplicationIdentity
    ) -> [DuplicateEvidence] {
        switch (candidate.buildVersion, existing.buildVersion) {
        case let (candidate?, existing?) where candidate == existing:
            return [.buildNumber(candidate)]
        case (nil, nil):
            return [.undeclaredBuildNumber]
        default:
            return []
        }
    }
}

/// What ZynSign found about an import's relation to the library, and what was
/// done about it.
///
/// The report is always present when a candidate related to something the
/// library holds. The resolution is present only when the user was asked, so
/// "the library's own policy kept both" and "the user chose to keep both" stay
/// distinguishable facts.
struct DuplicateOutcome: Equatable, Hashable, Sendable {

    /// The comparison that was made.
    let report: DuplicateReport

    /// The decision that was applied, or `nil` when the library's own
    /// duplicate policy decided without asking.
    let resolution: DuplicateResolution?

    /// The records a replacement actually removed, in library order.
    let replacedRecords: [ApplicationRecord]

    /// The records the decision concerned but could not remove. Reported
    /// rather than hidden: the import succeeded and the earlier entries
    /// remain, which is more than the user asked for and less than a silent
    /// loss.
    let retainedRecords: [ApplicationRecord]

    /// Records an outcome.
    init(
        report: DuplicateReport,
        resolution: DuplicateResolution? = nil,
        replacedRecords: [ApplicationRecord] = [],
        retainedRecords: [ApplicationRecord] = []
    ) {
        self.report = report
        self.resolution = resolution
        self.replacedRecords = replacedRecords
        self.retainedRecords = retainedRecords
    }

    /// The records a replacement was asked to remove and could not.
    var leftSomethingBehind: Bool {
        !retainedRecords.isEmpty
    }
}
