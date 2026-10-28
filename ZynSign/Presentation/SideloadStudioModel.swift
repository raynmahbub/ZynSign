import Foundation
import Combine

/// The Sideload Studio's state: what the journal says is installed, when each
/// build stops launching, and what the signing materials can do about it.
///
/// The model owns no records. Everything it shows is read on demand from the
/// four stores that already own it — the signing journal, the profile library,
/// the identity store, and the application library — and recomputed into one
/// snapshot. That is why there is no "mark as refreshed" action anywhere in
/// this type: a re-sign is a signing run, the run writes a record, and the
/// lease below updates the next time the studio reads. The moment the interface
/// starts keeping its own idea of installed state, the two ideas diverge and
/// the countdown becomes a decoration.
///
/// What it does decide is presentation: which account is in play, how each one
/// is doing against its published limit, which lease stops launching next, and
/// which signing materials are close enough to their own expiry to say so.
@MainActor
final class SideloadStudioModel: ObservableObject {

    /// What the studio is doing.
    enum Phase: Equatable {
        case loading
        case ready
        case failed(String)
    }

    @Published private(set) var phase: Phase = .loading

    /// The leases last derived from the journal, most urgent first.
    @Published private(set) var leases: [SideloadLease] = []

    /// The partition of `leases` into due, healthy, and unrecorded.
    @Published private(set) var plan: SideloadRefreshPlan = .empty

    /// Each account's live leases against its published limit.
    @Published private(set) var usage: [SideloadAccountUsage] = []

    /// The identities the store holds, in the store's own order.
    @Published private(set) var identities: [SigningIdentity] = []

    /// The profiles the library holds.
    @Published private(set) var profiles: [ProvisioningProfileSummary] = []

    /// The applications the library holds, for opening a lease's signing screen.
    @Published private(set) var entries: [LibraryEntry] = []

    /// A read that failed for a reason worth showing, without taking the whole
    /// screen down: the studio still reports the journal it could read.
    @Published private(set) var readNotice: String?

    /// When the snapshot was last read, so the screen can say how old its
    /// countdowns are instead of implying they tick by themselves.
    @Published private(set) var lastReadAt: Date?

    /// The four ports the studio reads, named one by one.
    ///
    /// The model takes them individually rather than taking the whole
    /// environment: a screen that may only read four things should only be able
    /// to reach four things, and a test should be able to hand it four small
    /// stores instead of composing an application.
    private let identityStore: any IdentityStore
    private let signingHistory: (any SigningHistoryStore)?
    private let provisioningProfiles: ProvisioningProfileLibrary?
    private let library: ApplicationLibrary
    private let now: () -> Date
    private var isReading = false

    init(
        identityStore: any IdentityStore,
        signingHistory: (any SigningHistoryStore)?,
        provisioningProfiles: ProvisioningProfileLibrary?,
        library: ApplicationLibrary,
        now: @escaping () -> Date = { Date() }
    ) {
        self.identityStore = identityStore
        self.signingHistory = signingHistory
        self.provisioningProfiles = provisioningProfiles
        self.library = library
        self.now = now
    }

    /// The studio over a composed application.
    convenience init(environment: ApplicationEnvironment, now: @escaping () -> Date = { Date() }) {
        self.init(
            identityStore: environment.identityStore,
            signingHistory: environment.signingHistory,
            provisioningProfiles: environment.provisioningProfiles,
            library: environment.library,
            now: now
        )
    }

    // MARK: - Reading

    /// Reads every store and rebuilds the snapshot.
    ///
    /// A store that cannot be read is named in `readNotice` rather than thrown:
    /// a device with no profile library still has an identity store and a
    /// journal, and the studio's job is to report what it can see.
    func load() async {
        guard !isReading else { return }
        isReading = true
        defer { isReading = false }
        if leases.isEmpty { phase = .loading }

        var notices: [String] = []

        do {
            identities = try identityStore.listIdentities()
        } catch {
            notices.append("The certificate store could not be read, so signing materials are not shown.")
        }

        // The materials are read whether or not there is a journal: a build
        // that tracks no leases can still say whether it could sign one.
        let (profileList, profileNotice) = await readProfiles()
        if let profileNotice { notices.append(profileNotice) }

        if let history = signingHistory {
            do {
                let records = try await history.allRecords()
                leases = SideloadLedger.leases(from: records, profiles: profileList)
            } catch {
                notices.append("The signing history could not be read, so no lease is shown.")
            }
        } else {
            notices.append("This build has no signing journal, so nothing is tracked for refresh.")
        }

        let moment = now()
        plan = SideloadRefreshPlan.plan(leases, at: moment)
        usage = SideloadLedger.usage(leases, at: moment)

        do {
            entries = try await library.entries()
        } catch {
            notices.append("The library could not be read, so an expired lease cannot be opened here.")
        }

        readNotice = notices.isEmpty ? nil : notices.joined(separator: " ")
        phase = .ready
        lastReadAt = moment
    }

    private func readProfiles() async -> ([ProvisioningProfileSummary], String?) {
        guard let library = provisioningProfiles else {
            profiles = []
            return ([], nil)
        }
        do {
            let list = try await library.allProfiles()
            profiles = list
            return (list, nil)
        } catch {
            profiles = []
            return ([], "The profile library could not be read, so a lease may not know its account.")
        }
    }

    // MARK: - The account in play

