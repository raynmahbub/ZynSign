import Foundation
import Combine

/// Presentation state for one application's rich, read-only details screen.
///
/// The model keeps the last complete report visible while a user refreshes.
/// Inspection itself belongs to the application use case; this model only
/// moves between loading, loaded, and failed states.
@MainActor
final class ApplicationDetailsModel: ObservableObject {

    enum Phase: Equatable {
        case loading
        case loaded(ApplicationDetailsInspectionReport)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .loading
    @Published private(set) var isRefreshing = false

    private let inspection: IPAApplicationDetailsInspection
    private let recordID: ApplicationRecordIdentifier
    private var isInspecting = false

    init(inspection: IPAApplicationDetailsInspection, recordID: ApplicationRecordIdentifier) {
        self.inspection = inspection
        self.recordID = recordID
    }

    var report: ApplicationDetailsInspectionReport? {
        if case .loaded(let report) = phase { return report }
        return nil
    }

    /// Loads once when the details screen appears. A failed initial load may
    /// be retried by appearing again or using the explicit refresh action.
    func load() async {
        if case .loaded = phase { return }
        await inspect(preservingReport: false)
    }

    /// Re-reads archive metadata and diagnostics. A previously loaded report
    /// remains available until the replacement inspection completes.
    func refresh() async {
        await inspect(preservingReport: true)
    }

    private func inspect(preservingReport: Bool) async {
        guard !isInspecting else { return }
        isInspecting = true
        isRefreshing = true
        refreshFailure = nil
        defer {
            isInspecting = false
            isRefreshing = false
        }

        if !preservingReport || report == nil {
            phase = .loading
        }

        do {
            let result = try await inspection.inspect(recordWithID: recordID)
            phase = .loaded(result)
        } catch is CancellationError {
            // A cancelled read does not replace a report the user was already
            // looking at. The initial screen returns to its loading phase.
            if report == nil { phase = .loading }
        } catch {
            let message = Self.failureMessage(for: error)
            if preservingReport, report != nil {
                // Keep the last known report visible; the error is surfaced
                // separately by the view as a refresh notice.
                refreshFailure = message
            } else {
                phase = .failed(message)
            }
        }
    }

    /// A refresh failure that did not displace the last complete report.
    @Published private(set) var refreshFailure: String?

    func clearRefreshFailure() {
        refreshFailure = nil
    }

    static func failureMessage(for error: any Error) -> String {
        if let zynSignError = error as? ZynSignError {
            return zynSignError.userMessage
        }
        return "The application details could not be refreshed."
    }
}
