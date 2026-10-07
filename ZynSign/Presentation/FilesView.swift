import SwiftUI
import UniformTypeIdentifiers
import UIKit

/// The Files area — a file browser over ZynSign's own container.
///
/// This is ZynSign's original file manager. It surfaces the same storage the
/// library and the import pipeline use: the Documents directory, the staging
/// directory, and the library artifacts directory. Nothing here reaches
/// outside the sandbox. Operations are local: import, share, rename, delete,
/// and navigate into subdirectories. No cloud browser, no desktop helper.
struct FilesView: View {

    @Environment(\.applicationEnvironment) private var environment
    @Environment(\.importPresentation) private var importPresentation
    @StateObject private var model: FilesViewModel
    @State private var searchText = ""
    @State private var isShowingImporter = false
    @State private var isShowingNewFolder = false
    @State private var newFolderName = ""
    @State private var shareItem: ShareURL?
    @State private var fileToRename: FileItem?
    @State private var renameText = ""

    /// When this view is pushed into a navigation stack that already exists
    /// — Settings → Browse, or a `NavigationLink` from another screen — it
    /// must not wrap itself in a second one. Nesting `NavigationStack` inside
    /// a pushed destination is a runtime crash, not a warning.
    var embedsNavigationStack: Bool = true

    init(directory: URL? = nil, embedsNavigationStack: Bool = true) {
        self.embedsNavigationStack = embedsNavigationStack
        _model = StateObject(wrappedValue: FilesViewModel(root: directory))
    }

    private var filtered: [FileItem] {
        if searchText.isEmpty { return model.items }
        return model.items.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        Group {
            if embedsNavigationStack {
                NavigationStack { fileListScreen }
            } else {
                fileListScreen
            }
        }
        .onAppear { model.reload() }
        .onChange(of: model.sort) { _, _ in model.reload() }
        .onChange(of: model.ascending) { _, _ in model.reload() }
    }

    /// The screen's own content, with no navigation container of its own, so
    /// this view can be pushed into a stack the host already owns.
    private var fileListScreen: some View {
            Group {
                if model.items.isEmpty && !model.isLoading {
                    emptyState
                } else {
                    fileList
                }
            }
            .navigationTitle(model.title)
            .navigationBarTitleDisplayMode(.large)
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search files")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if model.canGoUp {
                        Button { model.goUp() } label: { Label("Up", systemImage: "chevron.left") }
                    }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Menu {
                        Button { isShowingImporter = true } label: { Label("Import Files", systemImage: "square.and.arrow.down") }
                        Button { isShowingNewFolder = true } label: { Label("New Folder", systemImage: "folder.badge.plus") }
                        Button { model.reload() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Add")
                    Menu {
                        Picker("Sort", selection: $model.sort) {
                            Text("Name").tag(FilesViewModel.Sort.name)
                            Text("Date").tag(FilesViewModel.Sort.date)
                            Text("Size").tag(FilesViewModel.Sort.size)
                        }
                        Picker("Order", selection: $model.ascending) {
                            Text("Ascending").tag(true)
                            Text("Descending").tag(false)
                        }
                    } label: { Image(systemName: "arrow.up.arrow.down") }
                        .accessibilityLabel("Sort and order")
                }
            }
            .refreshable { model.reload() }
            .fileImporter(isPresented: $isShowingImporter, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
                switch result {
                case .success(let urls): importFiles(urls)
                case .failure: break
                }
            }
            .alert("New Folder", isPresented: $isShowingNewFolder) {
                TextField("Folder name", text: $newFolderName)
                Button("Cancel", role: .cancel) { newFolderName = "" }
                Button("Create") { model.createFolder(named: newFolderName); newFolderName = "" }
                    .disabled(newFolderName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .alert("Rename", isPresented: Binding(get: { fileToRename != nil }, set: { if !$0 { fileToRename = nil } })) {
                TextField("Name", text: $renameText)
                Button("Cancel", role: .cancel) { fileToRename = nil }
                Button("Rename") {
                    if let item = fileToRename { model.rename(item, to: renameText) }
                    fileToRename = nil
                }
            }
            .sheet(item: $shareItem) { item in
                ShareSheet(url: item.url)
            }
            .overlay { if model.isLoading { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) } }
            // The listing's own refresh: a fade in and out instead of the
            // spinner appearing over the list in one frame.
            .animation(ZMotion.fast, value: model.isLoading)
    }

