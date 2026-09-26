import Foundation
import Combine

/// Presentation state for the Binary & Signature Inspector.
///
/// The model runs one bundle pass through the inspection use case and applies
/// its events as they arrive, so each executable's card fills in as soon as
/// its structure is known and again when its verification completes. It holds
/// only value reports — never executable bytes — and every phase transition
/// happens on the main actor. Reading, parsing, and hashing run inside the use
/// case, off the main actor.
@MainActor
final class BinaryInspectorModel: ObservableObject {

    enum Phase: Equatable {
        /// The package is being opened and its executables found.
        case loading
        /// The executables are known; each carries its own progress.
        case loaded
        /// The package could not be opened. A user-presentable message.
        case failed(String)
    }

    /// The state of an on-demand sealed-resource verification.
    enum SealedResourceState: Equatable {
        case running
        case finished(SealedResourceVerification)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .loading
    @Published private(set) var overview: BinaryBundleOverview?
    @Published private(set) var progress: [String: BinaryTargetProgress] = [:]
    /// Verification progress from zero to one, while a target is verifying.
    @Published private(set) var verificationFraction: [String: Double] = [:]
    @Published private(set) var sealedResources: [String: SealedResourceState] = [:]
    /// The dashboard's search text. Results update on every change.
    @Published var searchText: String = ""

    let applicationName: String
    let bundleIdentifier: String?
    let source: BinaryInspectionSource
    let generator: String
    let inspection: IPABinaryInspection

    private var isRunning = false
    private var searchIndexes: [String: (report: BinaryInspectionReport, index: BinarySearchIndex)] = [:]

    init(
        inspection: IPABinaryInspection,
        source: BinaryInspectionSource,
        applicationName: String,
        bundleIdentifier: String?,
        generator: String
    ) {
        self.inspection = inspection
        self.source = source
        self.applicationName = applicationName
        self.bundleIdentifier = bundleIdentifier
        self.generator = generator
    }

    // MARK: - Loading

    /// Runs the bundle pass when the inspector appears. A pass that already
    /// finished is not repeated; `reload()` forces a new one.
    func load() async {
        if case .loaded = phase, !progress.isEmpty, progress.values.allSatisfy(\.isFinished) {
            return
        }
        await run()
    }

    /// Discards the current results and inspects the package again.
    func reload() async {
        await run()
    }

    private func run() async {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }
        phase = .loading
        overview = nil
        progress = [:]
        verificationFraction = [:]
        searchIndexes = [:]
        do {
            for try await event in inspection.inspectBundle(source) {
                apply(event)
            }
            if overview == nil, !Task.isCancelled {
                phase = .failed("The application's executables could not be listed.")
            }
        } catch is CancellationError {
            // The inspector went away; the next appearance inspects again.
        } catch {
            phase = .failed(Self.failureMessage(for: error))
        }
    }

    /// Applies one event from the use case. Internal so tests can drive the
    /// state machine without a package.
    func apply(_ event: BinaryInspectionEvent) {
        switch event {
        case .discovered(let overview):
            self.overview = overview
            var initial: [String: BinaryTargetProgress] = [:]
            for target in overview.targets {
                initial[target.id] = .pending
            }
            progress = initial
            phase = .loaded
        case .targetStarted(let targetID):
            progress[targetID] = .inspecting
        case .structureReady(let report):
            progress[report.id] = .structureReady(report)
            verificationFraction[report.id] = 0
        case .verificationProgress(let targetID, let completed, let total):
            verificationFraction[targetID] = total > 0 ? min(1, Double(completed) / Double(total)) : 0
        case .completed(let report):
            progress[report.id] = .completed(report)
            verificationFraction[report.id] = nil
        case .unavailable(let targetID, let limitation):
            progress[targetID] = .unavailable(limitation)
            verificationFraction[targetID] = nil
        }
    }

    // MARK: - Derived state

    var targets: [BinaryTarget] { overview?.targets ?? [] }