    /// The accounts that signed something, in catalogue order.
    var accountsInUse: [SideloadAccount] {
        SideloadLedger.accountsInUse(leases)
    }

    /// The account the studio leads with: the one behind the lease that stops
    /// launching first, so the headline number and the queue's first row are
    /// about the same app. A seven-day personal team shows up here the moment
    /// it signs anything.
    var activeAccount: SideloadAccount? {
        let ordered = (plan.due + plan.healthy).compactMap(\.account)
        return ordered.first ?? accountsInUse.first
    }

    /// The usage row for the account in play.
    var activeUsage: SideloadAccountUsage? {
        guard let activeAccount else { return nil }
        return usage.first { $0.account == activeAccount }
    }

    /// The usage rows that are over their limit, which is a fact the studio
    /// must state rather than bury in a list.
    var overLimitAccounts: [SideloadAccountUsage] {
        usage.filter(\.isOverLimit)
    }

    // MARK: - The lease that matters

    /// The lease that stops launching next, due or not.
    var nextLease: SideloadLease? {
        plan.due.first ?? plan.healthy.first
    }

    /// The countdown the hero card shows, in the words the row would use.
    var headlineCountdown: String {
        guard let next = nextLease, let days = next.daysRemaining(at: now()) else {
            return plan.isEmpty && leases.isEmpty ? "Nothing signed yet" : "No expiry recorded"
        }
        if next.status(at: now()) == .expired { return "Expired" }
        switch days {
        case 0: return "Expires today"
        case 1: return "1 day left"
        default: return "\(days) days left"
        }
    }

    /// One sentence under the headline. Never a claim about a device.
    var headlineDetail: String {
        if let next = nextLease {
            let ending = next.ending?.title ?? "Expiry"
            return "\(next.displayName) · \(ending) ends \(Self.formatted(next.expiresAt, now: now()))"
        }
        if leases.isEmpty {
            return "Sign an app and its seven-day (or one-year) lease appears here with a countdown."
        }
        return "Every recorded build has an expiry the studio can plan around."
    }

    /// How many leases stop launching in the next two days, whatever their
    /// account's lead — the number a person acts on.
    var urgentCount: Int {
        let moment = now()
        return leases.filter { lease in
            guard let expiresAt = lease.expiresAt else { return false }
            return expiresAt.timeIntervalSince(moment) <= 2 * 86_400
        }.count
    }

    // MARK: - Signing materials

    /// The identities the store reports as usable for signing.
    var usableIdentities: [SigningIdentity] {
        identities.filter(\.isUsableForSigning)
    }

    /// Identities whose certificate expires within the warning window. Shown
    /// before a signing run fails on them, which is the whole point of reading
    /// the journal's own dates.
    var expiringIdentities: [SigningIdentity] {
        let moment = now()
        return identities.filter { identity in
            identity.certificate.notValidAfter.timeIntervalSince(moment) <= Self.certificateWarningWindow
        }
    }

    /// How many days before a certificate's expiry the studio says so. A month
    /// is long enough to renew a membership without pressure.
    static let certificateWarningWindow: TimeInterval = 30 * 86_400

    /// The profiles that have expired or are about to.
    var expiringProfiles: [ProvisioningProfileSummary] {
        let moment = now()
        return profiles.filter { $0.expirationDate.timeIntervalSince(moment) <= Self.certificateWarningWindow }
    }

    /// Whether the studio can hand a lease to a signing run: a usable identity
    /// and a profile are both needed, and both are facts about the stores.
    var canSignAgain: Bool {
        !usableIdentities.isEmpty && !profiles.isEmpty
    }

    // MARK: - Handing a lease to a signing run

    /// The library entry a lease's signing screen signs, when the library still
    /// holds it. `nil` means the app was removed from the library after it was
    /// signed — the lease stays (the journal remembers the run), but there is
    /// nothing left to sign again, and the studio says so instead of offering a
    /// button that cannot work.
    func libraryEntry(for lease: SideloadLease) -> LibraryEntry? {
        guard let identifier = lease.libraryRecordIdentifier,
              let recordID = ApplicationRecordIdentifier(rawValue: identifier) else { return nil }
        return entries.first { $0.record.id == recordID }
    }

    /// Why a lease cannot be handed to a signing run, when it cannot.
    func refreshBlockedReason(for lease: SideloadLease) -> String? {
        if lease.libraryRecordIdentifier == nil {
            return "This run recorded no library application, so there is nothing to sign again. Import the package to re-create it."
        }
        if libraryEntry(for: lease) == nil {
            return "The application is no longer in the library. Import it again, then sign it."
        }
        if identities.isEmpty {
            return "No certificate is imported. Add one in Certificates & Profiles first."
        }
        if usableIdentities.isEmpty {
            return "The imported certificate cannot sign: its private key is unavailable or not associated with it."
        }
        if profiles.isEmpty {
            return "No provisioning profile is imported. Add the profile that authorises this app."
        }
        return nil
    }

    // MARK: - Formatting

    /// A date as a person reads it: the day, and the month when it is not this
    /// month. Deterministic for a given locale, and never a relative phrase that
    /// a screenshot cannot reproduce.
    static func formatted(_ date: Date?, now: Date) -> String {
        guard let date else { return "an unrecorded date" }
        let calendar = Calendar(identifier: .gregorian)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        formatter.dateFormat = sameYear ? "d MMM" : "d MMM yyyy"
        return formatter.string(from: date)
    }
}
