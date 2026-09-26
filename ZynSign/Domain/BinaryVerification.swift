import Foundation

// The vocabulary of ZynSign's on-device signature verification.
//
// Verification here means one thing: ZynSign re-read the executable's bytes,
// re-computed the hashes its code signature declares, and compared them. A
// check that was not performed is recorded as `notPerformed` with a reason; it
// is never reported as passed. Certificate trust, revocation, provisioning,
// and whether iOS will install or launch the app are outside every check and
// are stated as such.

// MARK: - Status

/// The outcome of one verification check.
enum BinaryCheckStatus: String, CaseIterable, Hashable {
    /// The check ran and everything it compared matched.
    case passed
    /// The check ran and found something that deserves attention but does
    /// not contradict the signature.
    case warning
    /// The check ran and found a contradiction: the bytes do not match what
    /// the signature declares.
    case failed
    /// The check could not be completed. The reason is always recorded.
    case notPerformed
    /// The check does not apply to this executable.
    case notApplicable

    var displayName: String {
        switch self {
        case .passed: return "Passed"
        case .warning: return "Warning"
        case .failed: return "Failed"
        case .notPerformed: return "Not Performed"
        case .notApplicable: return "Not Applicable"
        }
    }

    /// Ordering for "worst of": a failure outranks a warning, which outranks
    /// an unperformed check, which outranks a pass.
    var severityRank: Int {
        switch self {
        case .failed: return 4
        case .warning: return 3
        case .notPerformed: return 2
        case .passed: return 1
        case .notApplicable: return 0
        }
    }

    /// The most severe status in `statuses`, or `notApplicable` when empty.
    static func worst(_ statuses: [BinaryCheckStatus]) -> BinaryCheckStatus {
        statuses.max { $0.severityRank < $1.severityRank } ?? .notApplicable
    }
}

/// The checks that make up the Verification Details table.
enum BinaryVerificationCheckKind: String, CaseIterable, Hashable {
    case codeDirectory
    case pageHashes
    case specialSlots
    case cmsSignature
    case requirements
    case entitlements
    case nestedSignatures
    case certificateTrust

    var title: String {
        switch self {
        case .codeDirectory: return "CodeDirectory"
        case .pageHashes: return "Page Hashes"
        case .specialSlots: return "Special Slots"
        case .cmsSignature: return "CMS Signature"
        case .requirements: return "Requirements"
        case .entitlements: return "Entitlements"
        case .nestedSignatures: return "Nested Signatures"
        case .certificateTrust: return "Certificate Trust"
        }
    }

    /// What the check establishes when it passes.
    var explanation: String {
        switch self {
        case .codeDirectory:
            return "The CodeDirectory, the signature's table of hashes, is present and structurally sound in every architecture."
        case .pageHashes:
            return "Every page of code was hashed again on this device and compared with the hash the signature recorded for it."
        case .specialSlots:
            return "The Info.plist, resource seal, requirements, and entitlements were hashed again and compared with the digests the signature bound."
        case .cmsSignature:
            return "The CMS signature's message digest matches the CodeDirectory, and its cryptographic signature verifies with the signer certificate embedded in it."
        case .requirements:
            return "The requirement set is present and decodes. Requirement expressions are not evaluated."
        case .entitlements:
            return "The entitlements are present and decode. Whether a provisioning profile allows them is not evaluated here."
        case .nestedSignatures:
            return "Every framework, library, and extension inside the bundle was inspected and verified the same way."
        case .certificateTrust:
            return "Whether the signer certificate chains to Apple, is unexpired, or has been revoked. ZynSign does not evaluate trust."
        }
    }

    /// Whether the check contributes to the overall verdict. Certificate
    /// trust is never evaluated, so it is shown but never counted.
    var affectsVerdict: Bool {
        self != .certificateTrust
    }
}