    /// Brings a selection into ZynSign.
    ///
    /// Application packages and ZIP containers are not files like any other:
    /// they are what the library import flow is for, so they take the Import
    /// Hub path — the contents are validated, inspected, and admitted by the
    /// same pipeline every other entry point uses, and the import area reports
    /// what happened. Everything else is copied into the folder the user is
    /// browsing, which is what this screen has always done.
    private func importFiles(_ urls: [URL]) {
        let packages = urls.filter { $0.isFileURL && IPAFileFormat.acceptsForImport($0) }
        let others = urls.filter { !packages.contains($0) }
        if !packages.isEmpty {
            environment.importHub.receive(packages, origin: .documentPicker)
            // The hub is a shell-owned sheet raised from the picker callback.
            // The shell waits for the full UIKit presentation chain (including
            // the dismissing picker) before it asks to show the hub.
            importPresentation.present()
        }
        if !others.isEmpty {
            model.importFiles(urls: others)
        }
    }

    private var fileList: some View {
        List {
            if !model.canGoUp, let gauge = environment.storageGauge {
                StorageGaugeCard(reading: gauge.reading(for: model.currentDirectory))
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            }
            if model.canGoUp {
                Button { model.goUp() } label: {
                    Label(".. Up", systemImage: "arrow.up.left")
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(filtered) { item in
                FileRowView(
                    item: item,
                    onTap: { handleTap(item) },
                    onShare: { shareItem = ShareURL(url: item.url) },
                    onRename: { fileToRename = item; renameText = item.name },
                    onDelete: { model.delete(item) }
                )
            }
        }
        .listStyle(.insetGrouped)
        .animation(ZMotion.fast, value: filtered)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Files", systemImage: "folder.fill.badge.questionmark")
        } description: {
            Text("This folder is empty. Import files or create a folder to get started.")
        } actions: {
            Button { isShowingImporter = true } label: { Text("Import Files") }
                .buttonStyle(.borderedProminent)
            Button { isShowingNewFolder = true } label: { Text("New Folder") }
                .buttonStyle(.bordered)
        }
    }

    private func handleTap(_ item: FileItem) {
        if item.isDirectory {
            model.enter(item)
        } else {
            shareItem = ShareURL(url: item.url)
        }
    }
}

// MARK: - Model

@MainActor
final class FilesViewModel: ObservableObject {
    enum Sort: Hashable { case name, date, size }

    @Published var items: [FileItem] = []
    @Published var isLoading = false
    @Published var sort: Sort = .name
    @Published var ascending = true

    private var currentURL: URL
    private var history: [URL] = []

    var title: String { currentURL.lastPathComponent.isEmpty ? "Files" : currentURL.lastPathComponent }
    var canGoUp: Bool { !history.isEmpty }

    /// The directory currently shown. The storage gauge measures the volume
    /// this directory lives on.
    var currentDirectory: URL { currentURL }

    init(root: URL? = nil) {
        if let root { currentURL = root }
        else {
            // Default to Documents; fallback to library root if needed.
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            currentURL = docs ?? FileManager.default.temporaryDirectory
        }
    }

    func reload() {
        isLoading = true
        defer { isLoading = false }
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(at: currentURL, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey], options: [.skipsHiddenFiles]) else {
            items = []
            return
        }
        var mapped: [FileItem] = contents.compactMap { url in
            let vals = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
            return FileItem(url: url, isDirectory: vals?.isDirectory ?? false, size: vals?.fileSize ?? 0, modified: vals?.contentModificationDate ?? .distantPast)
        }
        switch sort {
        case .name: mapped.sort { ascending ? $0.name < $1.name : $0.name > $1.name }
        case .date: mapped.sort { ascending ? $0.modified < $1.modified : $0.modified > $1.modified }
        case .size: mapped.sort { ascending ? $0.size < $1.size : $0.size > $1.size }
        }
        // Directories first
        mapped.sort { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory && !rhs.isDirectory }
            return false
        }
        items = mapped
    }

    func enter(_ item: FileItem) {
        guard item.isDirectory else { return }
        history.append(currentURL)
        currentURL = item.url
        reload()
    }

    func goUp() {
        guard let prev = history.popLast() else { return }
        currentURL = prev
        reload()
    }

    func importFiles(urls: [URL]) {
        let fm = FileManager.default
        for src in urls {
            let accessing = src.startAccessingSecurityScopedResource()
            defer { if accessing { src.stopAccessingSecurityScopedResource() } }
            let dest = currentURL.appendingPathComponent(src.lastPathComponent)
            // Bounded copy via FileManager; for large IPAs the intake handles chunking elsewhere.
            try? fm.copyItem(at: src, to: dest)
        }
        reload()
    }

    func createFolder(named: String) {
        let trimmed = named.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let url = currentURL.appendingPathComponent(trimmed, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        reload()
    }

    func rename(_ item: FileItem, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != item.name else { return }
        let dest = item.url.deletingLastPathComponent().appendingPathComponent(trimmed)
        try? FileManager.default.moveItem(at: item.url, to: dest)
        reload()
    }

    func delete(_ item: FileItem) {
        try? FileManager.default.removeItem(at: item.url)
        reload()
    }
}

