import SwiftUI
import UIKit

/// The IPA explorer: a read-only tree, search, resource browser, and inspector.
///
/// The structure comes from one entry-table read. File bytes are read only
/// when the user opens a file, and only through `IPABundleEntryInspection`.
/// No control on this screen edits, extracts, signs, or runs the package.
struct IPAExplorerScreen: View {

    let contents: BundleContents
    let recordID: ApplicationRecordIdentifier

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var expanded: Set<ExplorerNodeID> = [.payload, .application]
    @State private var windows: [ExplorerNodeID: Int] = [:]
    @State private var selection: ExplorerNodeID?
    @State private var phoneDetail: ExplorerNodeID?
    @State private var query = ""
    @State private var mode: BrowseMode = .tree
    @State private var searchIndex: BundleSearchIndex?
    @State private var resources: [ExplorerResourceRow] = []
    @State private var showCopiedToast = false
    @State private var copiedMessage = "Copied"

    private enum BrowseMode: String, CaseIterable, Identifiable {
        case tree = "Tree"
        case resources = "Resources"
        var id: String { rawValue }
    }

    private var isRegular: Bool { horizontalSizeClass == .regular }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isSearching: Bool { !trimmedQuery.isEmpty }

    private var searchResult: BundleSearchResult {
        guard isSearching, let searchIndex else { return .empty }
        return searchIndex.search(trimmedQuery)
    }