/// One row of the Verification Details table.
struct BinaryVerificationCheck: Equatable, Hashable, Identifiable {
    let kind: BinaryVerificationCheckKind
    let status: BinaryCheckStatus
    /// One line, for example "3,631 of 3,631 pages match".
    let summary: String
    /// Plain language: what was compared, or why it could not be.
    let detail: String

    var id: String { kind.rawValue }
}

// MARK: - Page hashes

/// Page-hash verification for one CodeDirectory.
struct PageHashVerificationResult: Equatable, Identifiable {

    /// At most this many mismatched page indices are retained.
    static let maximumReportedMismatches = 64

    let codeDirectorySlot: UInt32
    let hashType: MachOHashType
    let pageSize: Int?
    let pageCount: Int
    /// How many pages were hashed and compared.
    let checkedPageCount: Int
    /// The first mismatched page indices, from zero.
    let mismatchedPageIndices: [Int]
    let mismatchCount: Int
    /// Why the pages were not compared, when they were not.
    let notPerformedReason: String?

    var id: UInt32 { codeDirectorySlot }

    var matchedPageCount: Int { max(0, checkedPageCount - mismatchCount) }

    var status: BinaryCheckStatus {
        if notPerformedReason != nil { return .notPerformed }
        return mismatchCount == 0 ? .passed : .failed
    }

    static func notPerformed(
        codeDirectorySlot: UInt32,
        hashType: MachOHashType,
        pageSize: Int?,
        pageCount: Int,
        reason: String
    ) -> PageHashVerificationResult {
        PageHashVerificationResult(
            codeDirectorySlot: codeDirectorySlot,
            hashType: hashType,
            pageSize: pageSize,
            pageCount: pageCount,
            checkedPageCount: 0,
            mismatchedPageIndices: [],
            mismatchCount: 0,
            notPerformedReason: reason
        )
    }
}

// MARK: - Special slots

/// What recomputing one special slot established.
enum SpecialSlotOutcome: Equatable, Hashable {
    /// The recomputed digest equals the bound digest.
    case matches
    /// The recomputed digest differs from the bound digest.
    case mismatch
    /// The slot binds nothing and nothing is expected.
    case unbound
    /// The slot binds a digest, but the content it covers is absent.
    case boundButContentMissing
    /// The content exists, but the slot binds no digest for it.
    case contentNotBound
    /// The slot could not be checked, with the reason.
    case notChecked(String)

    var status: BinaryCheckStatus {
        switch self {
        case .matches: return .passed
        case .mismatch, .boundButContentMissing: return .failed
        case .unbound: return .notApplicable
        case .contentNotBound: return .warning
        case .notChecked: return .notPerformed
        }
    }

    var displayName: String {
        switch self {
        case .matches: return "Matches"
        case .mismatch: return "Does not match"
        case .unbound: return "Not bound"
        case .boundButContentMissing: return "Content missing"
        case .contentNotBound: return "Present but not bound"
        case .notChecked: return "Not checked"
        }
    }

    var explanation: String {
        switch self {
        case .matches:
            return "The content hashes to exactly the digest the signature bound."
        case .mismatch:
            return "The content changed after signing: its hash differs from the digest the signature bound."
        case .unbound:
            return "The signature does not bind this slot."
        case .boundButContentMissing:
            return "The signature bound a digest for this content, but the content is not present."
        case .contentNotBound:
            return "The content exists, but the signature does not bind it, so changes to it would go unnoticed."
        case .notChecked(let reason):
            return reason
        }
    }
}

/// One special slot of one CodeDirectory, recomputed.
struct SpecialSlotVerificationResult: Equatable, Hashable, Identifiable {
    let codeDirectorySlot: UInt32
    let number: Int
    let outcome: SpecialSlotOutcome

    var id: String { "\(codeDirectorySlot):\(number)" }
    var title: String { CodeDirectorySpecialSlotSummary.title(for: number) }
    var status: BinaryCheckStatus { outcome.status }
}

