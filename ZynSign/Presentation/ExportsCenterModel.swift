import Foundation
import Combine

/// The Export Center's artifact list and the actions a row offers.
///
/// The model reads the export catalog through the export use case, derives
/// each artifact's availability from export storage on every load, and never
/// edits the catalog to filter it: what a person sees is a projection of what
/// is stored, narrowed and ordered by `ExportQuery`.
///
/// Three rules it enforces on the interface's behalf:
///
/// - An action that needs the artifact's bytes is offered only while the
///   artifact is available. A row whose file is gone says so and disables
///   sharing, verifying, and revealing rather than presenting a control that
///   cannot work.
/// - Deleting an export removes the signed artifact and its record, and
///   nothing else. The imported application it was signed from, its other
///   exports, and the signing history are not touched — the model has no code
///   path that could.
/// - A verification result is always the result of reopening the artifact.
///   The row's status changes only after a verification actually ran, or
///   after the catalog says one ran earlier.
@MainActor
final class ExportsCenterModel: ObservableObject {

    /// What the list is doing.
    enum Phase: Equatable {
        case loading
        case ready
        case failed(String)
    }

    /// A transient message the screen shows once.
    struct Notice: Identifiable, Equatable {
        let id = UUID()
        let title: String
        let message: String
    }

    /// The verification report the screen is showing, with the artifact it
    /// belongs to.
    struct VerificationPresentation: Identifiable, Equatable {
        let id: ExportIdentifier
        let fileName: String
        let report: ArtifactVerificationReport

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.id == rhs.id
                && lhs.fileName == rhs.fileName
                && lhs.report.verifiedAt == rhs.report.verifiedAt
                && lhs.report.status == rhs.report.status
        }
    }

    @Published private(set) var phase: Phase = .loading
    @Published private(set) var entries: [ExportEntry] = []
    @Published private(set) var operationRecords: [SigningRecord] = []
    @Published var query = ExportQuery()
    @Published var notice: Notice?
    @Published private(set) var verifyingIDs: Set<ExportIdentifier> = []
    @Published private(set) var removingIDs: Set<ExportIdentifier> = []
    @Published var verificationPresentation: VerificationPresentation?

    private let exports: ExportCenter
    private let history: (any SigningHistoryStore)?
    private let verifyExport: (ExportIdentifier) async throws -> ExportedArtifactVerification
    private let now: () -> Date

    init(
        exports: ExportCenter,
        history: (any SigningHistoryStore)? = nil,
        verifyExport: @escaping (ExportIdentifier) async throws -> ExportedArtifactVerification,
        now: @escaping () -> Date = { Date() }
    ) {
        self.exports = exports
        self.history = history
        self.verifyExport = verifyExport
        self.now = now
    }

    /// The entries the list shows, after the query's filters and ordering.
    var visibleEntries: [ExportEntry] {
        query.apply(to: entries, now: now())
    }

    /// Whether the catalog holds nothing at all, as opposed to nothing
    /// matching the query.
    var isEmpty: Bool { entries.isEmpty }

    /// Whether the query is hiding everything the catalog holds.
    var isFilteredToNothing: Bool { !entries.isEmpty && visibleEntries.isEmpty }

    /// The total bytes of the artifacts the list shows.
    var visibleByteCount: Int {
        visibleEntries.reduce(0) { $0 + $1.record.byteCount }
    }

    /// How many of the listed artifacts are no longer on the device.
    var unavailableCount: Int {
        entries.filter { !$0.isAvailable }.count
    }

    // MARK: - Loading

    /// Loads the catalog and the operation records the detail screens link
    /// from. A catalog that cannot be read is reported as a failure state
    /// rather than shown as an empty list: an unreadable catalog and an empty
    /// one are different facts.
    func load() async {
        do {
            entries = try await exports.entries()
            phase = .ready
        } catch {
            phase = .failed((error as? ZynSignError)?.userMessage
                ?? "The Export Center could not be read.")
            return
        }
        await loadOperationRecords()
    }

    /// Loads the signing journal, for linking an artifact to the operation
    /// that produced it. A journal that cannot be read is not a failure of
    /// the Export Center: the artifacts are still listed, and the detail
    /// screen simply has no operation to show.
    func loadOperationRecords() async {
        guard let history else { return }
        operationRecords = (try? await history.allRecords()) ?? []
    }

    /// The operation that produced `record`, when the journal still holds it.
    func operationRecord(for record: ExportRecord) -> SigningRecord? {
        operationRecords.first { $0.exportIdentifier == record.id.rawValue }
    }

    /// The current export record behind an operation's stored identifier,
    /// when the catalog still holds it. The export record is where the latest
    /// verification result lives, so an operation detail can say what is true
    /// now without changing what the operation recorded then.
    func exportEntry(for operation: SigningRecord) -> ExportEntry? {
        guard let identifier = operation.exportID else { return nil }
        return entries.first { $0.record.id == identifier }
    }

    // MARK: - Verification

    /// Reopens the artifact and verifies it independently, then shows the
    /// report. The list's status is replaced by the updated record's, so the
    /// row agrees with the report the user is looking at.
    func verify(_ entry: ExportEntry) async {
        guard !verifyingIDs.contains(entry.record.id) else { return }
        verifyingIDs.insert(entry.record.id)
        defer { verifyingIDs.remove(entry.record.id) }
        do {
            let result = try await verifyExport(entry.record.id)
            replace(result.record)
            verificationPresentation = VerificationPresentation(
                id: result.record.id,
                fileName: result.record.fileName,
                report: result.report
            )
        } catch is CancellationError {
            return
        } catch {
            notice = Notice(
                title: "Verification Could Not Run",
                message: (error as? ZynSignError)?.userMessage
                    ?? "The artifact could not be verified."
            )
        }
    }

    // MARK: - Delivery

    /// Records that the artifact was handed to the system share sheet and the
    /// sheet completed, so the row can say when it was last exported.
    func markDelivered(_ entry: ExportEntry) async {
        do {
            let updated = try await exports.recordDelivery(for: entry.record.id)
            replace(updated)
        } catch {
            // A delivery mark is a courtesy, not the artifact: failing to
            // record it never invalidates an export that happened.
        }
    }

    // MARK: - Removal

    /// Removes one exported artifact and its record. The imported application
    /// it was signed from is untouched, and so is the signing history.
    func remove(_ entry: ExportEntry) async {
        guard !removingIDs.contains(entry.record.id) else { return }
        removingIDs.insert(entry.record.id)
        defer { removingIDs.remove(entry.record.id) }
        do {
            let removal = try await exports.remove(entry.record.id)
            entries.removeAll { $0.record.id == removal.identifier }
            notice = Notice(
                title: "Exported Artifact Deleted",
                message: removal.freedByteCount > 0
                    ? "“\(removal.fileName)” was deleted from ZynSign's export storage. The application it was signed from is still in your library."
                    : "“\(removal.fileName)” was removed from the Export Center. Its file was already gone, and the application it was signed from is still in your library."
            )
        } catch {
            notice = Notice(
                title: "Could Not Delete Export",
                message: (error as? ZynSignError)?.userMessage
                    ?? "The exported artifact could not be deleted."
            )
        }
    }

    // MARK: - Helpers

    private func replace(_ record: ExportRecord) {
        if let index = entries.firstIndex(where: { $0.record.id == record.id }) {
            entries[index] = ExportEntry(
                record: record,
                availability: entries[index].availability,
                fileURL: entries[index].fileURL
            )
        } else {
            // A record the catalog holds but the list did not: reload so the
            // list and the catalog agree rather than inventing an availability.
            Task { await load() }
        }
    }
}
