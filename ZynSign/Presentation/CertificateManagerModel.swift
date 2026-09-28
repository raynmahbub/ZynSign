import Foundation
import Combine

/// The presentation-side state machine for the Certificates area.
///
/// The model carries exactly one content phase at a time — loading, loaded,
/// empty, or failed — so the screen can never show an empty library while
/// registrations are still being read, and never silently drops a storage
/// failure. Import, removal, defaulting, and renaming are part of the same
/// machine: after every change the model re-reads the identity store and the
/// annotation store, so what the screen shows is what the stores hold. The
/// list is never edited in place.
///
/// The model coordinates nothing itself: it invokes the identity store, the
/// local annotation store, and the PKCS#12 importer, and renders the
/// outcomes. A password travels to the importer in a single parameter and is
/// never retained, logged, or persisted anywhere in this model; the
/// annotation store it writes holds only labels, dates, and the default
/// mark.
@MainActor
final class CertificateManagerModel: ObservableObject {

    /// One identity as the screen presents it: the secure store's snapshot
    /// joined with the certificate's declared team and purpose, the
    /// expiration classification, and the user's local notes.
    ///
    /// The item is a projection, not a copy of the store: after every change
    /// the model re-reads the stores and rebuilds its items, so the item can
    /// never drift from persistence.
    struct CertificateItem: Identifiable, Equatable, Hashable {

        /// The secure store's snapshot of the identity.
        let identity: SigningIdentity

        /// The team the certificate's subject declares.
        let team: CertificateTeamIdentity

        /// The purpose the certificate's common name declares.
        let kind: SigningCertificateKind

        /// The expiration classification at the last read.
        let expiration: CertificateExpirationAssessment

        /// The user-chosen display label, or `nil` when the certificate's
        /// own display name is shown.
        let displayLabel: String?

        /// When ZynSign imported the identity, when recorded.
        let importedAt: Date?

        /// Whether the user has marked this identity as the default.
        let isDefault: Bool

        /// The certificate fingerprint: the stable identifier of the
        /// certificate's bytes, and the key of every local note.
        var id: String { identity.fingerprint.hexDigest }

        /// The name the screen shows: the user's label when chosen,
        /// otherwise the certificate's own display name.
        var displayName: String { displayLabel ?? identity.displayName }

        /// The subject's common name, as declared by the certificate.
        var commonName: String { identity.certificate.subject.commonName ?? identity.displayName }

        /// The subject's organization, as declared by the certificate.
        var organization: String? { identity.certificate.subject.organization }

        /// The team ID, when the certificate declares one.
        var teamID: String? { team.teamID }

        /// The team name, when the certificate declares one.
        var teamName: String? { team.teamName }

        /// The last observation of the identity's usability for signing.
        var isUsableForSigning: Bool { identity.isUsableForSigning }
    }

    /// How the library orders its entries.
    enum SortOrder: String, CaseIterable, Identifiable {

        /// By display name, the way a contacts list sorts.
        case name

        /// By team, then name. Identities with no team information sort
        /// after those with some.
        case team

        /// By expiration, soonest-expiring first: an identity that expires
        /// tomorrow floats above one good for a year, so what needs
        /// attention floats up.
        case expiration

        /// Most recently imported first; identities with no recorded import
        /// date sort after those with one.
        case recentlyImported

        var id: Self { self }

        /// The user-presentable name, shown in the sort menu.
        var displayName: String {
            switch self {
            case .name: return "Name"
            case .team: return "Team"
            case .expiration: return "Expiration"
            case .recentlyImported: return "Recently Imported"
            }
        }
    }

    /// The expiration states the status filter can select. "Active" means
    /// the identity is valid at the last evaluation — healthy or expiring
    /// soon — because both can still sign; the finer distinction is the
    /// separate "Expiring Soon" state.
    enum ExpirationFilter: String, CaseIterable, Identifiable {

        case all
        case active
        case expiringSoon
        case expired
        case notYetValid

        var id: Self { self }