// MARK: - Resources bound by the signature

/// Content outside the executable that a signature can bind: the bundle's
/// Info.plist (special slot 1) and resource seal (special slot 3).
enum BoundResourceContent: Equatable {
    /// The content, read within the inspection bounds.
    case available(Data)
    /// The bundle records no such file.
    case missing
    /// The file exists but could not be read within the inspection bounds.
    case unreadable(String)
    /// The executable is not inside a bundle, so there is nothing to bind.
    case notApplicable
}

/// The bundle content a signature may bind, gathered by the caller.
struct BinaryBoundResources: Equatable {
    let infoPlist: BoundResourceContent
    let codeResources: BoundResourceContent

    static let notApplicable = BinaryBoundResources(infoPlist: .notApplicable, codeResources: .notApplicable)
}

/// What ZynSign established about the resource seal of one executable.
enum ResourceIntegrityStatus: Equatable {
    /// The resource seal is present and bound: it hashes to the digest the
    /// signature recorded. The sealed file count, when the seal could be read.
    case sealedAndBound(sealedFileCount: Int?)
    /// The signature binds no resource seal.
    case notSealed
    /// The resource seal changed after signing.
    case sealMismatch
    /// The signature binds a resource seal that is not present.
    case sealMissing
    /// The seal could not be checked, with the reason.
    case notChecked(String)

    var status: BinaryCheckStatus {
        switch self {
        case .sealedAndBound: return .passed
        case .notSealed: return .notApplicable
        case .sealMismatch, .sealMissing: return .failed
        case .notChecked: return .notPerformed
        }
    }

    var summary: String {
        switch self {
        case .sealedAndBound(let count):
            if let count { return "Resource seal bound — \(count.formatted()) sealed files listed" }
            return "Resource seal bound"
        case .notSealed: return "No resource seal bound"
        case .sealMismatch: return "Resource seal changed after signing"
        case .sealMissing: return "Resource seal missing"
        case .notChecked: return "Resource seal not checked"
        }
    }

    var detail: String {
        switch self {
        case .sealedAndBound:
            return "_CodeSignature/CodeResources hashes to exactly the digest the signature bound. Each sealed file can be re-hashed on demand."
        case .notSealed:
            return "This signature does not bind a resource seal, which is normal for standalone libraries and linker-signed code."
        case .sealMismatch:
            return "_CodeSignature/CodeResources differs from what was signed, so the resource list can no longer be trusted."
        case .sealMissing:
            return "The signature expects _CodeSignature/CodeResources, but the bundle does not contain it."
        case .notChecked(let reason):
            return reason
        }
    }
}

// MARK: - CMS

/// Whether the CMS message digest binds a CodeDirectory.
enum CMSSignatureBinding: Equatable {
    /// The message digest equals the digest of the CodeDirectory in `slot`.
    case matches(codeDirectorySlot: UInt32)
    /// The message digest equals no CodeDirectory in the signature.
    case mismatch
    /// The digest was not compared, with the reason.
    case notCompared(String)
}

/// Whether the CMS cryptographic signature verified.
enum CMSSignatureCheck: Equatable {
    /// The signature over the signed attributes verifies with the embedded
    /// signer certificate's public key.
    case verified
    /// The signature does not verify.
    case invalid
    /// The signature was not checked, with the reason.
    case notPerformed(String)
}

/// The signer certificate, summarised. Public metadata only: no certificate
/// bytes, serial numbers, or key material are carried.
struct CodeSignatureSignerSummary: Equatable, Hashable {
    let commonName: String?
    let organization: String?
    /// For Apple-issued signing certificates, the team identifier.
    let organizationalUnit: String?
    let issuerCommonName: String?
    let notValidBefore: Date
    let notValidAfter: Date
    let keyDescription: String
}

