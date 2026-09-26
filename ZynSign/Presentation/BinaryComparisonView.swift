import SwiftUI
import Combine

/// Presentation state for comparing one executable with the same executable
/// in another package — for example an imported original and its signed
/// output.
@MainActor
final class BinaryComparisonModel: ObservableObject {

    enum Phase: Equatable {
        case choosing
        case comparing(BinaryComparisonCandidate)
        case compared(BinaryComparisonCandidate, BinaryComparison, after: BinaryInspectionReport)
        case unavailable(BinaryComparisonCandidate, String)
        case failed(String)
    }

    @Published private(set) var candidates: [BinaryComparisonCandidate] = []
    @Published private(set) var isLoadingCandidates = false
    @Published private(set) var candidateFailure: String?
    @Published private(set) var phase: Phase = .choosing

    let before: BinaryInspectionReport
    /// The current application's bundle identifier, used only to list the
    /// same application's packages first.
    let currentBundleIdentifier: String?
    private let inspection: IPABinaryInspection
    private let source: BinaryInspectionSource

    init(
        inspection: IPABinaryInspection,
        source: BinaryInspectionSource,
        before: BinaryInspectionReport,
        bundleIdentifier: String?
    ) {
        self.inspection = inspection
        self.source = source
        self.before = before
        self.currentBundleIdentifier = bundleIdentifier
    }

    func loadCandidates() async {
        guard candidates.isEmpty, !isLoadingCandidates else { return }
        isLoadingCandidates = true
        defer { isLoadingCandidates = false }
        do {
            candidates = try await inspection.comparisonCandidates(excluding: source)
            candidateFailure = nil
        } catch is CancellationError {
            return
        } catch {
            candidateFailure = BinaryInspectorModel.failureMessage(for: error)
        }
    }

    /// Candidates of the same application first, then everything else.
    var orderedCandidates: [BinaryComparisonCandidate] {
        let identifier = before.target.kind == .mainExecutable ? currentBundleIdentifier : nil
        return candidates.sorted { lhs, rhs in
            let lhsMatch = identifier != nil && lhs.bundleIdentifier == identifier
            let rhsMatch = identifier != nil && rhs.bundleIdentifier == identifier
            if lhsMatch != rhsMatch { return lhsMatch }
            return (lhs.date ?? .distantPast) > (rhs.date ?? .distantPast)
        }
    }

    func compare(with candidate: BinaryComparisonCandidate) async {
        phase = .comparing(candidate)
        do {
            let outcome = try await inspection.inspectTarget(matching: before.target, in: candidate.source)
            switch outcome {
            case .inspected(let after):
                phase = .compared(candidate, BinaryComparator.compare(before: before, after: after), after: after)
            case .unavailable(_, let limitation):
                phase = .unavailable(candidate, "\(limitation.title). \(limitation.explanation)")
            case .notFound:
                phase = .unavailable(candidate, "The other package contains no executable at the same location as \(before.target.name), so there is nothing to compare it with.")
            }
        } catch is CancellationError {
            phase = .choosing
        } catch {
            phase = .failed(BinaryInspectorModel.failureMessage(for: error))
        }
    }

    func chooseAnother() {
        phase = .choosing
    }
}

/// Compares one executable with its counterpart in another package and shows
/// only meaningful differences: signature, CodeDirectory, entitlement names,
/// libraries, build targets, verification, and size.
struct BinaryComparisonView: View {

    @StateObject private var model: BinaryComparisonModel
    let beforeTitle: String
    @Environment(\.dismiss) private var dismiss

    init(
        inspection: IPABinaryInspection,
        source: BinaryInspectionSource,
        before: BinaryInspectionReport,
        beforeTitle: String,
        bundleIdentifier: String? = nil
    ) {
        _model = StateObject(wrappedValue: BinaryComparisonModel(
            inspection: inspection,
            source: source,
            before: before,
            bundleIdentifier: bundleIdentifier
        ))
        self.beforeTitle = beforeTitle
    }

