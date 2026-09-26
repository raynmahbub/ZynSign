import SwiftUI

// MARK: - Statistics

/// The library's statistics as a grid of tiles: total, favourites, signed,
/// unsigned, collections, and storage. Every value comes from the index, so
/// the tiles update with the list. Each tile is also a shortcut — tapping
/// Favorites opens the Favorites collection, tapping Storage sorts by size.
struct LibraryStatisticsCard: View {

    enum Tile: Hashable {
        case total
        case favorites
        case signed
        case unsigned
        case collections
        case storage
    }

    let statistics: LibraryStatistics
    let showsSigning: Bool
    let onSelect: (Tile) -> Void

    @ScaledMetric(relativeTo: .body) private var tileMinimumWidth: CGFloat = 96

    var body: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: tileMinimumWidth), spacing: ZSpacing.xs)],
            alignment: .leading,
            spacing: ZSpacing.xs
        ) {
            tile(.total, value: "\(statistics.totalApplications)", label: "Total Apps", systemImage: "square.grid.2x2", tint: .blue)
            tile(.favorites, value: "\(statistics.favorites)", label: "Favorites", systemImage: "star.fill", tint: .yellow)
            if showsSigning {
                tile(.signed, value: "\(statistics.signed)", label: "Signed", systemImage: "checkmark.seal.fill", tint: .green)
                tile(.unsigned, value: "\(statistics.unsigned)", label: "Unsigned", systemImage: "circle.dashed", tint: .gray)
            }
            tile(.collections, value: "\(statistics.collections)", label: "Collections", systemImage: "folder.fill", tint: .indigo)
            tile(.storage, value: storageText, label: "Storage", systemImage: "internaldrive.fill", tint: .teal)
        }
        .padding(ZSpacing.sm)
        .zynCardBackground(cornerRadius: ZRadius.lg)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Library statistics")
    }

    private var storageText: String {
        ByteCountFormatter.string(fromByteCount: statistics.storageBytes, countStyle: .file)
    }

    private func tile(_ tile: Tile, value: String, label: String, systemImage: String, tint: Color) -> some View {
        Button {
            ZHaptics.tap()
            onSelect(tile)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Image(systemName: systemImage)
                    .font(.subheadline)
                    .foregroundStyle(tint)
                Text(value)
                    .font(.title3.weight(.bold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .padding(ZSpacing.xs)
            .background(Color(.tertiarySystemFill).opacity(0.6), in: RoundedRectangle(cornerRadius: ZRadius.sm, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: ZRadius.sm, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label): \(value)")
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - Scope bar

/// The row of scopes above the list: All Apps, the smart collections, and
/// the user's collections, each with its count, followed by New Collection
/// and Manage. The selected scope is filled.
struct LibraryScopeBar: View {

    struct Item: Identifiable, Equatable {
        let scope: LibraryScope
        let title: String
        let systemImage: String
        let count: Int

        var id: String { scope.storageValue }
    }

    let items: [Item]
    let selection: LibraryScope
    let onSelect: (LibraryScope) -> Void
    var onNewCollection: (() -> Void)?
    var onManage: (() -> Void)?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: ZSpacing.xs) {
                    ForEach(items) { item in
                        chip(item)
                    }
                    if let onNewCollection {
                        utilityChip(title: "New Collection", systemImage: "plus", action: onNewCollection)
                    }
                    if let onManage {
                        utilityChip(title: "Manage", systemImage: "folder.badge.gearshape", action: onManage)
                    }
                }
                .padding(.horizontal, ZSpacing.md)
                .padding(.vertical, 2)
            }
            .onAppear {
                proxy.scrollTo(selection.storageValue, anchor: .center)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Library scopes")
    }

    private func chip(_ item: Item) -> some View {
        let isSelected = item.scope == selection
        return Button {
            ZHaptics.tap()
            onSelect(item.scope)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: item.systemImage)
                    .font(.footnote.weight(.semibold))
                Text(item.title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Text("\(item.count)")
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(isSelected ? Color.white.opacity(0.85) : Color.secondary)
            }
            .padding(.horizontal, ZSpacing.sm)
            .frame(minHeight: 44)
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .background(isSelected ? Color.accentColor : Color(.secondarySystemFill), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .id(item.id)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(item.title), \(ApplicationLibraryModel.applicationCount(item.count))")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : [.isButton])
    }

    private func utilityChip(title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button {
            ZHaptics.tap()
            action()
        } label: {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
                .padding(.horizontal, ZSpacing.sm)
                .frame(minHeight: 44)
                .foregroundStyle(Color.accentColor)
                .overlay {
                    Capsule().strokeBorder(Color.accentColor.opacity(0.4), lineWidth: 1)
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Active filters

/// The filters in effect, each removable with one tap, and Clear All.
struct LibraryActiveFilterBar: View {

    struct Item: Identifiable, Equatable {
        let filter: LibraryFilter
        let title: String

        var id: LibraryFilter { filter }
    }

    let items: [Item]
    let onRemove: (LibraryFilter) -> Void
    let onClear: () -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: ZSpacing.xs) {
                Image(systemName: "line.3.horizontal.decrease.circle.fill")
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
                ForEach(items) { item in
                    Button {
                        onRemove(item.filter)
                    } label: {
                        HStack(spacing: 4) {
                            Text(item.title)
                                .font(.footnote.weight(.medium))
                                .lineLimit(1)
                            Image(systemName: "xmark.circle.fill")
                                .font(.footnote)
                        }
                        .padding(.horizontal, ZSpacing.sm)
                        .frame(minHeight: 44)
                        .foregroundStyle(Color.accentColor)
                        .background(Color.accentColor.opacity(0.14), in: Capsule())
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Remove filter: \(item.title)")
                }
                Button("Clear All", action: onClear)
                    .font(.footnote.weight(.medium))
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .frame(minHeight: 44)
                    .accessibilityLabel("Clear all filters")
            }
            .padding(.horizontal, ZSpacing.md)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Active filters")
    }
}

// MARK: - Bulk action bar

/// The floating bar shown while applications are selected: how many are
/// selected (with Select All and Deselect All), and the bulk actions —
/// Favorite, Move to Collection, Export, Verify, Remove from Collection,
/// and Delete. At accessibility text sizes the actions keep their icons and
/// spoken names and drop the captions, so the bar never overflows.
struct LibraryBulkActionBar: View {

    @ObservedObject var model: ApplicationLibraryModel
    let features: LibraryFeatureAvailability
    let onMove: () -> Void
    let onDelete: () -> Void

    /// Queues the selection for signing, when the signing queue is exposed.
    /// Offered from the selection menu rather than as another bar button, so
    /// the bar's width is unchanged. `nil` offers nothing.
    var onQueue: (() -> Void)? = nil

    /// Opens preset planning for the selection. Offered from the selection
    /// menu, beside Queue Selected. `nil` when presets are not exposed.
    var onSignWithPreset: (() -> Void)? = nil

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let ids = model.selectedIDs
        let allFavorites = model.areAllFavorites(ids)
        VStack(spacing: ZSpacing.xxs) {
            if let progress = model.progress {
                progressLine(progress)
            }
            HStack(spacing: ZSpacing.xxs) {
                selectionMenu(count: ids.count)
                Spacer(minLength: ZSpacing.xxs)
                if features.powerFeatures {
                    action(allFavorites ? "Unfavorite" : "Favorite", systemImage: allFavorites ? "star.slash" : "star") {
                        Task { await model.toggleFavorite(ids) }
                    }
                    if model.canOrganize {
                        action("Move", systemImage: "folder.badge.plus", perform: onMove)
                    }
                    if model.canExport {
                        action("Export", systemImage: "square.and.arrow.up") {
                            Task { await model.export(ids) }
                        }
                    }
                    action("Verify", systemImage: "checkmark.shield") {
                        Task { await model.verify(ids) }
                    }
                    if let collectionID = model.scope.collectionID, model.canOrganize {
                        action("Remove", systemImage: "folder.badge.minus") {
                            Task { await model.remove(ids, fromCollection: collectionID) }
                        }
                    }
                }
                action("Delete", systemImage: "trash", role: .destructive, perform: onDelete)
                    .keyboardShortcut(.delete, modifiers: .command)
            }
        }
        .padding(.horizontal, ZSpacing.sm)
        .padding(.vertical, ZSpacing.xs)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: ZRadius.xl, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: ZRadius.xl, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        }
        .zynSoftShadow(ZShadow.card)
        .padding(.horizontal, ZSpacing.md)
        .padding(.bottom, ZSpacing.xs)
        .disabled(model.isBusy)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Actions for \(ApplicationLibraryModel.applicationCount(ids.count)) selected")
    }

    private func selectionMenu(count: Int) -> some View {
        Menu {
            Button {
                model.selectAll()
            } label: {
                Label("Select All", systemImage: "checkmark.circle")
            }
            .disabled(model.isEverythingSelected)
            Button {
                model.deselectAll()
            } label: {
                Label("Deselect All", systemImage: "circle")
            }
            if let onQueue {
                Divider()
                Button(action: onQueue) {
                    Label("Queue Selected for Signing…", systemImage: "tray.and.arrow.down")
                }
                .disabled(!model.selectedEntries.contains { $0.isArtifactAvailable })
            }
            if let onSignWithPreset {
                Button(action: onSignWithPreset) {
                    Label("Sign with Preset…", systemImage: "rectangle.stack")
                }
                .disabled(!model.selectedEntries.contains { $0.isArtifactAvailable })
            }
        } label: {
            Text("\(count) selected")
                .font(.footnote.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("\(count) selected")
        .accessibilityHint(selectionMenuHint)
    }

    private var selectionMenuHint: String {
        switch (onQueue != nil, onSignWithPreset != nil) {
        case (true, true):
            return "Opens Select All, Deselect All, Queue Selected for Signing, and Sign with Preset"
        case (true, false):
            return "Opens Select All, Deselect All, and Queue Selected for Signing"
        case (false, true):
            return "Opens Select All, Deselect All, and Sign with Preset"
        case (false, false):
            return "Opens Select All and Deselect All"
        }
    }

    private func action(
        _ title: String,
        systemImage: String,
        role: ButtonRole? = nil,
        perform: @escaping () -> Void
    ) -> some View {
        Button(role: role, action: perform) {
            VStack(spacing: 2) {
                Image(systemName: systemImage)
                    .font(.body.weight(.semibold))
                if !dynamicTypeSize.isAccessibilitySize {
                    Text(title)
                        .font(.caption2.weight(.medium))
                        .lineLimit(1)
                }
            }
            .frame(minWidth: 48, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .tint(role == .destructive ? Color.red : Color.accentColor)
        .accessibilityLabel(title)
    }

    private func progressLine(_ progress: ApplicationLibraryModel.Progress) -> some View {
        HStack(spacing: ZSpacing.xs) {
            ProgressView(value: Double(progress.completed), total: Double(max(progress.total, 1)))
            Text("\(progress.title) \(min(progress.completed + 1, progress.total)) of \(progress.total)")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.top, ZSpacing.xxs)
        .accessibilityElement(children: .combine)
    }
}

/// A floating progress capsule for work started outside selection mode — a
/// verification or export launched from one application's quick actions.
struct LibraryProgressCapsule: View {
    let progress: ApplicationLibraryModel.Progress

    var body: some View {
        HStack(spacing: ZSpacing.xs) {
            ProgressView()
            Text("\(progress.title)…")
                .font(.footnote.weight(.medium))
        }
        .padding(.horizontal, ZSpacing.md)
        .frame(minHeight: 44)
        .background(.regularMaterial, in: Capsule())
        .zynSoftShadow()
        .padding(.bottom, ZSpacing.xs)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Verification report

/// The outcome of verifying package files: a summary, then one line per
/// application naming what was found.
struct LibraryVerificationReportView: View {

    let report: ApplicationLibraryModel.VerificationReport

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label(report.summary, systemImage: report.problemCount == 0 ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                        .foregroundStyle(report.problemCount == 0 ? Color.green : Color.orange)
                        .font(.body.weight(.medium))
                } footer: {
                    Text("Verifying re-reads each package file and compares its size and SHA-256 content fingerprint with what was recorded at import. It tells you whether the bytes changed — not whether an app is signed, trusted, or installable.")
                }
                Section("Results") {
                    ForEach(report.items) { item in
                        row(item)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Verification")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .onAppear {
            LibraryAnnouncer.announce(report.summary)
        }
    }

    private func row(_ item: ApplicationLibraryModel.VerificationReport.Item) -> some View {
        HStack(alignment: .top, spacing: ZSpacing.sm) {
            Image(systemName: symbol(for: item))
                .foregroundStyle(item.isIntact ? Color.green : Color.orange)
                .font(.body.weight(.semibold))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.body)
                Text(detail(for: item))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private func symbol(for item: ApplicationLibraryModel.VerificationReport.Item) -> String {
        switch item.outcome {
        case .checked(.intact): return "checkmark.circle.fill"
        case .checked(.modified): return "exclamationmark.triangle.fill"
        case .checked(.missing): return "questionmark.folder.fill"
        case .failed: return "xmark.octagon.fill"
        }
    }

    private func detail(for item: ApplicationLibraryModel.VerificationReport.Item) -> String {
        switch item.outcome {
        case .checked(let integrity):
            return "\(integrity.displayName). \(integrity.explanation)"
        case .failed(let message):
            return "Could not verify. \(message)"
        }
    }
}