/// What ZynSign established about a CMS signature payload.
struct CodeSignatureCMSEvaluation: Equatable {
    let signerCount: Int
    let certificateCount: Int
    let signer: CodeSignatureSignerSummary?
    /// Why no signer certificate is summarised, when none is.
    let signerCertificateNote: String?
    let digestAlgorithmName: String?
    let signatureAlgorithmName: String?
    let binding: CMSSignatureBinding
    let signature: CMSSignatureCheck
    /// The signing time the signer declared. A declaration by the signer's
    /// own clock, not a trusted timestamp.
    let declaredSigningTime: Date?
    /// Whether the signer carries attributes outside the signed set, such as
    /// a timestamp token. ZynSign records their presence only.
    let hasUnsignedAttributes: Bool
}

/// The CMS part of one signature.
enum CodeSignatureCMSAssessment: Equatable {
    /// The signature has no CMS slot.
    case absent
    /// The CMS slot holds an empty wrapper, as ad-hoc signatures do.
    case empty
    /// ZynSign's bounded reader could not read the message, with the reason.
    case unreadable(String)
    /// The message was read and evaluated.
    case evaluated(CodeSignatureCMSEvaluation)

    var evaluation: CodeSignatureCMSEvaluation? {
        if case .evaluated(let evaluation) = self { return evaluation }
        return nil
    }
}

/// One CodeDirectory blob offered to the CMS inspector as candidate content.
struct CodeSignatureCMSContent: Equatable {
    let codeDirectorySlot: UInt32
    let bytes: Data
}

/// The boundary through which a detached code-signature CMS payload is
/// examined.
///
/// A code signature's CMS message signs the CodeDirectory without carrying
/// it: the content is detached. The implementation reads the message with
/// ZynSign's bounded CMS reader, relates the signer to an embedded
/// certificate, compares the message-digest attribute with each candidate
/// CodeDirectory, and checks the signature with the platform primitive. It
/// never evaluates certificate trust.
protocol CodeSignatureCMSVerifying {

    /// Examines `cmsPayload` — the CMS blob without its 8-byte header —
    /// against the CodeDirectories of the same signature.
    func assess(cmsPayload: Data, codeDirectories: [CodeSignatureCMSContent]) -> CodeSignatureCMSAssessment
}

// MARK: - Integrity report

/// Verification of one architecture slice.
struct ArchitectureIntegrityResult: Equatable, Identifiable {
    let architectureIndex: Int
    let isSigned: Bool
    let pageHashes: [PageHashVerificationResult]
    let specialSlots: [SpecialSlotVerificationResult]
    let cms: CodeSignatureCMSAssessment
    /// The per-slice checks, in table order.
    let checks: [BinaryVerificationCheck]

    var id: Int { architectureIndex }

    func check(_ kind: BinaryVerificationCheckKind) -> BinaryVerificationCheck? {
        checks.first { $0.kind == kind }
    }
}

/// The overall verification verdict for one executable.
enum BinaryVerificationVerdict: String, Equatable, Hashable {
    /// Every check that applies ran and passed.
    case valid
    /// No contradiction was found, but something deserves attention or a
    /// check could not be completed.
    case warning
    /// At least one check found a contradiction.
    case failed
    /// No architecture carries a signature.
    case unsigned
    /// Verification is still running.
    case pending
    /// Verification could not run at all.
    case notVerified

    var displayName: String {
        switch self {
        case .valid: return "Valid"
        case .warning: return "Warning"
        case .failed: return "Failed"
        case .unsigned: return "Unsigned"
        case .pending: return "Verifying"
        case .notVerified: return "Not Verified"
        }
    }

    var explanation: String {
        switch self {
        case .valid:
            return "Every check that applies ran on this device and passed. This is not a statement about certificate trust or whether iOS will install the app."
        case .warning:
            return "No contradiction was found, but at least one check needs attention or could not be completed."
        case .failed:
            return "At least one check found that the bytes do not match what the signature declares."
        case .unsigned:
            return "The executable carries no code signature."
        case .pending:
            return "ZynSign is still hashing and comparing the executable."
        case .notVerified:
            return "The executable could not be verified."
        }
    }
}

