import Foundation
import Combine
import SwiftUI
import UniformTypeIdentifiers

/// The presentation-side state machine for the Profiles section, rebuilt as the
/// Provisioning Profile Manager.
///
/// One content phase at a time — loading, loaded, empty, failed — so the
/// screen never shows an empty library while profiles are still being read.
/// Import and removal re-read the library after they settle, so the screen
/// always shows what the profile library holds.
///
/// On top of the library read, the model computes one compatibility report
/// per profile (the pre-sign checks with no app selected, so bundle matching
/// honestly reports "not checked") and observes the user's pinned
/// "Use for Signing" profile. Search, sort, and filters are pure static
/// projections of the phase — never edits to it — which keeps the rules
/// testable without views.
@MainActor
final class ProvisioningProfilesModel: ObservableObject {

    // MARK: - Content

    enum Phase: Equatable {
        case loading
        case loaded([ProvisioningProfileSummary])
        case empty
        case failed(String)
    }

    /// How the manager orders its profiles.
    enum SortOrder: String, CaseIterable, Identifiable {

        /// Soonest to expire first, expired profiles sunk to the end — the
        /// order that makes the quietest failure the loudest.
        case expiration

        /// By name, the way a Contacts list sorts.
        case name

        /// Most recently imported first.
        case recentlyImported

        /// By distribution type, then by expiration.
        case type

        var id: Self { self }

        var displayName: String {
            switch self {
            case .expiration: return "Expiration"
            case .name: return "Name"
            case .recentlyImported: return "Recently Imported"
            case .type: return "Profile Type"
            }
        }
    }

    /// The distribution-type filter offered in the filter menu.
    enum TypeFilter: String, CaseIterable, Identifiable {
        case all
        case development
        case adHoc
        case appStore
        case enterprise
        case unknown

        var id: Self { self }

        var displayName: String {
            switch self {
            case .all: return "Any Type"
            case .development: return ProvisioningProfileClassification.development.displayName
            case .adHoc: return ProvisioningProfileClassification.adHoc.displayName
            case .appStore: return ProvisioningProfileClassification.appStore.displayName
            case .enterprise: return ProvisioningProfileClassification.enterprise.displayName
            case .unknown: return ProvisioningProfileClassification.unknown.displayName
            }
        }

        /// Whether a profile passes this filter.
        func includes(_ summary: ProvisioningProfileSummary) -> Bool {
            switch self {
            case .all: return true
            case .development: return summary.resolvedProfileType == .development
            case .adHoc: return summary.resolvedProfileType == .adHoc
            case .appStore: return summary.resolvedProfileType == .appStore
            case .enterprise: return summary.resolvedProfileType == .enterprise
            case .unknown: return summary.resolvedProfileType == .unknown
            }
        }
    }

    /// The expiration-state filter offered in the filter menu.
    enum ExpirationFilter: String, CaseIterable, Identifiable {
        case all
        case healthy
        case expiringSoon
        case expired

        var id: Self { self }

        var displayName: String {
            switch self {
            case .all: return "Any Expiration"
            case .healthy: return ProfileExpirationState.healthy.displayName
            case .expiringSoon: return ProfileExpirationState.expiringSoon.displayName
            case .expired: return ProfileExpirationState.expired.displayName
            }
        }

        /// Whether a profile passes this filter at `referenceDate`.
        func includes(
            _ summary: ProvisioningProfileSummary,
            referenceDate: Date
        ) -> Bool {
            switch self {
            case .all: return true
            case .healthy, .expiringSoon, .expired:
                let state = summary.expirationAssessment(referenceDate: referenceDate).state
                switch self {
                case .healthy: return state == .healthy
                case .expiringSoon: return state == .expiringSoon
                case .expired: return state == .expired
                case .all: return true
                }
            }
        }
    }

    /// A transient, user-presentable announcement — an import outcome, a
    /// removal failure, or a refresh failure that did not need to replace
    /// the content on screen.
    struct Notice: Equatable, Identifiable {
        let title: String
        let message: String

