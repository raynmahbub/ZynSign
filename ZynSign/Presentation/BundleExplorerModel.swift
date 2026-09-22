import Foundation

/// The presentation-side state machine for the bundle explorer.
///
/// The model carries exactly one content phase at a time — loading, loaded,
/// empty, or failed — so the explorer can never show an empty bundle while
/// the package is still being read, and never silently drops a failure.
/// The bundle's structure is read once: the loaded phase carries a
/// `BundleContents` value, and every directory the user descends into is
/// answered from that value. Nothing the explorer does after the first
/// read touches the package again.
///
/// The model coordinates nothing itself: it invokes the application-layer
/// inspection use case and renders the outcome. Reading the package runs
/// off the main actor inside the use case; every phase transition happens
/// here, on the main actor.
@MainActor
final class BundleExplorerModel: ObservableObject {

    /// The phase of the explorer's content, rendered directly by the view.
    enum Phase: Equatable {

        /// The package is being read. The initial phase, so the explorer
        /// never presents an empty bundle as a finding.
        case loading

        /// The bundle's structure is known and holds at least one entry.
        case loaded(BundleContents)

        /// The bundle was read and holds no entries at all. Carries the
        /// bundle's name so the screen can still be titled.
        case empty(bundleName: String)

        /// The bundle could not be read. Carries a user-presentable
        /// explanation, never diagnostic detail.
        case failed(String)
    }

    /// The current content phase of the explorer.
    @Published private(set) var phase: Phase = .loading

    private let inspection: IPABundleContentsInspection
    private let recordID: ApplicationRecordIdentifier
    private var isInspecting = false

    /// Creates the model for the application recorded under `recordID`,
    /// over the inspection use case the composition root supplied.
    init(inspection: IPABundleContentsInspection, recordID: ApplicationRecordIdentifier) {
        self.inspection = inspection
        self.recordID = recordID
    }

    /// Reads the bundle's structure when the explorer appears.
    ///
    /// The call is idempotent once content is on screen: a view that is
    /// recomputed and calls again enumerates nothing, because the library's
    /// package does not change underneath a record. A call after a failure
    /// tries again, presenting the loading state. A call that arrives while
    /// a read is already running is ignored rather than queued; the running
    /// read's outcome is the answer to both.
    func load() async {
        switch phase {
        case .loaded, .empty:
            return
        case .loading, .failed:
            break
        }
        guard !isInspecting else { return }
        isInspecting = true
        defer { isInspecting = false }
        phase = .loading
        do {
            let contents = try await inspection.inspect(recordWithID: recordID)
            phase = contents.isEmpty ? .empty(bundleName: contents.bundleName) : .loaded(contents)
        } catch is CancellationError {
            // The explorer went away while the package was being read; there
            // is nothing to show and nobody to report to. The phase stays
            // `loading`, so an explorer that comes back reads again.
        } catch {
            phase = .failed(Self.failureMessage(for: error))
        }
    }

    /// The bundle's structure, once loaded; `nil` in every other phase.
    var contents: BundleContents? {
        if case .loaded(let contents) = phase {
            return contents
        }
        return nil
    }

    /// The entries directly inside `directory`, in listing order, answered
    /// from the loaded structure; `nil` before the structure is loaded or
    /// when the bundle holds no such directory.
    func entries(in directory: BundlePath) -> [BundleEntry]? {
        contents?.entries(in: directory)
    }

    /// The user-presentable message for a failure. A typed error's own
    /// user-facing text carries no diagnostic detail; a foreign error is
    /// reduced to a fixed explanation and is never rendered verbatim.
    static func failureMessage(for error: any Error) -> String {
        if let zynSignError = error as? ZynSignError {
            return zynSignError.userMessage
        }
        return "The application's contents could not be read."
    }
}