struct FileItem: Identifiable, Equatable, Hashable {
    let url: URL
    let isDirectory: Bool
    let size: Int
    let modified: Date
    var id: String { url.path }
    var name: String { url.lastPathComponent }
    var ext: String { url.pathExtension.lowercased() }
    var icon: String {
        if isDirectory { return "folder.fill" }
        switch ext {
        case "ipa", "tipa": return "app.badge"
        case "zip": return "doc.zipper"
        case "plist": return "doc.text"
        case "mobileprovision", "provisionprofile": return "signature"
        case "p12", "pfx": return "key.fill"
        case "jpg","jpeg","png","heic": return "photo"
        default: return "doc.fill"
        }
    }
    var sizeText: String {
        if isDirectory { return "Folder" }
        return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }
}

private struct FileRowView: View {
    let item: FileItem
    let onTap: () -> Void
    let onShare: () -> Void
    let onRename: () -> Void
    let onDelete: () -> Void
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: item.icon)
                .foregroundStyle(item.isDirectory ? .blue : .secondary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).lineLimit(1)
                Text("\(item.sizeText) · \(item.modified, format: .dateTime.month().day().year())")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if item.isDirectory { Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary) }
        }
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) { onDelete() } label: { Label("Delete", systemImage: "trash") }
            Button { onShare() } label: { Label("Share", systemImage: "square.and.arrow.up") }.tint(.blue)
        }
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            Button { onRename() } label: { Label("Rename", systemImage: "pencil") }.tint(.orange)
        }
        .contextMenu {
            Button { onShare() } label: { Label("Share", systemImage: "square.and.arrow.up") }
            Button { onRename() } label: { Label("Rename", systemImage: "pencil") }
            Button(role: .destructive) { onDelete() } label: { Label("Delete", systemImage: "trash") }
        }
    }
}

private struct ShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: [url], applicationActivities: nil) }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
private struct ShareURL: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

/// The storage gauge: the volume's used/free split as a progress bar, with
/// the application's own footprint underneath. The card is pure rendering —
/// the facts and the pressure classification come from `StorageGaugeService`.
struct StorageGaugeCard: View {
    @Environment(\.appTheme) private var theme
    let reading: StorageGaugeReading

    var body: some View {
        VStack(alignment: .leading, spacing: ZSpacing.sm) {
            HStack {
                Label("Storage", systemImage: "internaldrive")
                    .font(ZynSignTokens.Typography.headline)
                Spacer()
                pressureBadge
            }
            if let used = reading.usedFraction {
                ProgressView(value: used)
                    .tint(pressureTint)
                HStack {
                    Text("Used \(StorageGaugeReading.humanReadable(usedBytes))")
                    Spacer()
                    Text("Free \(StorageGaugeReading.humanReadable(reading.facts.availableBytes))")
                }
                .font(ZynSignTokens.Typography.caption)
                .foregroundStyle(.secondary)
                if let appUsage = reading.facts.appUsageBytes {
                    Text("ZynSign occupies \(StorageGaugeReading.humanReadable(appUsage)).")
                        .font(ZynSignTokens.Typography.caption2)
                        .foregroundStyle(.tertiary)
                }
            } else {
                Text("The volume did not report its capacity.")
                    .font(ZynSignTokens.Typography.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(ZSpacing.md)
        .background(
            RoundedRectangle(cornerRadius: ZynSignTokens.Radius.card, style: .continuous)
                .fill(ZynSignTokens.Color.secondaryGroupedBackground)
        )
    }

    private var usedBytes: Int? {
        guard let total = reading.facts.totalBytes, let available = reading.facts.availableBytes else { return nil }
        return max(0, total - available)
    }

    private var pressureTint: Color {
        switch reading.pressure {
        case .critical: return ZynSignTokens.Color.error
        case .attention: return ZynSignTokens.Color.warning
        case .comfortable: return theme.accent
        case .unknown: return ZynSignTokens.Color.neutral
        }
    }

    private var pressureBadge: some View {
        Group {
            switch reading.pressure {
            case .comfortable:
                ZStatusBadge(reading.pressure.displayName, systemImage: "checkmark.circle", kind: .success)
            case .attention:
                ZStatusBadge(reading.pressure.displayName, systemImage: "exclamationmark.triangle", kind: .warning)
            case .critical:
                ZStatusBadge(reading.pressure.displayName, systemImage: "exclamationmark.octagon", kind: .error)
            case .unknown:
                ZStatusBadge(reading.pressure.displayName, systemImage: "questionmark.circle", kind: .neutral)
            }
        }
    }
}