        var id: String { "\(title)-\(message)" }
    }

    // MARK: - Published state

    @Published private(set) var phase: Phase = .loading
    @Published var searchText = ""
    @Published var sortOrder: SortOrder = .expiration
    @Published var typeFilter: TypeFilter = .all
    @Published var expirationFilter: ExpirationFilter = .all

    /// One compatibility report per loaded profile, computed with no app
    /// selected at the last read.
    @Published private(set) var reports: [ProvisioningProfileIdentifier: ProfileCompatibilityReport] = [:]

    /// The profile pinned by "Use for Signing", as observed at the last
    /// read; cards show a "Selected" marker on it.
    @Published private(set) var preferredProfileID: ProvisioningProfileIdentifier?

    @Published private(set) var isImporting = false
    @Published var isShowingImporter = false
    @Published private(set) var notice: Notice?

    /// The profile awaiting a confirmed removal, if any.
    @Published var pendingRemoval: ProvisioningProfileSummary?

    /// The freshly imported profile, driving the import-summary sheet.
    @Published var importedProfile: ProvisioningProfileSummary?

    /// The profile to push after the import-summary sheet closes, driving
    /// the detail screen from "View Details".
    @Published var pendingDetail: ProvisioningProfileSummary?

    /// Transient toast state: a short confirmation ("Team ID copied",
    /// "selected for signing") that should not interrupt with an alert.
    @Published var isShowingToast = false
    @Published private(set) var toastMessage = ""
    @Published private(set) var toastStyle: ZToast.Style = .success

    // MARK: - Dependencies

    private let profiles: ProvisioningProfileLibrary?
    private let importer: ProvisioningProfileImporter?
    private let compatibility: ProfileCompatibilityUseCase?
    private let selections: (any ProfileSelectionStore)?
    private let recordEvent: ((String, Bool) -> Void)?

    /// The content types the profile picker offers: the `.mobileprovision`
    /// extension type when the system can form it, with `.data` as the
    /// supertype that keeps the file selectable regardless of how the
    /// provider reports it. The importer re-checks the file either way.
    static var importableTypes: [UTType] {
        var types: [UTType] = []
        if let mobileprovision = UTType(filenameExtension: "mobileprovision", conformingTo: .data) {
            types.append(mobileprovision)
        }
        if let plain = UTType(filenameExtension: "mobileprovision") {
            types.append(plain)
        }
        types.append(.data)
        return types
    }

    init(
        profiles: ProvisioningProfileLibrary?,
        importer: ProvisioningProfileImporter?,
        compatibility: ProfileCompatibilityUseCase? = nil,
        selections: (any ProfileSelectionStore)? = nil,
        recordEvent: ((String, Bool) -> Void)? = nil
    ) {
        self.profiles = profiles
        self.importer = importer
        self.compatibility = compatibility
        self.selections = selections
        self.recordEvent = recordEvent
        self.preferredProfileID = selections?.preferredProfileID()
    }

    /// Whether importing is possible in this composition. A missing library
    /// or a missing importer both mean no.
    var canImport: Bool {
        profiles != nil && importer != nil
    }

    func showImporter() {
        guard canImport else { return }
        isShowingImporter = true
    }

    // MARK: - Loading

    /// Loads the profiles when the screen appears. A refresh keeps content
    /// on screen and announces failure instead of replacing it.
    func load() async {
        switch phase {
        case .loaded, .empty:
            await refresh()
        case .loading, .failed:
            await readProfiles(presentingLoadingState: true)
        }
    }

    func refresh() async {
        await readProfiles(presentingLoadingState: false)
    }

