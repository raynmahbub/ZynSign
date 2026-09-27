import SwiftUI

/// Chooses which packages to extract from an archive that holds several.
///
/// Every package starts selected. Extraction happens only for what the user
/// confirms, one isolated working copy per package; the archive itself is
/// never changed. Each extracted package then goes through validation and
/// analysis and appears in the preview like any other import.
struct ArchiveSelectionView: View {

    let archiveName: String
    let candidates: [NestedPackageCandidate]
    let onExtract: ([NestedPackageCandidate]) -> Void
    let onDecline: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selection: Set<String>

    init(
        archiveName: String,
        candidates: [NestedPackageCandidate],
        onExtract: @escaping ([NestedPackageCandidate]) -> Void,
        onDecline: @escaping () -> Void
    ) {
        self.archiveName = archiveName
        self.candidates = candidates
        self.onExtract = onExtract
        self.onDecline = onDecline
        _selection = State(initialValue: Set(candidates.map(\.id)))
    }

    private var chosen: [NestedPackageCandidate] {
        candidates.filter { selection.contains($0.id) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(candidates) { candidate in
                        row(for: candidate)
                    }
                } header: {
                    Text(candidates.count == 1 ? "1 app package" : "\(candidates.count) app packages")
                } footer: {
                    Text("Each chosen package is extracted into its own working copy, checked, and shown in the preview before anything is imported. \(archiveName) is not changed.")
                }
                Section {
                    Button("Don't Import Anything From This Archive", role: .destructive) {
                        onDecline()
                        dismiss()
                    }
                }
            }
            .navigationTitle("Choose Apps")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Later") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(selection.count == candidates.count ? "Select None" : "Select All") {
                        withAnimation(ZMotion.fast) {
                            selection = selection.count == candidates.count ? [] : Set(candidates.map(\.id))
                        }
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button {
                    onExtract(chosen)
                    dismiss()
                } label: {
                    Text(chosen.count == 1 ? "Extract 1 App" : "Extract \(chosen.count) Apps")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(chosen.isEmpty)
                .keyboardShortcut(.return, modifiers: .command)
                .padding(.horizontal, ZSpacing.md)
                .padding(.vertical, ZSpacing.sm)
                .background(.bar)
            }
        }
    }

    private func row(for candidate: NestedPackageCandidate) -> some View {
        let isSelected = selection.contains(candidate.id)
        return Button {
            if isSelected {
                selection.remove(candidate.id)
            } else {
                selection.insert(candidate.id)
            }
        } label: {
            HStack(spacing: ZSpacing.sm) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .contentTransition(.symbolEffect(.replace))
                VStack(alignment: .leading, spacing: 2) {
                    Text(candidate.fileName)
                        .font(.body.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    if let folder = candidate.folder {
                        Text(folder)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer(minLength: ZSpacing.xs)
                Text(ImportQueueRendering.bytes(candidate.byteCount))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
