import Foundation

/// The signing-journal record for one Signing Engine run, captured when the
/// run starts and completed when it concludes.
///
/// The Sign screen runs the Signing Engine directly rather than through
/// `SigningOperationCenter`, and the engine delivers and verifies but keeps no
/// history. The screen therefore starts a draft with each run it starts and
/// appends the completed record when the run concludes, so the signing
/// history and the library — its signed state, Recently Signed, Expiring
/// Soon, and statistics — see every signing the screen performed.
///
/// What the record carries: the library entry that was signed, named by its
/// identifier; the certificate, named by its fingerprint and display name;
/// the profile's declared name; and when the profile and the certificate
/// expire. What it never carries: profile bytes, key material, passwords, or
/// a path — the delivered file is named by its file name only.
struct SigningEngineJournalDraft {

    /// The entry being signed.
    let entry: LibraryEntry

    /// When the run started.
    let startedAt: Date

    /// The signing certificate's fingerprint, when an identity was selected.
    let certificateFingerprint: CertificateFingerprint?

    /// The signing certificate's display name, when an identity was selected.
    let certificateDisplayName: String?

    /// When the signing certificate stops being valid.
    let certificateExpiresAt: Date?

    /// The provisioning profile's declared name, when it could be read.
    let provisioningProfileName: String?

    /// When the provisioning profile expires, as the profile declares it.
    let profileExpiresAt: Date?

    /// Starts a draft for a run of `entry` with `identity` and the profile
    /// bytes the run signs with. The bytes are read for the declared name
    /// and expiry and are not kept.
    init(entry: LibraryEntry, identity: SigningIdentity?, profile: Data, startedAt: Date) {
        self.entry = entry
        self.startedAt = startedAt
        self.certificateFingerprint = identity?.fingerprint
        self.certificateDisplayName = identity?.displayName
        self.certificateExpiresAt = identity?.certificate.notValidAfter
        let declared = Self.declaredProfile(in: profile)
        self.provisioningProfileName = declared?.profileName
        self.profileExpiresAt = declared?.expirationDate
    }

    /// The journal record for the run's conclusion.
    ///
    /// - A result that signed is a success, and names the delivered file.
    /// - A result that failed records the stage that stopped it and the
    ///   failure's category; a failure the engine categorised as a
    ///   cancellation is recorded as cancelled.
    /// - No result means the run threw instead of concluding: cancelled when
    ///   it was cancelled, failed otherwise, without inventing a stage.
    func record(result: SigningEngineResult?, wasCancelled: Bool, finishedAt: Date) -> SigningRecord {
        let outcome: SigningRecord.Outcome
        var stoppingStage: String?
        var errorCode: String?
        if let result, result.status == .signed {
            outcome = .succeeded
        } else if let failure = result?.failure {
            outcome = failure.category == .cancelled ? .cancelled : .failed
            stoppingStage = failure.stage.rawValue
            errorCode = failure.category.rawValue
        } else {
            outcome = wasCancelled ? .cancelled : .failed
        }
        let delivered = outcome == .succeeded ? result?.outputURL : nil
        return SigningRecord(
            presetID: nil,
            certificateFingerprint: certificateFingerprint,
            sourceBundleIdentifier: entry.record.bundleIdentifier.rawValue,
            sourceDisplayName: entry.record.displayName,
            stoppingStage: stoppingStage,
            errorCode: errorCode,
            outputFileName: delivered?.lastPathComponent,
            outputByteCount: delivered == nil ? nil : result?.summary?.containerByteCount,
            startedAt: startedAt,
            duration: finishedAt.timeIntervalSince(startedAt),
            result: outcome,
            sourceRecordIdentifier: entry.record.id.rawValue,
            shortVersion: entry.record.identity.shortVersionString,
            buildVersion: entry.record.identity.buildVersion,
            certificateDisplayName: certificateDisplayName,
            provisioningProfileName: provisioningProfileName,
            profileExpiresAt: profileExpiresAt,
            certificateExpiresAt: certificateExpiresAt
        )
    }

    /// The profile's declared metadata: the property list a signed profile
    /// container carries, located by its own markers, or the bytes as-is
    /// when they are a bare property list. No container decoder is involved,
    /// so this layer stays independent of the platform's CMS reader. `nil`
    /// when the profile cannot be read — the record then says less rather
    /// than something invented.
    static func declaredProfile(in data: Data) -> ProvisioningProfile? {
        let payload = ApplicationProvenanceExtraction.embeddedPropertyList(in: data) ?? data
        return try? PropertyListProvisioningProfileParser().parse(plistData: payload)
    }
}
