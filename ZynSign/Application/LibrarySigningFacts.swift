import Foundation

/// What ZynSign's signing journal says about one library entry: when it was
/// last signed successfully, and when the assets that signing used expire.
struct LibrarySigningFact: Hashable, Sendable {

    /// When the most recent successful signing started.
    let lastSignedAt: Date

    /// When the provisioning profile used by that signing expires, when
    /// the journal recorded it.
    let profileExpiresAt: Date?

    /// When the certificate used by that signing stops being valid, when
    /// the journal recorded it.
    let certificateExpiresAt: Date?

    /// The earlier of the two expiry dates: the moment the signed output
    /// stops being launchable, as far as the journal knows.
    var earliestExpiry: Date? {
        switch (profileExpiresAt, certificateExpiresAt) {
        case (.some(let profile), .some(let certificate)): return min(profile, certificate)
        case (.some(let profile), .none): return profile
        case (.none, .some(let certificate)): return certificate
        case (.none, .none): return nil
        }
    }
}

/// How close the assets behind an entry's last signing are to expiring.
enum LibraryExpiryStatus: Hashable, Sendable {

    /// The entry was never signed, or its signing recorded no expiry.
    case unknown

    /// The assets stay valid beyond the expiry window.
    case valid(until: Date)

    /// The assets expire within the expiry window.
    case expiringSoon(on: Date)

    /// The assets have expired.
    case expired(on: Date)

    /// Whether the entry belongs in Expiring Soon: expiring within the
    /// window, or already expired.
    var needsAttention: Bool {
        switch self {
        case .expiringSoon, .expired: return true
        case .unknown, .valid: return false
        }
    }

    /// Classifies a signing fact at `now` against `window`.
    static func evaluate(
        _ fact: LibrarySigningFact?,
        now: Date,
        window: TimeInterval = LibraryWindows.expiringSoon
    ) -> LibraryExpiryStatus {
        guard let expiry = fact?.earliestExpiry else { return .unknown }
        if expiry <= now {
            return .expired(on: expiry)
        }
        if expiry.timeIntervalSince(now) <= window {
            return .expiringSoon(on: expiry)
        }
        return .valid(until: expiry)
    }
}

/// The signing journal reduced to one fact per library entry.
///
/// **Which entry a signing belongs to.** Signings recorded since the
/// library learned to name its entries carry the signed record's
/// identifier, and belong to that record alone — a newer import of the same
/// application is not "signed" because an older copy was. Journal entries
/// written before that carry only a bundle identifier; one of those is
/// attributed to every record with that bundle identifier that already
/// existed when the signing started, which is the most the entry can say.
///
/// **Which signing counts.** Only successful signings — the journal
/// entries that delivered an output — make an entry signed. When several
/// apply, the most recent wins, and its recorded expiry dates are the ones
/// Expiring Soon uses.
///
/// The journal is bounded, so an entry signed long ago can fall out of it
/// and read as unsigned again. The facts describe the journal as it is;
/// they never invent history it no longer holds.
struct LibrarySigningFacts: Hashable, Sendable {

    private var byRecord: [ApplicationRecordIdentifier: LibrarySigningFact]
    private var byBundleIdentifier: [String: LibrarySigningFact]

    /// Facts from an empty journal: nothing is signed.
    static let empty = LibrarySigningFacts(journal: [])

    /// Reduces `journal` to facts.
    init(journal: [SigningRecord]) {
        var byRecord: [ApplicationRecordIdentifier: LibrarySigningFact] = [:]
        var byBundleIdentifier: [String: LibrarySigningFact] = [:]
        for entry in journal where entry.outcome == .succeeded {
            let fact = LibrarySigningFact(
                lastSignedAt: entry.startedAt,
                profileExpiresAt: entry.profileExpiresAt,
                certificateExpiresAt: entry.certificateExpiresAt
            )
            if let recordID = entry.sourceRecordID {
                if let existing = byRecord[recordID], existing.lastSignedAt >= fact.lastSignedAt {
                    continue
                }
                byRecord[recordID] = fact
            } else if let bundleIdentifier = entry.sourceBundleIdentifier {
                if let existing = byBundleIdentifier[bundleIdentifier], existing.lastSignedAt >= fact.lastSignedAt {
                    continue
                }
                byBundleIdentifier[bundleIdentifier] = fact
            }
        }
        self.byRecord = byRecord
        self.byBundleIdentifier = byBundleIdentifier
    }

    /// Whether the journal holds no successful signing at all.
    var isEmpty: Bool {
        byRecord.isEmpty && byBundleIdentifier.isEmpty
    }

    /// The fact for `record`, or `nil` when the journal holds no successful
    /// signing attributable to it.
    func fact(for record: ApplicationRecord) -> LibrarySigningFact? {
        if let exact = byRecord[record.id] {
            return exact
        }
        if let legacy = byBundleIdentifier[record.bundleIdentifier.rawValue],
           record.importedAt <= legacy.lastSignedAt {
            return legacy
        }
        return nil
    }
}