        /// The user-presentable name, shown in the filter menu.
        var displayName: String {
            switch self {
            case .all: return "All"
            case .active: return "Active"
            case .expiringSoon: return "Expiring Soon"
            case .expired: return "Expired"
            case .notYetValid: return "Not Yet Valid"
            }
        }
    }

    /// The certificate purposes the type filter can select.
    enum KindFilter: String, CaseIterable, Identifiable {

        case all
        case development
        case distribution
        case other

        var id: Self { self }

        /// The user-presentable name, shown in the filter menu.
        var displayName: String {
            switch self {
            case .all: return "All"
            case .development: return "Development"
            case .distribution: return "Distribution"
            case .other: return "Other"
            }
        }
    }

    /// One selectable team in the team filter, derived from the loaded
    /// identities. Identities with no team information form a single "No
    /// Team" group rather than each becoming an option.
    struct TeamOption: Equatable, Hashable, Identifiable {
        let id: String
        let displayName: String

        /// The team identifier for identities that declare no team
        /// information.
        static let noTeamID = "zynsign.no-team"
    }

    /// A transient, user-presentable announcement — a change that failed,
    /// or a result that did not need to replace the content on screen. The
    /// view renders it and clears it when acknowledged.
    struct Notice: Equatable, Identifiable {
        let title: String
        let message: String

        var id: String { "\(title)-\(message)" }
    }

    /// The phase of the library's content, rendered directly by the view.
    enum Phase: Equatable {

        /// The identity store is being read. The initial phase, so the
        /// screen never presents an empty library as a finding.
        case loading

        /// The store holds the given identities, in the order the screen
        /// will project them.
        case loaded([CertificateItem])

        /// The store was read and holds no identities.
        case empty

        /// The store could not be read. Carries a user-presentable
        /// explanation, never diagnostic detail.
        case failed(String)
    }

    // MARK: - Published state

    /// The current content phase of the library.
    @Published private(set) var phase: Phase = .loading

    /// The search text the list filters on.
    @Published var searchText = ""

    /// The order the library is listed in.
    @Published var sortOrder: SortOrder = .name

    /// The expiration state the list filters on.
    @Published var expirationFilter: ExpirationFilter = .all

    /// The purpose the list filters on.
    @Published var kindFilter: KindFilter = .all

    /// The team the list filters on, as a team option identifier; `nil`
    /// filters by no team.
    @Published var teamFilter: String?

    /// The fingerprint the user has marked as the default signing identity,
    /// as of the last read.
    @Published private(set) var defaultFingerprint: String?

    /// Whether an import is running; the view disables its import controls
    /// while this is set.
    @Published private(set) var isImporting = false

    /// The user-presentable reason the last import failed, or `nil` when
    /// there is none. The view shows it in the password sheet and clears it
    /// on the next attempt.
    @Published private(set) var importError: String?

    /// The item an import produced, for the view's success summary. The view
    /// clears it when the summary is dismissed.
    @Published private(set) var importSummary: CertificateItem?

    /// The identity a change is running against, so the view can mark it.
    /// `nil` whenever no change is running.
    @Published private(set) var busyItemID: String?

    /// The announcement to show, if any.
    @Published private(set) var notice: Notice?

    // MARK: - Dependencies

    private let store: any IdentityStore
    private let annotations: (any IdentityAnnotationsStore)?
    private let importer: any SigningIdentityImporter
    private let clock: any EvaluationClock
    private let warningThresholdDays: Int
    private var isReadingStore = false
    private var hasPendingRead = false

    /// Creates the model over the identity store it lists, the local
    /// annotation store it reads and writes, and the importer it drives.
    ///
    /// The annotation store is optional: without it the model lists,
    /// searches, sorts, filters, imports, and removes as usual, and treats
    /// labels, import dates, and the default as unavailable rather than
    /// failing the screen. The clock and threshold are injected so the
    /// expiration classification is reproducible in tests.
    init(
        store: any IdentityStore,
        annotations: (any IdentityAnnotationsStore)?,
        importer: any SigningIdentityImporter,
        clock: any EvaluationClock = SystemEvaluationClock(),
        warningThresholdDays: Int = CertificateExpirationAssessment.defaultWarningThresholdDays
    ) {
        self.store = store
        self.annotations = annotations
        self.importer = importer
        self.clock = clock
        self.warningThresholdDays = warningThresholdDays
    }

