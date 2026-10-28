import Foundation

/// Turns the signing journal into the leases the studio plans with.
///
/// The journal is already the record of what happened: every operation writes
/// one, with the application it signed, when it ran, and — since the fields
/// were added for exactly this — when the profile and the certificate behind it
/// expire. The ledger therefore *reads* instead of storing. Adding a second
/// record would create a second truth about the same run, and the first one to
/// drift would be the one nobody could tell was wrong.
///
/// Three rules decide what a lease is:
///
/// - **Only a delivered run makes one.** An operation that failed or was
///   cancelled produced nothing to keep launching, so it is not in the ledger
///   at all. (It is still in the signing history, where the failure is the
///   point.)
/// - **One lease per application.** Five successful runs of the same app are
///   five entries in the journal and one lease: the newest run's expiry is the
///   only one that still decides anything, because signing replaces the
///   signature.
/// - **The account is read, never assumed.** It is taken from the profile the
///   run recorded when that profile is still in the profile library, settled by
///   the profile's own lifetime when it is not, and left unknown when neither
///   answers. An unknown account still gets a lease; it just does not get a
///   limit it cannot prove.
enum SideloadLedger {

    /// The leases the journal and the profile library support, most urgent
    /// first.
    ///
    /// - Parameters:
    ///   - records: every record the signing history holds, in any order.
    ///   - profiles: the profile library, used to read a run's account from the
    ///     profile that signed it.
    static func leases(
        from records: [SigningRecord],
        profiles: [ProvisioningProfileSummary] = []
    ) -> [SideloadLease] {
        let delivered = records.filter { $0.outcome == .succeeded }
        var newest: [String: SigningRecord] = [:]
        for record in delivered {
            let key = applicationKey(for: record)
            if let existing = newest[key], existing.startedAt >= record.startedAt {
                continue
            }
            newest[key] = record
        }
        let profilesByName = Dictionary(
            profiles.map { ($0.name, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return newest.values.map { lease(for: $0, profilesByName: profilesByName) }
            .sorted { first, second in
                switch (first.expiresAt, second.expiresAt) {
                case let (firstDate?, secondDate?):
                    if firstDate != secondDate { return firstDate < secondDate }
                    return first.displayName < second.displayName
                case (_?, nil):
                    return true
                case (nil, _?):
                    return false
                case (nil, nil):
                    return first.displayName < second.displayName
                }
            }
    }

    /// The application a run belongs to: the library record it signed, then the
    /// bundle identifier, then the artifact it produced. A record naming none of
    /// them is keyed by its own identifier, so it still gets exactly one lease.
    static func applicationKey(for record: SigningRecord) -> String {
        if let identifier = record.sourceRecordIdentifier, !identifier.isEmpty {
            return "record:\(identifier)"
        }
        if let bundleIdentifier = record.sourceBundleIdentifier, !bundleIdentifier.isEmpty {
            return "bundle:\(bundleIdentifier)"
        }
        if let fileName = record.outputFileName, !fileName.isEmpty {
            return "artifact:\(fileName)"
        }
        return "run:\(record.id.rawValue)"
    }

    /// One lease from one delivered run.
    static func lease(
        for record: SigningRecord,
        profilesByName: [String: ProvisioningProfileSummary] = [:]
    ) -> SideloadLease {
        let profile = record.provisioningProfileName.flatMap { profilesByName[$0] }
        let account = SideloadAccount.infer(
            profileType: profile?.profileType,
            profileExpiresAt: record.profileExpiresAt,
            signedAt: record.startedAt
        )
        return SideloadLease(
            id: applicationKey(for: record),
            displayName: record.displayName,
            bundleIdentifier: record.sourceBundleIdentifier ?? record.outputFileName ?? "Unknown bundle",
            libraryRecordIdentifier: record.sourceRecordIdentifier,
            signedAt: record.startedAt,
            profileExpiresAt: record.profileExpiresAt,
            certificateExpiresAt: record.certificateExpiresAt,
            account: account,
            refreshLeadDays: account?.refreshLeadDays,
            profileName: profile?.name ?? record.provisioningProfileName,
            outputFileName: record.outputFileName
        )
    }

    /// How each account's live leases count against the limit it publishes.
    ///
    /// Every account in the catalogue is present, so the studio can show a
    /// limit it has not used yet as clearly as one it has. Expired leases are
    /// not counted: a build that no longer launches is not occupying one of the
    /// account's slots on the device.
    static func usage(_ leases: [SideloadLease], at now: Date) -> [SideloadAccountUsage] {
        SideloadAccount.allCases.map { account in
            let live = leases.filter { lease in
                lease.account == account && lease.status(at: now) != .expired
            }
            return SideloadAccountUsage(account: account, installed: live.count)
        }
    }

    /// The accounts that actually signed something, strongest first, for the
    /// chip row. Ordered by the catalogue so the row never reshuffles.
    static func accountsInUse(_ leases: [SideloadLease]) -> [SideloadAccount] {
        let present = Set(leases.compactMap(\.account))
        return SideloadAccount.allCases.filter { present.contains($0) }
    }
}