    func state(for target: BinaryTarget) -> BinaryTargetProgress {
        progress[target.id] ?? .pending
    }

    func report(for target: BinaryTarget) -> BinaryInspectionReport? {
        progress[target.id]?.report
    }

    var finishedCount: Int { progress.values.filter(\.isFinished).count }

    var isFinished: Bool {
        !targets.isEmpty && finishedCount == targets.count
    }

    /// Reports that have finished verification, in dashboard order.
    var completedReports: [BinaryInspectionReport] {
        targets.compactMap { target in
            if case .completed(let report) = state(for: target) { return report }
            return nil
        }
    }

    /// The bundle-level Nested Signatures check.
    var nestedSignaturesCheck: BinaryVerificationCheck {
        NestedSignatureEvaluation.check(
            nestedTargets: overview?.nestedTargets ?? [],
            progress: progress,
            omittedTargetCount: overview?.omittedTargetCount ?? 0
        )
    }

    // MARK: - Search

    /// Search results across every inspected executable, grouped by target.
    func searchResults(for query: String) -> [BinarySearchGroup] {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        return targets.compactMap { target -> BinarySearchGroup? in
            guard let targetReport = self.report(for: target) else { return nil }
            let matches = searchIndex(for: targetReport).search(query, limit: 100)
            if matches.isEmpty { return nil }
            return BinarySearchGroup(target: target, entries: matches)
        }
    }

    /// The search index for a report, built once per report state.
    func searchIndex(for report: BinaryInspectionReport) -> BinarySearchIndex {
        if let cached = searchIndexes[report.id], cached.report == report {
            return cached.index
        }
        let index = BinarySearchIndex(report: report)
        searchIndexes[report.id] = (report, index)
        return index
    }

    // MARK: - Sealed resources

    func sealedResourceState(for target: BinaryTarget) -> SealedResourceState? {
        sealedResources[target.id]
    }

    /// Re-hashes every sealed file of `target`'s bundle on demand.
    func verifySealedResources(for target: BinaryTarget) async {
        if case .some(.running) = sealedResources[target.id] { return }
        sealedResources[target.id] = .running
        do {
            let result = try await inspection.verifySealedResources(of: target, in: source)
            sealedResources[target.id] = .finished(result)
        } catch is CancellationError {
            sealedResources[target.id] = nil
        } catch {
            sealedResources[target.id] = .failed(Self.failureMessage(for: error))
        }
    }

    // MARK: - Export

    /// Writes a read-only report for `reports` to a temporary file and
    /// returns its location, for the share sheet.
    func exportFile(for reports: [BinaryInspectionReport], format: BinaryInspectionExportFormat) throws -> URL {
        let includesMain = reports.contains { $0.target.kind == .mainExecutable }
        let context = BinaryInspectionExportContext(
            applicationName: applicationName,
            bundleIdentifier: bundleIdentifier,
            generatedAt: Date(),
            generator: generator,
            nestedSignatures: includesMain ? nestedSignaturesCheck : nil
        )
        let data = BinaryInspectionReportRenderer.render(reports, context: context, format: format)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZynSign-Export", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = BinaryInspectionReportRenderer.suggestedFileName(
            applicationName: applicationName,
            executableName: reports.count == 1 ? reports.first?.target.name : nil,
            format: format
        )
        let url = directory.appendingPathComponent(name, isDirectory: false)
        try data.write(to: url, options: .atomic)
        return url
    }

    /// The user-presentable message for a failure. A typed error's own text
    /// carries no diagnostic detail; anything else is reduced to a fixed
    /// explanation.
    static func failureMessage(for error: any Error) -> String {
        if let zynSignError = error as? ZynSignError {
            return zynSignError.userMessage
        }
        return "The application's executables could not be inspected."
    }
}

/// The search results for one executable.
struct BinarySearchGroup: Identifiable, Equatable {
    let target: BinaryTarget
    let entries: [BinarySearchEntry]

    var id: String { target.id }
}