/// The complete verification of one executable.
struct BinaryIntegrityReport: Equatable {
    let architectures: [ArchitectureIntegrityResult]
    /// The Verification Details rows, aggregated across architectures. The
    /// nested-signature row is bundle-level and is added by the caller that
    /// knows the whole bundle.
    let checks: [BinaryVerificationCheck]
    let resourceIntegrity: ResourceIntegrityStatus
    let verifiedAt: Date

    var isSigned: Bool { architectures.contains(where: \.isSigned) }

    var verdict: BinaryVerificationVerdict {
        BinaryVerdictPolicy.verdict(isSigned: isSigned, checks: checks)
    }

    func check(_ kind: BinaryVerificationCheckKind) -> BinaryVerificationCheck? {
        checks.first { $0.kind == kind }
    }

    var totalPageCount: Int {
        architectures.flatMap(\.pageHashes).reduce(0) { $0 + $1.pageCount }
    }

    var checkedPageCount: Int {
        architectures.flatMap(\.pageHashes).reduce(0) { $0 + $1.checkedPageCount }
    }

    var mismatchedPageCount: Int {
        architectures.flatMap(\.pageHashes).reduce(0) { $0 + $1.mismatchCount }
    }
}

// MARK: - Policies

/// Derives the verdict from the checks. Deliberately small and pure, so the
/// rule is easy to read and pinned by tests.
enum BinaryVerdictPolicy {

    static func verdict(isSigned: Bool, checks: [BinaryVerificationCheck]) -> BinaryVerificationVerdict {
        guard isSigned else { return .unsigned }
        let counted = checks.filter { $0.kind.affectsVerdict }
        guard !counted.isEmpty else { return .notVerified }
        if counted.contains(where: { $0.status == .failed }) {
            return .failed
        }
        if counted.contains(where: { $0.status == .warning || $0.status == .notPerformed }) {
            return .warning
        }
        return .valid
    }
}

/// Aggregates per-architecture checks into the Verification Details table.
enum BinaryIntegrityAggregation {

    /// Combines the per-slice checks of each kind into one row. The row's
    /// status is the most severe slice status; its text names the slices when
    /// they differ.
    static func aggregate(
        _ results: [ArchitectureIntegrityResult],
        architectureNames: [Int: String]
    ) -> [BinaryVerificationCheck] {
        let kinds: [BinaryVerificationCheckKind] = [
            .codeDirectory, .pageHashes, .specialSlots, .cmsSignature,
            .requirements, .entitlements, .certificateTrust,
        ]
        return kinds.compactMap { kind -> BinaryVerificationCheck? in
            let perSlice = results.compactMap { result -> (Int, BinaryVerificationCheck)? in
                result.check(kind).map { (result.architectureIndex, $0) }
            }
            guard let first = perSlice.first else { return nil }
            if perSlice.count == 1 {
                return first.1
            }
            let status = BinaryCheckStatus.worst(perSlice.map { $0.1.status })
            let summaries = Set(perSlice.map { $0.1.summary })
            if summaries.count == 1, Set(perSlice.map { $0.1.status }).count == 1 {
                return BinaryVerificationCheck(
                    kind: kind,
                    status: status,
                    summary: first.1.summary,
                    detail: "Same result in all \(perSlice.count) architectures. " + first.1.detail
                )
            }
            let lines = perSlice.map { entry -> String in
                let name = architectureNames[entry.0] ?? "Architecture \(entry.0 + 1)"
                return "\(name): \(entry.1.summary)"
            }
            let worst = perSlice.first { $0.1.status == status }?.1 ?? first.1
            return BinaryVerificationCheck(
                kind: kind,
                status: status,
                summary: lines.joined(separator: " · "),
                detail: worst.detail
            )
        }
    }
}
