import SwiftUI

/// The Duplicate Resolution Center: every conflict in the preview, in one
/// place, instead of a question per import.
///
/// Each conflict shows the existing library entry beside the incoming
/// package — icon, version and build, size, and when the existing entry was
/// imported — with the rules' suggestion and why. The user chooses Keep
/// Both, Replace Existing, or Skip per conflict, applies one choice to all,
/// or accepts every suggestion at once. Nothing is chosen for them: until a
/// selected conflict has a choice, the hub will not import.
@MainActor
struct DuplicateResolutionCenterView: View {

    @ObservedObject var hub: ImportHub
    var onImport: () -> Void = {}

    @Environment(\.dismiss) private var dismiss

    private var conflicts: [ImportHub.Item] {
        hub.conflictItems.filter(\.isSelected)
    }

    private var excludedCount: Int {
        hub.conflictItems.filter { !$0.isSelected }.count
    }

    var body: some View {
        NavigationStack {
            List {
                if conflicts.isEmpty {
                    ContentUnavailableView(
                        "No Conflicts",
                        systemImage: "checkmark.seal",
                        description: Text("None of the selected apps conflict with the library.")
                    )
                    .listRowBackground(Color.clear)
                } else {
                    Section {
                        applyToAll
                    } header: {
                        Text(headerText)
                    } footer: {
                        Text("Suggestions follow ZynSign's rules: a newer version suggests replacing, an identical package suggests skipping, an older one suggests keeping both. Same-version rebuilds are always left to you.")
                    }

                    ForEach(conflicts) { item in
                        if let conflict = item.conflict {
                            Section {
                                ConflictComparisonView(item: item, conflict: conflict)
                                resolutionPicker(for: item)
                                Text(ImportQueueRendering.suggestionExplanation(for: conflict))
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                if item.resolution == .replaceExisting {
                                    Label(ImportQueueRendering.replacementScope(for: conflict), systemImage: "exclamationmark.triangle")
                                        .font(.footnote)
                                        .foregroundStyle(.orange)
                                }
                            } header: {
                                Text(ImportQueueRendering.headline(for: conflict))
                            }
                        }
                    }
                }

                if excludedCount > 0 {
                    Section {
                        Text(excludedCount == 1
                             ? "1 conflicting app is not selected and will be skipped."
                             : "\(excludedCount) conflicting apps are not selected and will be skipped.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .animation(.snappy, value: conflicts.map(\.resolution))
            .navigationTitle("Resolve Conflicts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                importBar
            }
        }
    }

    private var headerText: String {
        let unresolved = hub.unresolvedConflictCount
        let total = conflicts.count
        let noun = total == 1 ? "1 conflict" : "\(total) conflicts"
        return unresolved == 0 ? "\(noun) · all resolved" : "\(noun) · \(unresolved) need a choice"
    }

    private var applyToAll: some View {
        VStack(alignment: .leading, spacing: ZSpacing.sm) {
            Text("Apply to All")
                .font(.subheadline.weight(.semibold))
            ViewThatFits(in: .horizontal) {
                HStack(spacing: ZSpacing.xs) { applyButtons }
                VStack(alignment: .leading, spacing: ZSpacing.xs) { applyButtons }
            }
            if conflicts.contains(where: { $0.conflict?.suggestion != nil }) {
                Button {
                    ZHaptics.tap()
                    withAnimation(.snappy) { hub.applySuggestions() }
                } label: {
                    Label("Use Suggested Choices", systemImage: "wand.and.stars")
                }
                .buttonStyle(.borderless)
                .keyboardShortcut("u", modifiers: [.command, .shift])
            }
        }
        .padding(.vertical, ZSpacing.xxs)
    }

    @ViewBuilder
    private var applyButtons: some View {
        ForEach(ConflictResolution.allCases, id: \.self) { resolution in
            Button {
                ZHaptics.tap()
                withAnimation(.snappy) { hub.applyToAllConflicts(resolution) }
            } label: {
                Label(resolution.displayName, systemImage: resolution.symbolName)
            }
            .buttonStyle(.bordered)
            .tint(resolution.isDestructive ? .orange : .accentColor)
            .controlSize(.small)
        }
    }

    private func resolutionPicker(for item: ImportHub.Item) -> some View {
        Picker(
            "Choice",
            selection: Binding<ConflictResolution?>(
                get: { hub.items.first(where: { $0.id == item.id })?.resolution },
                set: { hub.resolve(item.id, with: $0) }
            )
        ) {
            ForEach(ConflictResolution.allCases, id: \.self) { resolution in
                Text(Self.shortName(for: resolution)).tag(Optional(resolution))
            }
        }
        .pickerStyle(.segmented)
        .accessibilityLabel("Choice for \(ImportQueueRendering.title(for: item))")
    }

    private static func shortName(for resolution: ConflictResolution) -> String {
        switch resolution {
        case .keepBoth: return "Keep Both"
        case .replaceExisting: return "Replace"
        case .skip: return "Skip"
        }
    }

    @ViewBuilder
    private var importBar: some View {
        if !conflicts.isEmpty {
            VStack(spacing: ZSpacing.xxs) {
                Button {
                    onImport()
                    dismiss()
                } label: {
                    Text(hub.canImportSelected ? importTitle : "Choose for every conflict to import")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!hub.canImportSelected)
                .keyboardShortcut(.return, modifiers: .command)
            }
            .padding(.horizontal, ZSpacing.md)
            .padding(.vertical, ZSpacing.sm)
            .background(.bar)
        }
    }

    private var importTitle: String {
        let count = hub.selectedReadyItems.count
        return count == 1 ? "Import 1 App" : "Import \(count) Apps"
    }
}

/// Existing versus incoming, side by side where there is room and stacked
/// where there is not.
struct ConflictComparisonView: View {

    let item: ImportHub.Item
    let conflict: ImportConflict

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .body) private var iconSize: CGFloat = 40

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: ZSpacing.sm) {
                    existing
                    Image(systemName: "arrow.down")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    incoming
                }
            } else {
                HStack(alignment: .top, spacing: ZSpacing.sm) {
                    existing
                    Image(systemName: "arrow.right")
                        .foregroundStyle(.secondary)
                        .padding(.top, iconSize / 2 - 6)
                        .accessibilityHidden(true)
                    incoming
                }
            }
        }
        .padding(.vertical, ZSpacing.xxs)
    }

    private var existing: some View {
        let record = conflict.comparedRecord
        return column(
            caption: conflict.existingRecords.count > 1 ? "In Library (\(conflict.existingRecords.count) entries)" : "In Library",
            name: record.identity.displayName ?? record.identity.bundleIdentifier.rawValue,
            version: ImportQueueRendering.versionText(record.identity),
            size: ImportQueueRendering.bytes(record.artifact.byteCount),
            detail: "Imported \(record.importedAt.formatted(date: .abbreviated, time: .omitted))"
        ) {
            ApplicationIconView(
                artifactID: record.artifact.artifactID,
                displayName: record.identity.displayName ?? "",
                bundleIdentifier: record.identity.bundleIdentifier.rawValue,
                size: iconSize
            )
        }
    }

    private var incoming: some View {
        column(
            caption: "Incoming",
            name: conflict.incomingIdentity.displayName ?? conflict.incomingIdentity.bundleIdentifier.rawValue,
            version: ImportQueueRendering.versionText(conflict.incomingIdentity),
            size: ImportQueueRendering.bytes(conflict.incomingByteCount),
            detail: item.fileName
        ) {
            ImportItemIcon(item: item, size: iconSize)
        }
    }

    private func column<Icon: View>(
        caption: String,
        name: String,
        version: String,
        size: String,
        detail: String,
        @ViewBuilder icon: () -> Icon
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(caption.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            HStack(spacing: ZSpacing.xs) {
                icon()
                VStack(alignment: .leading, spacing: 1) {
                    Text(name)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)
                    Text(version)
                        .font(.caption.monospacedDigit())
                }
            }
            Text(size)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