    private func readProfiles(presentingLoadingState: Bool) async {
        guard let profiles else {
            phase = .failed("The profile library is not part of this build's composition.")
            return
        }
        if presentingLoadingState {
            phase = .loading
        }
        do {
            let summaries = try await profiles.allProfiles()
            phase = summaries.isEmpty ? .empty : .loaded(summaries)
            reports = compatibility?.reports(for: summaries) ?? [:]
            preferredProfileID = selections?.preferredProfileID()
        } catch {
            let message = (error as? ZynSignError)?.userMessage ?? "The profile library could not be accessed."
            if presentingLoadingState {
                phase = .failed(message)
            } else {
                notice = Notice(title: "Refresh Failed", message: message)
            }
        }
    }

    // MARK: - Projection

    /// The profiles the screen shows for the current search text, sort
    /// order, and filters. The phase is never edited — this is a pure
    /// projection of it.
    func visibleProfiles() -> [ProvisioningProfileSummary] {
        guard case .loaded(let summaries) = phase else { return [] }
        return Self.displayed(
            summaries,
            matching: searchText,
            sortedBy: sortOrder,
            typeFilter: typeFilter,
            expirationFilter: expirationFilter,
            referenceDate: Date()
        )
    }

    /// Whether `summary` matches `query`: a case-insensitive substring of
    /// the profile's name, team name, team ID, UUID, App ID, bundle
    /// identifier, or any declared pattern. An empty query matches
    /// everything. Internal so the rule is testable without views.
    static func matches(_ summary: ProvisioningProfileSummary, query: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return true }
        let haystacks: [String?] = [
            summary.name,
            summary.teamName,
            summary.teamIdentifier,
            summary.uuid,
            summary.applicationIdentifier,
            summary.bundleIdentifier,
        ]
        if haystacks.contains(where: { ($0 ?? "").lowercased().contains(needle) }) {
            return true
        }
        return summary.bundleIdentifierPatterns.contains {
            $0.lowercased().contains(needle)
        }
    }

    /// The profiles ordered by `order`. Internal so the rule is testable.
    static func ordered(
        _ summaries: [ProvisioningProfileSummary],
        by order: SortOrder
    ) -> [ProvisioningProfileSummary] {
        switch order {
        case .expiration:
            return summaries.sorted(by: ProvisioningProfileSummary.sortByExpiration)
        case .name:
            return summaries.sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        case .recentlyImported:
            return summaries.sorted {
                if $0.importedAt != $1.importedAt { return $0.importedAt > $1.importedAt }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        case .type:
            return summaries.sorted {
                let lhs = $0.resolvedProfileType.displayName
                let rhs = $1.resolvedProfileType.displayName
                if lhs != rhs { return lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending }
                return $0.expirationDate < $1.expirationDate
            }
        }
    }

    /// The full projection: search, then type filter, then expiration
    /// filter, then sort. Internal so every rule is testable without views.
    static func displayed(
        _ summaries: [ProvisioningProfileSummary],
        matching query: String,
        sortedBy order: SortOrder,
        typeFilter: TypeFilter,
        expirationFilter: ExpirationFilter,
        referenceDate: Date
    ) -> [ProvisioningProfileSummary] {
        let searched = summaries.filter { matches($0, query: query) }
        let typed = searched.filter { typeFilter.includes($0) }
        let filtered = typed.filter { expirationFilter.includes($0, referenceDate: referenceDate) }
        return ordered(filtered, by: order)
    }

    /// The compatibility report for one profile, if it was computed.
    func report(for summary: ProvisioningProfileSummary) -> ProfileCompatibilityReport? {
        reports[summary.id]
    }

    // MARK: - Import

    /// Records how the system picker closed and, when a file was chosen,
    /// imports it. Cancellation stays quiet; picker failures and refused files
    /// are announced instead of disappearing. A successful import presents
    /// the import summary sheet and re-reads the library.
    func handlePickerResult(_ result: Result<[URL], any Error>) {
        let urls: [URL]
        switch result {
        case .success(let selectedURLs):
            urls = selectedURLs
        case .failure(let error):
            let cocoaError = error as NSError
            guard !(cocoaError.domain == NSCocoaErrorDomain && cocoaError.code == NSUserCancelledError),
                  !(error is CancellationError) else { return }
            notice = Notice(
                title: "Couldn't Open Profile",
                message: (error as? ZynSignError)?.userMessage
                    ?? "The selected profile could not be opened. Save it to Files and try again."
            )
            return
        }
        guard let url = urls.first else { return }
        guard let importer, let profiles else { return }
        isImporting = true
        Task {
            defer { isImporting = false }
            do {
                let summary = try await importer.importProfile(at: url)
                try await profiles.upsert(summary)
                NotificationCenter.default.post(name: .zynsignProvisioningProfilesChanged, object: nil)
                recordEvent?("profile.imported", true)
                importedProfile = summary
                await refresh()
            } catch let error as ZynSignError {
                recordEvent?("profile.importFailed", false)
                notice = Self.notice(for: error)
            } catch {
                recordEvent?("profile.importFailed", false)
                notice = Notice(title: "Import Failed", message: "The profile could not be imported.")
            }
        }
    }

    /// The announcement for a typed import failure. An unsupported format
    /// says so in its own title; everything else keeps "Import Failed".
    static func notice(for error: ZynSignError) -> Notice {
        let title: String
        if let failure = error.provisioningProfileFailure, failure.category == .unsupportedInput {
            title = "Unsupported Profile"
        } else {
            title = "Import Failed"
        }
        return Notice(title: title, message: error.userMessage)
    }

    // MARK: - Quick actions

    /// Pins the profile "Use for Signing" refers to. Suggestion screens
    /// offer it first for apps it suits; it is a preference, not a claim
    /// that the profile fits every app.
    func useForSigning(_ summary: ProvisioningProfileSummary) {
        selections?.setPreferredProfile(summary.id)
        preferredProfileID = selections?.preferredProfileID()
    }

    /// Re-reads the stored `.mobileprovision` file behind `summary`,
    /// updates the library with the fresh facts, and re-runs the
    /// compatibility reports. A missing or unreadable file is announced
    /// with the typed reason; the library keeps the old summary.
    func refreshValidation(_ summary: ProvisioningProfileSummary) async {
        guard let importer, let profiles else { return }
        do {
            let refreshed = try await importer.refresh(summary)
            try await profiles.upsert(refreshed)
            NotificationCenter.default.post(name: .zynsignProvisioningProfilesChanged, object: nil)
            recordEvent?("profile.refreshed", true)
        } catch let error as ZynSignError {
            recordEvent?("profile.refreshed", false)
            notice = Notice(
                title: "Refresh Failed",
                message: error.userMessage
            )
        } catch {
            recordEvent?("profile.refreshed", false)
            notice = Notice(title: "Refresh Failed", message: "The profile could not be re-validated.")
        }
        await refresh()
    }

    /// Requests removal; the view confirms before calling `remove(_:)`.
    func requestRemoval(_ summary: ProvisioningProfileSummary) {
        pendingRemoval = summary
    }

    /// Clears the announcement once the user has acknowledged it.
    func clearNotice() {
        notice = nil
    }

    /// Shows a short confirmation toast.
    func toast(_ message: String, style: ZToast.Style = .success) {
        toastMessage = message
        toastStyle = style
        isShowingToast = true
    }

    /// Removes the profile and its stored file, then re-reads the library.
    /// A pinned or overridden selection pointing at the removed profile
    /// reads back as unresolvable, so no separate cleanup is needed.
    func remove(_ summary: ProvisioningProfileSummary) async {
        guard let profiles else { return }
        do {
            try await profiles.remove(profileWithID: summary.id)
            recordEvent?("profile.removed", true)
        } catch {
            recordEvent?("profile.removed", false)
            notice = Notice(
                title: "Deletion Failed",
                message: (error as? ZynSignError)?.userMessage ?? "The profile could not be deleted."
            )
        }
        // Catalog deletion can succeed even when file cleanup reports an
        // error; either way signing must re-read its chosen stored bytes.
        NotificationCenter.default.post(name: .zynsignProvisioningProfilesChanged, object: nil)
        await refresh()
    }
}
