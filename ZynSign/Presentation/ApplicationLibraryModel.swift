import Foundation
import Combine

/// The presentation-side state machine for the Applications Library screen.
///
/// The model carries exactly one content phase at a time — loading, loaded,
/// empty, or failed — so the screen can never show an empty library while
/// records are still being read, and never silently drops a persistence
/// failure. Removal and import are part of the same machine: while a
/// deletion runs, the entry being removed is named so the view can mark it;
/// a settled import re-reads the library so the new record appears without
/// any manual list editing.
///
/// The model coordinates nothing itself: it invokes the application-layer
/// library use case and the existing import presentation model, and renders
/// the outcomes. Persistence and file work run off the main actor inside
/// the use case; every phase transition happens here, on the main actor.
/// The list is never edited in place — after every change the model re-reads
/// the library from persistence, so what the screen shows is what the
/// library holds.
@MainActor
final class ApplicationLibraryModel: ObservableObject {

    /// The phase of the library's content, rendered directly by the view.
    enum Phase: Equatable {

        /// The library is being read from persistence. The initial phase, so
        /// the screen never presents an empty library as a finding.
        case loading

        /// The library holds the given entries, in library order.
        case loaded([LibraryEntry])

        /// The library was read and holds no records.
        case empty

        /// The library could not be read. Carries a user-presentable
        /// explanation, never diagnostic detail.
        case failed(String)
    }

    /// A transient, user-presentable announcement — an import outcome, or a
    /// failure that did not need to replace the content on screen. The view
    /// renders it as an alert and clears it when acknowledged.
    struct Notice: Equatable, Identifiable {
        let title: String
        let message: String

        var id: String { "\(title)-\(message)" }
    }

    /// The current content phase of the library.
    @Published private(set) var phase: Phase = .loading

    /// The record whose removal is running, so the view can mark the entry.
    /// `nil` whenever no removal is running.
    @Published private(set) var removingRecordID: ApplicationRecordIdentifier?

    /// The announcement to show, if any. Cleared by `clearNotice()` once the
    /// user has acknowledged it.
    @Published private(set) var notice: Notice?

    /// The import presentation model the screen's import action drives. It
    /// is the same phase machine the Import area uses, so this screen adds
    /// no second import flow.
    let importing: PackageImportModel

    private let library: ApplicationLibrary
    private var isReadingLibrary = false
    private var hasPendingRead = false

    /// Creates the model over the library use case and the import
    /// presentation model. The model observes the import's settled outcomes
    /// through the import model's settlement hook.
    init(library: ApplicationLibrary, importing: PackageImportModel) {
        self.library = library
        self.importing = importing
        importing.onSettlement = { [weak self] phase in
            self?.handleImportSettlement(phase)
        }
    }

    // MARK: - Loading

    /// Loads the library when the screen appears. The first load presents
    /// the loading state; once content is on screen the same call acts as a
    /// refresh that keeps the content visible while persistence is read
    /// again — so a record imported in another area appears without the
    /// screen flashing through a loading state, and a failure during such a
    /// refresh never replaces the user's library with an error screen.
    func load() async {
        switch phase {
        case .loaded, .empty:
            await refresh()
        case .loading, .failed:
            await readLibrary(presentingLoadingState: true)
        }
    }

    /// Reads the library again while keeping whatever is on screen.
    func refresh() async {
        await readLibrary(presentingLoadingState: false)
    }

    /// Reads the library and updates the phase. A read already in progress
    /// is not interrupted; a request arriving during one is answered by a
    /// follow-up read, so a refresh can never be lost to a concurrent load.
    private func readLibrary(presentingLoadingState: Bool) async {
        if isReadingLibrary {
            hasPendingRead = true
            return
        }
        isReadingLibrary = true
        defer { isReadingLibrary = false }
        var showLoadingState = presentingLoadingState
        while true {
            if showLoadingState {
                phase = .loading
            }
            do {
                let entries = try await library.entries()
                phase = entries.isEmpty ? .empty : .loaded(entries)
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

    // MARK: - Removal

    /// Removes a library entry: its record and the package file behind it.
    ///
    /// The user has already confirmed the removal in the view; this
    /// coordinates the effect. The library use case owns the persistence and
    /// artifact-ownership rules — the model only invokes it and then re-reads
    /// the library, so the screen always reflects persistence. On failure
    /// the error is announced and the re-read shows what the library
    /// actually holds; nothing is silently dropped.
    ///
    /// While the removal runs, `removingRecordID` names the entry. One
    /// removal runs at a time.
    func remove(_ entry: LibraryEntry) async {
        guard removingRecordID == nil, case .loaded = phase else { return }
        removingRecordID = entry.record.id
        defer { removingRecordID = nil }
        do {
            try await library.remove(recordWithID: entry.record.id)
        } catch {
            notice = Notice(
                title: Self.removalFailureTitle,
                message: Self.failureMessage(for: error)
            )
        }
        await refresh()
    }

    // MARK: - Import integration

    /// Records how the system document picker closed. The outcome is
    /// forwarded to the import model; a picker closed without a selection
    /// is an ordinary cancellation there, not an error.
    func handlePickerResult(_ result: Result<URL, any Error>) {
        importing.handlePickerResult(result)
    }

    /// Cancels a running import.
    func cancelImport() {
        importing.cancelImport()
    }

    /// Reacts to a settled import. A success re-reads the library so the new
    /// record appears immediately; a failure is announced without touching
    /// the library; a cancellation needs no announcement.
    private func handleImportSettlement(_ phase: PackageImportModel.Phase) {
        switch phase {
        case .succeeded(let summary):
            notice = Notice(title: Self.importSuccessTitle, message: summary.libraryMessage)
            Task { await refresh() }
        case .failed(let message):
            notice = Notice(title: Self.importFailureTitle, message: message)
        case .idle, .importing, .cancelled:
            break
        }
    }

    /// Clears the announcement once the user has acknowledged it.
    func clearNotice() {
        notice = nil
    }

    // MARK: - Rendering

    /// The user-presentable message for a failure. A typed error's own
    /// user-facing text carries no diagnostic detail; a foreign error is
    /// reduced to a fixed explanation and is never rendered verbatim.
    static func failureMessage(for error: any Error) -> String {
        if let zynSignError = error as? ZynSignError {
            return zynSignError.userMessage
        }
        return "The library could not be accessed."
    }

    private static let importSuccessTitle = "Import Complete"
    private static let importFailureTitle = "Import Failed"
    private static let removalFailureTitle = "Deletion Failed"
    private static let refreshFailureTitle = "Refresh Failed"
}