    // MARK: - Loading

    /// Loads the library when the screen appears. The first load presents
    /// the loading state; once content is on screen the same call acts as a
    /// refresh that keeps the content visible while the stores are read
    /// again — so an identity imported elsewhere appears without the screen
    /// flashing through a loading state, and a failure during such a refresh
    /// never replaces the user's library with an error screen.
    func load() async {
        switch phase {
        case .loaded, .empty:
            await refresh()
        case .loading, .failed:
            await readStore(presentingLoadingState: true)
        }
    }

    /// Reads the stores again while keeping whatever is on screen.
    func refresh() async {
        await readStore(presentingLoadingState: false)
    }

    /// Reads the identity store and the annotation store and updates the
    /// phase. A read already in progress is not interrupted; a request
    /// arriving during one is answered by a follow-up read, so a refresh can
    /// never be lost to a concurrent load.
    private func readStore(presentingLoadingState: Bool) async {
        if isReadingStore {
            hasPendingRead = true
            return
        }
        isReadingStore = true
        defer { isReadingStore = false }
        var showLoadingState = presentingLoadingState
        while true {
            if showLoadingState {
                phase = .loading
            }
            do {
                let identities = try store.listIdentities()
                var annotationsByFingerprint: [String: IdentityAnnotation] = [:]
                var defaultFingerprint: String?
                if let annotations {
                    annotationsByFingerprint = try annotations.annotations()
                    defaultFingerprint = try annotations.defaultIdentityFingerprint()
                }
                // A default that no longer names a loaded identity is stale:
                // clear it once, so a removed identity cannot stay default.
                if let stale = defaultFingerprint,
                   !identities.contains(where: { $0.fingerprint.hexDigest == stale }) {
                    defaultFingerprint = nil
                    try? annotations?.setDefaultIdentityFingerprint(nil)
                }
                let now = clock.now()
                let items = identities.map { identity in
                    makeItem(
                        identity: identity,
                        annotation: annotationsByFingerprint[identity.fingerprint.hexDigest],
                        defaultFingerprint: defaultFingerprint,
                        at: now
                    )
                }
                self.defaultFingerprint = defaultFingerprint
                phase = items.isEmpty ? .empty : .loaded(items)
            } catch {
                if showLoadingState {
                    phase = .failed(Self.failureMessage(for: error))
                } else {
                    // Content is on screen; keep it and announce the failure
                    // rather than silently discarding it.
                    notice = Notice(
                        title: Self.refreshFailureTitle,
                        message: Self.failureMessage(for: error)
                    )
                }
            }
            guard hasPendingRead else { break }
            hasPendingRead = false
            showLoadingState = false
        }
    }

    /// Joins one identity with its local notes into the item the screen
    /// shows. Pure, so the join rule is testable without stores.
    private func makeItem(
        identity: SigningIdentity,
        annotation: IdentityAnnotation?,
        defaultFingerprint: String?,
        at now: Date
    ) -> CertificateItem {
        let fingerprint = identity.fingerprint.hexDigest
        return CertificateItem(
            identity: identity,
            team: CertificateTeamIdentity.from(identity.certificate.subject),
            kind: SigningCertificateKind.classify(subject: identity.certificate.subject),
            expiration: CertificateExpirationAssessment.assess(
                certificate: identity.certificate,
                at: now,
                warningThresholdDays: warningThresholdDays
            ),
            displayLabel: annotation?.displayLabel,
            importedAt: annotation?.importedAt,
            isDefault: defaultFingerprint == fingerprint
        )
    }

    // MARK: - Filtering and ordering

    /// Whether any filter other than "all" is active.
    var hasActiveFilters: Bool {
        expirationFilter != .all || kindFilter != .all || teamFilter != nil
    }

