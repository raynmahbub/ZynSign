import Foundation
import Combine

/// The signing history: every operation the journal holds, narrowed and
/// ordered by the user, successes and failures alike.
///
/// The model reads the journal and never edits it to filter: what a person
/// sees is a projection of what is stored. Two facts it keeps straight on the
/// interface's behalf:
///
/// - A failed operation is never presented as a success. The row's mark, its
///   summary, and its stage come from the record's own outcome, and an
///   operation that never delivered an artifact says so.
/// - A record written by an earlier build reads as an operation whose newer
///   detail was not recorded — the same history, with the fields that build
///   did not capture simply absent. Nothing is invented to fill them.
@MainActor
final class SigningHistoryModel: ObservableObject {

    /// What the list is doing.
    enum Phase: Equatable {
        case loading
        case ready
        case failed(String)
    }

    @Published private(set) var phase: Phase = .loading
    @Published private(set) var records: [SigningRecord] = []
    @Published var query = SigningHistoryQuery()
    @Published private(set) var isClearing = false
    @Published var notice: Notice?

    /// A transient message the screen shows once.
    struct Notice: Identifiable, Equatable {
        let id = UUID()
        let title: String
        let message: String
    }

    private let history: any SigningHistoryStore
    private let now: () -> Date

    init(
        history: any SigningHistoryStore,
        now: @escaping () -> Date = { Date() }
    ) {
        self.history = history
        self.now = now
    }

    /// The records the list shows, after the query's filters and ordering.
    var visibleRecords: [SigningRecord] {
        query.apply(to: records, now: now())
    }

    /// Whether the journal holds nothing at all.
    var isEmpty: Bool { records.isEmpty }

    /// Whether the query is hiding everything the journal holds.
    var isFilteredToNothing: Bool { !records.isEmpty && visibleRecords.isEmpty }

    /// How many operations the journal holds that did not deliver output.
    /// Failed and cancelled operations are counted together because the
    /// interface asks one question: how many did not produce a signed
    /// artifact.
    var unsuccessfulCount: Int {
        records.filter { $0.outcome != .succeeded }.count
    }

    // MARK: - Loading

    func load() async {
        do {
            records = try await history.allRecords()
            phase = .ready
        } catch {
            phase = .failed((error as? ZynSignError)?.userMessage
                ?? "The signing history could not be read.")
        }
    }

    // MARK: - Maintenance

    /// Clears the journal. Offered by the history screen's own control, and
    /// separate from the storage screen's "old records" cleanup, which keeps
    /// the recent records whatever their age.
    func clear() async {
        guard !isClearing else { return }
        isClearing = true
        defer { isClearing = false }
        do {
            try await history.clear()
            records = []
            notice = Notice(
                title: "History Cleared",
                message: "The signing history was cleared. Your exported artifacts and imported applications are untouched."
            )
        } catch {
            notice = Notice(
                title: "Could Not Clear History",
                message: (error as? ZynSignError)?.userMessage
                    ?? "The signing history could not be cleared."
            )
        }
    }
}