    var body: some View {
        content
            .navigationTitle("Compare \(model.before.target.name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await model.loadCandidates() }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .choosing:
            candidateList
        case .comparing(let candidate):
            VStack(spacing: ZSpacing.sm) {
                ProgressView()
                Text("Inspecting and verifying \(model.before.target.name) in \(candidate.name)…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(ZSpacing.lg)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .combine)
        case .compared(let candidate, let comparison, let after):
            results(candidate: candidate, comparison: comparison, after: after)
        case .unavailable(_, let message):
            ContentUnavailableView {
                Label("Nothing to Compare", systemImage: "arrow.left.arrow.right")
            } description: {
                Text(message)
            } actions: {
                Button("Choose Another Package") { model.chooseAnother() }
                    .buttonStyle(.bordered)
            }
        case .failed(let message):
            ContentUnavailableView {
                Label("Comparison Unavailable", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Choose Another Package") { model.chooseAnother() }
                    .buttonStyle(.bordered)
            }
        }
    }

    // MARK: - Choosing

    private var candidateList: some View {
        List {
            Section {
                BinaryFieldRow(label: "Before", value: "\(beforeTitle) — \(model.before.target.name)")
                BinaryFieldRow(label: "Verification", value: model.before.verdict.displayName)
            } footer: {
                Text("Choose the package to compare with, such as the signed output of this app. The same executable is inspected and verified there, read-only.")
            }
            let records = model.orderedCandidates.filter { $0.kind == .libraryRecord }
            let signed = model.orderedCandidates.filter { $0.kind == .signedPackage }
            if model.isLoadingCandidates {
                Section {
                    HStack(spacing: ZSpacing.sm) {
                        ProgressView()
                        Text("Finding packages…").font(.footnote).foregroundStyle(.secondary)
                    }
                }
            } else if let failure = model.candidateFailure {
                Section { Text(failure).font(.footnote).foregroundStyle(.secondary) }
            } else if records.isEmpty && signed.isEmpty {
                Section {
                    Text("There is no other imported or signed package to compare with.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            if !signed.isEmpty {
                Section("Signed Packages") {
                    ForEach(signed) { candidate in candidateRow(candidate) }
                }
            }
            if !records.isEmpty {
                Section("Library") {
                    ForEach(records) { candidate in candidateRow(candidate) }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private func candidateRow(_ candidate: BinaryComparisonCandidate) -> some View {
        Button {
            Task { await model.compare(with: candidate) }
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(candidate.name)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
                Text(candidateDetail(candidate))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Compares \(model.before.target.name) with the same executable in this package.")
    }

    private func candidateDetail(_ candidate: BinaryComparisonCandidate) -> String {
        var parts: [String] = []
        if let version = candidate.version { parts.append("Version \(version)") }
        if let identifier = candidate.bundleIdentifier { parts.append(identifier) }
        if let date = candidate.date { parts.append(date.formatted(date: .abbreviated, time: .shortened)) }
        if let bytes = candidate.byteCount { parts.append(BinaryFormat.bytes(bytes)) }
        return parts.isEmpty ? (candidate.kind == .signedPackage ? "Signed package" : "Library record") : parts.joined(separator: " · ")
    }

    // MARK: - Results

    private func results(candidate: BinaryComparisonCandidate, comparison: BinaryComparison, after: BinaryInspectionReport) -> some View {
        List {
            Section {
                BinaryFieldRow(label: "Before", value: "\(beforeTitle) — \(model.before.verdict.displayName)")
                BinaryFieldRow(label: "After", value: "\(candidate.name) — \(after.verdict.displayName)")
                BinaryFieldRow(label: "Differences", value: comparison.hasDifferences ? comparison.differences.count.formatted() : "None")
            } footer: {
                Text("Only differences a person would act on are shown. Hash tables and raw bytes are never compared line by line.")
            }
            if !comparison.hasDifferences {
                Section {
                    Label("No meaningful differences", systemImage: "equal.circle")
                        .font(.headline)
                    Text("Size, architectures, signature, CodeDirectory, entitlement names, libraries, build targets, and verification results are the same in both packages.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(comparison.categoriesWithDifferences, id: \.self) { category in
                Section {
                    ForEach(comparison.differences(in: category)) { difference in
                        BinaryDifferenceRow(difference: difference)
                    }
                } header: {
                    Label(category.displayName, systemImage: category.systemImage)
                }
            }
            Section {
                Button("Compare With Another Package") { model.chooseAnother() }
                    .frame(minHeight: 44)
            }
        }
        .listStyle(.insetGrouped)
    }
}

/// One difference: the field, and its value before and after.
struct BinaryDifferenceRow: View {
    let difference: BinaryComparisonDifference

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(difference.field)
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: ZSpacing.xs)
                switch difference.change {
                case .added:
                    ZStatusBadge("Added", systemImage: "plus.circle", kind: .info)
                case .removed:
                    ZStatusBadge("Removed", systemImage: "minus.circle", kind: .warning)
                case .changed:
                    ZStatusBadge("Changed", systemImage: "arrow.left.arrow.right", kind: .neutral)
                }
            }
            switch difference.change {
            case .added:
                Text(difference.after)
                    .font(.footnote)
                    .textSelection(.enabled)
            case .removed:
                Text(difference.before)
                    .font(.footnote)
                    .strikethrough()
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            case .changed:
                Text("Before: \(difference.before)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Text("After: \(difference.after)")
                    .font(.footnote)
                    .textSelection(.enabled)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(difference.spokenDescription)
    }
}