    /// Clears every filter at once.
    func clearFilters() {
        expirationFilter = .all
        kindFilter = .all
        teamFilter = nil
    }

    /// The teams the loaded identities declare, for the team filter.
    /// Identities without team information form a single "No Team" group.
    var teamOptions: [TeamOption] {
        guard case .loaded(let items) = phase else { return [] }
        var seen: [String: TeamOption] = [:]
        for item in items {
            let id = item.teamID ?? item.teamName ?? TeamOption.noTeamID
            let name = item.teamName ?? item.teamID ?? "No Team"
            if seen[id] == nil {
                seen[id] = TeamOption(id: id, displayName: name)
            }
        }
        return seen.values.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    /// The identities the screen shows for the current search, filters, and
    /// sort. The loaded phase is never edited in place — the visible list is
    /// this projection of it, recomputed on every change.
    func visibleItems() -> [CertificateItem] {
        guard case .loaded(let items) = phase else { return [] }
        return Self.displayed(
            items,
            matching: searchText,
            expiration: expirationFilter,
            kind: kindFilter,
            team: teamFilter,
            sortedBy: sortOrder
        )
    }

    /// Whether `item` matches `query`: a case-insensitive substring of the
    /// display name, the certificate's common name, the organization, the
    /// team name or ID, the issuer, or the fingerprint. An empty query
    /// matches everything. Internal so the rule is testable without views.
    static func matches(_ item: CertificateItem, query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        let haystacks = [
            item.displayName,
            item.commonName,
            item.organization ?? "",
            item.teamName ?? "",
            item.teamID ?? "",
            item.identity.certificate.issuer.displayName,
            item.id,
        ]
        return haystacks.contains { $0.localizedCaseInsensitiveContains(trimmed) }
    }

    /// Whether `item` passes the selected expiration state.
    static func matches(_ item: CertificateItem, expiration: ExpirationFilter) -> Bool {
        switch expiration {
        case .all:
            return true
        case .active:
            return item.expiration.isUsableAtEvaluationDate
        case .expiringSoon:
            return item.expiration.status == .expiringSoon
        case .expired:
            return item.expiration.status == .expired
        case .notYetValid:
            return item.expiration.status == .notYetValid
        }
    }

    /// Whether `item` passes the selected purpose.
    static func matches(_ item: CertificateItem, kind: KindFilter) -> Bool {
        switch kind {
        case .all:
            return true
        case .development:
            return item.kind == .development
        case .distribution:
            return item.kind == .distribution
        case .other:
            return item.kind == .other
        }
    }

    /// Whether `item` passes the selected team. `nil` passes everything.
    static func matches(_ item: CertificateItem, team teamID: String?) -> Bool {
        guard let teamID else { return true }
        return (item.teamID ?? item.teamName ?? TeamOption.noTeamID) == teamID
    }

    /// Orders `items` by `order`. Every comparison ends in the item
    /// identifier, so the order is always stable and deterministic.
    static func ordered(_ items: [CertificateItem], by order: SortOrder) -> [CertificateItem] {
        switch order {
        case .name:
            return items.sorted { lhs, rhs in
                if lhs.displayName.localizedStandardCompare(rhs.displayName) != .orderedSame {
                    return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
                }
                return lhs.id < rhs.id
            }
        case .team:
            return items.sorted { lhs, rhs in
                // Identities with team information sort before those
                // without, the way people read a grouped list.
                let lhsHasTeam = lhs.team.hasTeamInformation
                let rhsHasTeam = rhs.team.hasTeamInformation
                if lhsHasTeam != rhsHasTeam {
                    return lhsHasTeam && !rhsHasTeam
                }
                let lhsTeam = lhs.teamName ?? lhs.teamID ?? ""
                let rhsTeam = rhs.teamName ?? rhs.teamID ?? ""
                if lhsTeam.localizedStandardCompare(rhsTeam) != .orderedSame {
                    return lhsTeam.localizedStandardCompare(rhsTeam) == .orderedAscending
                }
                if lhs.displayName.localizedStandardCompare(rhs.displayName) != .orderedSame {
                    return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
                }
                return lhs.id < rhs.id
            }
        case .expiration:
            return items.sorted { lhs, rhs in
                if lhs.expiration.notValidAfter != rhs.expiration.notValidAfter {
                    return lhs.expiration.notValidAfter < rhs.expiration.notValidAfter
                }
                return lhs.id < rhs.id
            }
        case .recentlyImported:
            return items.sorted { lhs, rhs in
                // Recorded import dates first, newest above older;
                // identities without a recorded date sort after all of them.
                switch (lhs.importedAt, rhs.importedAt) {
                case (.some(let lhsDate), .some(let rhsDate)):
                    if lhsDate != rhsDate {
                        return lhsDate > rhsDate
                    }
                    return lhs.id < rhs.id
                case (.some, .none):
                    return true
                case (.none, .some):
                    return false
                case (.none, .none):
                    return lhs.id < rhs.id
                }
            }
        }
    }

    /// The filtered, ordered list the screen shows for the current search,
    /// filters, and order.
    static func displayed(
        _ items: [CertificateItem],
        matching query: String,
        expiration: ExpirationFilter,
        kind: KindFilter,
        team: String?,
        sortedBy order: SortOrder
    ) -> [CertificateItem] {
        ordered(
            items.filter {
                matches($0, query: query)
                    && matches($0, expiration: expiration)
                    && matches($0, kind: kind)
                    && matches($0, team: team)
            },
            by: order
        )
    }

    // MARK: - The default identity

    /// Marks `item` as the default signing identity, then re-reads so the
    /// screen reflects persistence.
    ///
    /// - Returns: Whether the default was saved.
    @discardableResult
    func setDefault(_ item: CertificateItem) async -> Bool {
        guard let annotations else {
            notice = Notice(title: Self.notesUnavailableTitle, message: Self.notesUnavailableMessage)
            return false
        }
        do {
            try annotations.setDefaultIdentityFingerprint(item.id)
            await refresh()
            return true
        } catch {
            notice = Notice(title: Self.defaultFailureTitle, message: Self.failureMessage(for: error))
            return false
        }
    }

    /// Clears the default signing identity, when one is set.
    ///
    /// - Returns: Whether the default was cleared.
    @discardableResult
    func clearDefault() async -> Bool {
        guard let annotations, defaultFingerprint != nil else { return false }
        do {
            try annotations.setDefaultIdentityFingerprint(nil)
            await refresh()
            return true
        } catch {
            notice = Notice(title: Self.defaultFailureTitle, message: Self.failureMessage(for: error))
            return false
        }
    }

    // MARK: - Display labels (local only)

    /// Renames the display of `item` locally. The certificate and its key
    /// are untouched; only the user's label changes. An empty label clears
    /// the rename and returns the screen to the certificate's own name.
    ///
    /// The label is trimmed; a label that is empty after trimming clears
    /// the rename, and one longer than the annotation boundary is refused
    /// with a notice rather than truncated.
    ///
    /// - Returns: Whether the label was saved or cleared.
    @discardableResult
    func setDisplayLabel(_ rawLabel: String?, for item: CertificateItem) async -> Bool {
        guard let annotations else {
            notice = Notice(title: Self.notesUnavailableTitle, message: Self.notesUnavailableMessage)
            return false
        }
        let trimmed = rawLabel?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, trimmed.count > IdentityAnnotation.maximumLabelLength {
            notice = Notice(
                title: Self.labelFailureTitle,
                message: "Display labels can be at most \(IdentityAnnotation.maximumLabelLength) characters."
            )
            return false
        }
        do {
            var annotation = currentAnnotation(forFingerprint: item.id) ?? IdentityAnnotation()
            annotation.displayLabel = (trimmed?.isEmpty == false) ? trimmed : nil
            try annotations.setAnnotation(annotation, forFingerprint: item.id)
            await refresh()
            return true
        } catch {
            notice = Notice(title: Self.labelFailureTitle, message: Self.failureMessage(for: error))
            return false
        }
    }

    private func currentAnnotation(forFingerprint fingerprint: String) -> IdentityAnnotation? {
        (try? annotations?.annotations())?[fingerprint]
    }

    // MARK: - Import

    /// Imports the PKCS#12 container the user selected, with the password
    /// the user entered.
    ///
    /// The password is passed straight through to the importer and is not
    /// stored, logged, or retained by this model; the importer owns it for
    /// the duration of the call. On success the model records the import
    /// date in the local notes (when no date is recorded yet), re-reads the
    /// store, and returns the imported item so the view can summarise it.
    /// On failure the list is left exactly as it is and the reason is
    /// carried in `importError`.
    @discardableResult
    func performImport(data: Data, password: String) async -> CertificateItem? {
        guard !isImporting else { return nil }
        isImporting = true
        importError = nil
        defer { isImporting = false }
        do {
            let identityID = try importer.importPKCS12(data: data, password: password)
            if let identity = try? store.identity(withID: identityID) {
                let fingerprint = identity.fingerprint.hexDigest
                if let annotations, currentAnnotation(forFingerprint: fingerprint)?.importedAt == nil {
                    var annotation = currentAnnotation(forFingerprint: fingerprint) ?? IdentityAnnotation()
                    annotation.importedAt = clock.now()
                    try? annotations.setAnnotation(annotation, forFingerprint: fingerprint)
                }
            }
            await refresh()
            guard case .loaded(let items) = phase else { return nil }
            let imported = items.first { $0.identity.id == identityID }
            importSummary = imported
            return imported
        } catch {
            importError = Self.failureMessage(for: error)
            return nil
        }
    }

    // MARK: - Removal

    /// Removes the registration of `item`.
    ///
    /// The user has already confirmed the removal in the view; this
    /// coordinates the effect. The identity store forgets the registration
    /// (the borrowed key remains owned by its provisioning component), the
    /// local notes are pruned, and a default that named the identity is
    /// cleared. Then the model re-reads, so the screen always reflects
    /// persistence. While the removal runs, `busyItemID` names the item.
    ///
    /// - Returns: Whether the registration was removed.
    @discardableResult
    func remove(_ item: CertificateItem) async -> Bool {
        guard busyItemID == nil else { return false }
        busyItemID = item.id
        defer { busyItemID = nil }
        do {
            try store.removeRegistration(item.identity.id)
            if let annotations {
                try? annotations.removeAnnotation(forFingerprint: item.id)
                if defaultFingerprint == item.id {
                    try? annotations.setDefaultIdentityFingerprint(nil)
                }
            }
            await refresh()
            return true
        } catch {
            notice = Notice(title: Self.removalFailureTitle, message: Self.failureMessage(for: error))
            return false
        }
    }

    // MARK: - Rendering

    /// The user-presentable message for a failure. A typed error's own
    /// user-facing text carries no diagnostic detail; a foreign error is
    /// reduced to a fixed explanation and is never rendered verbatim.
    static func failureMessage(for error: any Error) -> String {
        if let zynSignError = error as? ZynSignError {
            return zynSignError.userMessage
        }
        return "The certificate library could not be accessed."
    }

    /// Clears the announcement once the user has acknowledged it.
    func clearNotice() {
        notice = nil
    }

    /// Clears the import summary once the view has dismissed it.
    func clearImportSummary() {
        importSummary = nil
    }

    /// The item the user marked as the default, when one is loaded.
    var defaultItem: CertificateItem? {
        guard case .loaded(let items) = phase, let defaultFingerprint else { return nil }
        return items.first { $0.id == defaultFingerprint }
    }

    private static let refreshFailureTitle = "Refresh Failed"
    private static let removalFailureTitle = "Removal Failed"
    private static let defaultFailureTitle = "Default Could Not Be Saved"
    private static let labelFailureTitle = "Rename Failed"
    private static let notesUnavailableTitle = "Notes Unavailable"
    private static let notesUnavailableMessage = "Local notes are not available, so this change could not be made."
}