    var body: some View {
        Group {
            if isRegular {
                NavigationSplitView {
                    sidebar
                        .navigationSplitViewColumnWidth(min: 280, ideal: 340, max: 480)
                } detail: {
                    inspector(for: selection ?? .application)
                }
                .navigationSplitViewStyle(.balanced)
            } else {
                NavigationStack {
                    sidebar
                        .navigationDestination(item: $phoneDetail) { node in
                            inspector(for: node)
                        }
                }
            }
        }
        .zToast(isPresented: $showCopiedToast, message: copiedMessage, style: .info)
        .task {
            if searchIndex == nil {
                searchIndex = BundleSearchIndex(contents: contents)
            }
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List {
            Section {
                ExplorerStatisticsCard(contents: contents)
                    .listRowInsets(EdgeInsets(top: ZSpacing.xs, leading: 0, bottom: ZSpacing.xs, trailing: 0))
                    .listRowBackground(Color.clear)
            }

            if !isSearching {
                Section {
                    Picker("Browse", selection: $mode) {
                        ForEach(BrowseMode.allCases) { item in
                            Text(item.rawValue).tag(item)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityLabel("Browse mode")
                }
            }

            if isSearching {
                searchSection
            } else if mode == .resources {
                resourceSection
            } else {
                treeSection
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(contents.bundleName)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "Filename, extension, or folder")
        .onChange(of: mode) { _, newMode in
            if newMode == .resources { loadResourcesIfNeeded() }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                ZStatusBadge("Read-only", systemImage: "eye", kind: .neutral)
                    .accessibilityLabel("Read-only")
            }
        }
    }

    private var treeSection: some View {
        Section {
            let items = ExplorerTreeProjection.visibleItems(
                contents: contents,
                expanded: expanded,
                windows: windows
            )
            ForEach(items) { item in
                switch item {
                case .row(let row):
                    treeRow(row)
                case .showMore(let parent, let hidden):
                    showMoreButton(parent: parent, hidden: hidden)
                }
            }
        } header: {
            ExplorerBreadcrumbBar(
                crumbs: ExplorerTreeProjection.breadcrumb(for: selection, contents: contents)
            ) { node in
                reveal(node, returnToTree: false)
                selection = node
            }
        } footer: {
            VStack(alignment: .leading, spacing: ZSpacing.xs) {
                Text(ExplorerPresentationCopy.readOnlyNote)
                if contents.omittedEntryCount > 0 {
                    Text(BundleDirectoryListingContent.omittedEntriesText(for: contents.omittedEntryCount))
                }
            }
        }
    }

    private var searchSection: some View {
        Section {
            if searchIndex == nil {
                ProgressView("Preparing search…")
                    .frame(maxWidth: .infinity, alignment: .center)
            } else if searchResult.matches.isEmpty {
                ContentUnavailableView {
                    Label("No Matches", systemImage: "magnifyingglass")
                } description: {
                    Text("No file or folder name matches “\(trimmedQuery)”.")
                }
                .listRowBackground(Color.clear)
            } else {
                ForEach(searchResult.matches) { match in
                    searchRow(match)
                }
            }
        } header: {
            if searchResult.totalMatchCount > 0 {
                Text(searchResult.isTruncated
                     ? "\(searchResult.totalMatchCount) matches · showing \(searchResult.matches.count)"
                     : "\(searchResult.totalMatchCount) \(searchResult.totalMatchCount == 1 ? "match" : "matches")")
            } else {
                Text("Search")
            }
        }
    }

    private var resourceSection: some View {
        Section {
            if resources.isEmpty {
                ContentUnavailableView {
                    Label("No Previewable Resources", systemImage: "photo.on.rectangle")
                } description: {
                    Text("No images, JSON, XML, localization folders, or launch assets were recorded.")
                }
                .listRowBackground(Color.clear)
            } else {
                ForEach(resources) { row in
                    resourceRow(row)
                }
            }
        } header: {
            Text(resources.isEmpty ? "Resources" : "\(resources.count) resources")
        }
    }

    // MARK: - Rows

    private func treeRow(_ row: ExplorerTreeRow) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: ZSpacing.xs) {
            disclosure(for: row)
            ExplorerFileIcon(symbol: row.id == .application ? "app.fill" : row.classification.symbolName, classification: row.classification)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.name)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                HStack(spacing: 4) {
                    Text(row.detailText)
                    if let bytes = row.declaredByteCount {
                        Text("·")
                        Text(Int64(bytes), format: .byteCount(style: .file))
                    }
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if row.offersBundlePage {
                Button {
                    openDetail(row.id)
                } label: {
                    Image(systemName: "info.circle")
                        .font(.body)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("View details for \(row.name)")
            }
        }
        .padding(.leading, CGFloat(min(row.depth, 8)) * 12)
        .contentShape(Rectangle())
        .onTapGesture { activate(row) }
        .contextMenu { quickActions(name: row.name, location: row.locationText, node: row.id) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(row.accessibilityLabel)
        .accessibilityHint(row.isDirectory ? "Expands or collapses this folder. Does not modify the package." : "Opens a read-only preview.")
        .accessibilityAction(named: row.isDirectory ? (row.isExpanded ? "Collapse" : "Expand") : "View Details") {
            if row.isDirectory { toggle(row.id) } else { openDetail(row.id) }
        }
        .accessibilityAction(named: ExplorerQuickAction.copyPath.rawValue) { copy(row.locationText, message: "Path copied") }
        .accessibilityAction(named: ExplorerQuickAction.copyFilename.rawValue) { copy(row.name, message: "Filename copied") }
    }

    private func disclosure(for row: ExplorerTreeRow) -> some View {
        Group {
            if row.isDirectory {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(row.isExpanded ? 90 : 0))
                    .frame(width: 22, height: 22)
                    .accessibilityHidden(true)
            } else {
                Color.clear.frame(width: 22, height: 22).accessibilityHidden(true)
            }
        }
    }

    private func showMoreButton(parent: ExplorerNodeID, hidden: Int) -> some View {
        Button {
            withAnimation(ZMotion.fast) {
                let current = windows[parent] ?? ExplorerTreeProjection.pageSize
                windows[parent] = current + ExplorerTreeProjection.pageSize
            }
        } label: {
            Label("Show \(min(hidden, ExplorerTreeProjection.pageSize)) more", systemImage: "ellipsis")
                .font(.body)
        }
        .accessibilityLabel("Show \(hidden) more items")
        .accessibilityHint("Loads the next page of this folder. Does not read file contents.")
    }

    private func searchRow(_ match: BundleSearchMatch) -> some View {
        Button {
            openDetail(.entry(match.path))
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: ZSpacing.sm) {
                let entry = contents.entry(at: match.path)
                let classification = entry.map(BundleFileClassification.recognize) ?? .generic
                ExplorerFileIcon(
                    symbol: entry?.isDirectory == true ? classification.symbolName : classification.symbolName,
                    classification: classification
                )
                VStack(alignment: .leading, spacing: 2) {
                    ExplorerHighlightedName(name: match.name, highlight: match.highlight)
                        .lineLimit(2)
                        .truncationMode(.middle)
                    Text(match.field == .folder ? "In \(match.folderName ?? "folder")" : match.locationText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
        .buttonStyle(.plain)
        .contextMenu { quickActions(name: match.name, location: match.locationText, node: .entry(match.path)) }
        .accessibilityLabel("\(match.name), \(match.locationText)")
        .accessibilityHint("Opens a read-only preview.")
    }

    private func resourceRow(_ row: ExplorerResourceRow) -> some View {
        Button {
            openDetail(.entry(row.entry.path))
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: ZSpacing.sm) {
                ExplorerFileIcon(
                    symbol: BundleFileClassification.recognize(row.entry).symbolName,
                    classification: BundleFileClassification.recognize(row.entry)
                )
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.entry.name)
                        .font(.body)
                        .lineLimit(2)
                        .truncationMode(.middle)
                    HStack(spacing: 4) {
                        Text(row.reason)
                        if let bytes = row.entry.declaredByteCount {
                            Text("·")
                            Text(Int64(bytes), format: .byteCount(style: .file))
                        }
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    Text(row.locationText)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
        .buttonStyle(.plain)
        .contextMenu { quickActions(name: row.entry.name, location: row.locationText, node: .entry(row.entry.path)) }
        .accessibilityLabel("\(row.entry.name), \(row.reason), \(row.locationText)")
    }

    @ViewBuilder
    private func quickActions(name: String, location: String, node: ExplorerNodeID) -> some View {
        Button(ExplorerQuickAction.viewDetails.rawValue, systemImage: ExplorerQuickAction.viewDetails.systemImage) {
            openDetail(node)
        }
        Button(ExplorerQuickAction.revealInTree.rawValue, systemImage: ExplorerQuickAction.revealInTree.systemImage) {
            reveal(node, returnToTree: true)
        }
        Button(ExplorerQuickAction.copyPath.rawValue, systemImage: ExplorerQuickAction.copyPath.systemImage) {
            copy(location, message: "Path copied")
        }
        Button(ExplorerQuickAction.copyFilename.rawValue, systemImage: ExplorerQuickAction.copyFilename.systemImage) {
            copy(name, message: "Filename copied")
        }
    }

    // MARK: - Navigation

    @ViewBuilder
    private func inspector(for node: ExplorerNodeID) -> some View {
        ExplorerInspectorHost(
            recordID: recordID,
            contents: contents,
            node: node,
            onReveal: { reveal($0, returnToTree: true) },
            onOpen: { openDetail($0) },
            onCopy: { copy($0, message: $1) }
        )
    }

    private func activate(_ row: ExplorerTreeRow) {
        if row.isDirectory {
            toggle(row.id)
            if isRegular { selection = row.id }
        } else {
            openDetail(row.id)
        }
    }

    private func toggle(_ id: ExplorerNodeID) {
        withAnimation(ZMotion.fast) {
            if expanded.contains(id) {
                expanded.remove(id)
            } else {
                expanded.insert(id)
            }
        }
    }

    private func openDetail(_ node: ExplorerNodeID) {
        withAnimation(ZMotion.fast) {
            expanded = ExplorerTreeProjection.revealedExpansion(of: node, existing: expanded)
            if let (parent, count) = ExplorerTreeProjection.windowNeeded(toShow: node, contents: contents) {
                windows[parent] = max(windows[parent] ?? 0, count)
            }
            selection = node
            if !isRegular {
                phoneDetail = node
            }
        }
    }

    private func reveal(_ node: ExplorerNodeID, returnToTree: Bool) {
        withAnimation(ZMotion.fast) {
            expanded = ExplorerTreeProjection.revealedExpansion(of: node, existing: expanded)
            if let (parent, count) = ExplorerTreeProjection.windowNeeded(toShow: node, contents: contents) {
                windows[parent] = max(windows[parent] ?? 0, count)
            }
            mode = .tree
            query = ""
            selection = node
            if returnToTree {
                phoneDetail = nil
            }
        }
    }

    private func copy(_ text: String, message: String) {
        UIPasteboard.general.string = text
        copiedMessage = message
        withAnimation(ZMotion.interactive) {
            showCopiedToast = true
        }
    }

    private func loadResourcesIfNeeded() {
        guard resources.isEmpty else { return }
        resources = ExplorerResourceCatalog.rows(in: contents)
    }
}

// MARK: - Statistics

struct ExplorerStatisticsCard: View {

    let contents: BundleContents
    @State private var statistics: BundleStatistics?

    var body: some View {
        ZCard {
            VStack(alignment: .leading, spacing: ZSpacing.sm) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(contents.bundleName)
                            .font(.headline)
                            .lineLimit(2)
                        Text("IPA Explorer")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: ZSpacing.sm)
                    ZStatusBadge("Read-only", systemImage: "eye", kind: .neutral)
                }
                if let statistics {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: ZSpacing.sm) {
                        metric("Total Files", value: statistics.totalFiles)
                        metric("Frameworks", value: statistics.frameworks)
                        metric("Extensions", value: statistics.extensions)
                        metric("Executables", value: statistics.executables)
                        metric("Images", value: statistics.images)
                        sizeMetric(statistics.bundleSize)
                    }
                    Text(ExplorerPresentationCopy.declaredSizeNote)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ProgressView("Counting…")
                        .frame(maxWidth: .infinity, minHeight: 72, alignment: .center)
                }
            }
        }
        .task {
            if statistics == nil {
                statistics = BundleStatistics(contents: contents)
            }
        }
    }

    private var columns: [GridItem] {
        [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)]
    }

    private func metric(_ title: String, value: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value, format: .number)
                .font(.title3.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(value)")
    }

    private func sizeMetric(_ bytes: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(Int64(bytes), format: .byteCount(style: .file))
                .font(.title3.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text("Bundle Size")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
            .accessibilityLabel("Bundle Size, \(Int64(bytes).formatted(.byteCount(style: .file)))")
    }
}

// MARK: - Shared row pieces

struct ExplorerFileIcon: View {
    let symbol: String
    let classification: BundleFileClassification

    var body: some View {
        Image(systemName: symbol)
            .font(.body)
            .foregroundStyle(tint)
            .frame(minWidth: 24)
            .accessibilityHidden(true)
    }

    private var tint: Color {
        switch classification {
        case .folder, .framework, .appExtension, .localization: return .accentColor
        case .executable: return .orange
        case .image: return .blue
        case .provisioningProfile: return .purple
        default: return .secondary
        }
    }
}

struct ExplorerHighlightedName: View {
    let name: String
    let highlight: ExplorerHighlight?

    var body: some View {
        if let highlight, let range = highlight.range(in: name) {
            (Text(name[..<range.lowerBound])
             + Text(name[range]).bold().foregroundStyle(Color.accentColor)
             + Text(name[range.upperBound...]))
        } else {
            Text(name)
        }
    }
}

struct ExplorerBreadcrumbBar: View {
    let crumbs: [ExplorerCrumb]
    var onSelect: (ExplorerNodeID) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(Array(crumbs.enumerated()), id: \.element.id) { index, crumb in
                    if index > 0 {
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                    }
                    Button {
                        onSelect(crumb.id)
                    } label: {
                        Text(crumb.title)
                            .font(index == crumbs.count - 1 ? .subheadline.weight(.semibold) : .subheadline)
                            .foregroundStyle(index == crumbs.count - 1 ? Color.primary : Color.secondary)
                            .lineLimit(1)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(crumb.title)
                    .accessibilityHint("Shows this location in the bundle tree.")
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Bundle path")
    }
}

enum ExplorerResourceCatalog {
    static func rows(in contents: BundleContents) -> [ExplorerResourceRow] {
        var rows: [ExplorerResourceRow] = []
        func walk(_ directory: BundlePath) {
            for entry in contents.entries(in: directory) ?? [] {
                if let reason = ExplorerResourceFilter.reason(for: entry) {
                    rows.append(ExplorerResourceRow(
                        entry: entry,
                        reason: reason,
                        locationText: ExplorerLocation.displayPath(bundleName: contents.bundleName, entry: entry.path)
                    ))
                }
                if entry.isDirectory {
                    walk(entry.path)
                }
            }
        }
        walk(.root)
        return rows
    }
}

struct ExplorerResourceRow: Equatable, Identifiable {
    let entry: BundleEntry
    let reason: String
    let locationText: String
    var id: BundlePath { entry.path }
}
