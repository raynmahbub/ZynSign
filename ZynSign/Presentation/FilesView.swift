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
    @State private var isShowingNewTextFile = false
    @State private var newTextFileName = ""
    @State private var plistEditorItem: FileItem?
    @State private var textEditorItem: FileItem?
    @State private var hexInspectorItem: FileItem?
    @State private var clipboardItem: (url: URL, move: Bool)?
    @State private var archiveStatusMessage: String?

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
                        Button { isShowingNewTextFile = true } label: { Label("New Text / Plist File", systemImage: "doc.badge.plus") }
                        if let clip = clipboardItem {
                            Button {
                                model.pasteClipboard(clip.url, move: clip.move)
                                if clip.move { clipboardItem = nil }
                            } label: {
                                Label(clip.move ? "Move '\(clip.url.lastPathComponent)' Here" : "Paste '\(clip.url.lastPathComponent)' Here", systemImage: "doc.on.clipboard")
                            }
                        }
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
            .sheet(isPresented: $isShowingImporter) {
                ZDocumentPicker(
                    contentTypes: [.item, .data],
                    allowsMultipleSelection: true,
                    onPick: { urls in
                        isShowingImporter = false
                        importFiles(urls)
                    },
                    onCancel: { isShowingImporter = false }
                )
            }
            .alert("New Folder", isPresented: $isShowingNewFolder) {
                TextField("Folder name", text: $newFolderName)
                Button("Cancel", role: .cancel) { newFolderName = "" }
                Button("Create") { model.createFolder(named: newFolderName); newFolderName = "" }
                    .disabled(newFolderName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .alert("New Text File", isPresented: $isShowingNewTextFile) {
                TextField("notes.txt or config.plist", text: $newTextFileName)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                Button("Cancel", role: .cancel) { newTextFileName = "" }
                Button("Create") {
                    if let created = model.createTextFile(named: newTextFileName) {
                        textEditorItem = created
                    }
                    newTextFileName = ""
                }
            }
            .alert("Archive Tools", isPresented: Binding(
                get: { archiveStatusMessage != nil },
                set: { if !$0 { archiveStatusMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(archiveStatusMessage ?? "")
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
            .sheet(item: $plistEditorItem) { item in
                FilePlistEditorSheet(fileURL: item.url) { model.reload() }
            }
            .sheet(item: $textEditorItem) { item in
                FileTextEditorSheet(fileURL: item.url) { model.reload() }
            }
            .sheet(item: $hexInspectorItem) { item in
                FileHexInspectorSheet(fileURL: item.url) { model.reload() }
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
            if let pair = FileArchiveTools.detectCertificatePair(in: model.currentDirectory) {
                Section {
                    Button {
                        importDetectedPair(pair)
                    } label: {
                        Label("Import Paired Certificate & Profile (\(pair.p12URL.lastPathComponent))", systemImage: "key.radiowaves.forward.fill")
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    }
                } footer: {
                    Text("Detected matching .p12 and .mobileprovision files in this folder.")
                }
            }
            ForEach(filtered) { item in
                FileRowView(
                    item: item,
                    onTap: { handleTap(item) },
                    onShare: { shareItem = ShareURL(url: item.url) },
                    onRename: { fileToRename = item; renameText = item.name },
                    onDelete: { model.delete(item) },
                    onEditPlist: { plistEditorItem = item },
                    onEditText: { textEditorItem = item },
                    onInspectHex: { hexInspectorItem = item },
                    onExtractArchive: { runExtract(item) },
                    onPackageAsIPA: { runPackage(item, kind: .ipa) },
                    onCompressAsZip: { runPackage(item, kind: .zip) },
                    onCopyItem: { clipboardItem = (item.url, false) },
                    onMoveItem: { clipboardItem = (item.url, true) },
                    onImportToZynSign: { importSingleItemToWorkspace(item) }
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
        } else if ["plist", "entitlements", "strings", "mobileconfig"].contains(item.ext) {
            plistEditorItem = item
        } else if ["txt", "json", "xml", "md", "log", "yaml", "yml"].contains(item.ext) {
            textEditorItem = item
        } else {
            shareItem = ShareURL(url: item.url)
        }
    }

    private func runExtract(_ item: FileItem) {
        Task {
            do {
                let out = try await FileArchiveTools.extractArchive(at: item.url, in: model.currentDirectory)
                model.reload()
                ZHaptics.success()
                archiveStatusMessage = "Extracted into “\(out.lastPathComponent)”."
            } catch {
                archiveStatusMessage = error.localizedDescription
            }
        }
    }

    private func runPackage(_ item: FileItem, kind: FileArchiveTools.PackageOutputKind) {
        Task {
            do {
                let out = try await FileArchiveTools.packageDirectory(
                    at: item.url,
                    as: kind,
                    in: model.currentDirectory
                )
                model.reload()
                ZHaptics.success()
                archiveStatusMessage = "Created “\(out.lastPathComponent)”."
            } catch {
                archiveStatusMessage = error.localizedDescription
            }
        }
    }

    private func importSingleItemToWorkspace(_ item: FileItem) {
        if item.ext == "ipa" || item.ext == "tipa" {
            _ = environment.importHub.receive([item.url], origin: .documentPicker)
            importPresentation.present()
        } else if item.ext == "mobileprovision" || item.ext == "provisionprofile" {
            Task {
                if let importer = environment.provisioningProfileImporter,
                   let summary = try? await importer.importProfile(at: item.url) {
                    try? await environment.provisioningProfiles?.upsert(summary)
                    ZHaptics.success()
                    archiveStatusMessage = "Imported provisioning profile “\(item.name)”."
                }
            }
        } else if item.ext == "dylib" || item.ext == "deb" {
            if let data = try? Data(contentsOf: item.url),
               let tweakLib = environment.tweakLibrary,
               case .success(let outcome) = (try? tweakLib.importPayload(data, fileName: item.name)) {
                ZHaptics.success()
                archiveStatusMessage = "Imported “\(outcome.descriptor.name)” into Tweak Library."
            }
        } else {
            shareItem = ShareURL(url: item.url)
        }
    }

    private func importDetectedPair(_ pair: FileArchiveTools.DetectedCertificatePair) {
        Task {
            var messages: [String] = []
            if let importer = environment.provisioningProfileImporter,
               let summary = try? await importer.importProfile(at: pair.profileURL) {
                try? await environment.provisioningProfiles?.upsert(summary)
                messages.append("Imported profile \(pair.profileURL.lastPathComponent).")
            }
            if let pw = pair.passwordHint,
               let p12Bytes = try? Data(contentsOf: pair.p12URL),
               (try? environment.pkcs12Importer.importPKCS12(data: p12Bytes, password: pw)) != nil {
                messages.append("Imported identity \(pair.p12URL.lastPathComponent).")
            } else {
                messages.append("Open Certificates & Profiles to enter the password for \(pair.p12URL.lastPathComponent).")
            }
            ZHaptics.success()
            archiveStatusMessage = messages.joined(separator: " ")
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

    func createTextFile(named: String) -> FileItem? {
        let trimmed = named.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("/") else { return nil }
        let target = FileArchiveTools.uniqueDestinationURL(baseName: trimmed, pathExtension: nil, in: currentURL)
        let starter: Data
        if target.pathExtension.lowercased() == "plist" {
            starter = (try? PlistDocumentCodec.encode([:], format: .xml)) ?? Data()
        } else {
            starter = Data()
        }
        try? starter.write(to: target, options: .atomic)
        reload()
        return items.first { $0.url == target }
    }

    func pasteClipboard(_ sourceURL: URL, move: Bool) {
        let dest = FileArchiveTools.uniqueDestinationURL(
            baseName: sourceURL.deletingPathExtension().lastPathComponent,
            pathExtension: sourceURL.pathExtension.isEmpty ? nil : sourceURL.pathExtension,
            in: currentURL
        )
        let fm = FileManager.default
        if move {
            try? fm.moveItem(at: sourceURL, to: dest)
        } else {
            try? fm.copyItem(at: sourceURL, to: dest)
        }
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
    let onEditPlist: () -> Void
    let onEditText: () -> Void
    let onInspectHex: () -> Void
    let onExtractArchive: () -> Void
    let onPackageAsIPA: () -> Void
    let onCompressAsZip: () -> Void
    let onCopyItem: () -> Void
    let onMoveItem: () -> Void
    let onImportToZynSign: () -> Void

    private var isArchive: Bool {
        ["ipa", "tipa", "zip", "deb"].contains(item.ext)
    }

    var body: some View {
        HStack(spacing: ZSpacing.sm) {
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
            if item.isDirectory {
                Button { onPackageAsIPA() } label: { Label("Package Folder as .ipa", systemImage: "app.badge") }
                Button { onCompressAsZip() } label: { Label("Compress Folder as .zip", systemImage: "doc.zipper") }
            } else {
                if ["ipa", "tipa", "mobileprovision", "provisionprofile", "dylib", "deb"].contains(item.ext) {
                    Button { onImportToZynSign() } label: { Label("Import into ZynSign", systemImage: "tray.and.arrow.down.fill") }
                }
                if isArchive {
                    Button { onExtractArchive() } label: { Label("Extract Archive", systemImage: "archivebox") }
                }
                Button { onEditPlist() } label: { Label("Property List Editor", systemImage: "list.bullet.indent") }
                Button { onEditText() } label: { Label("Text Editor", systemImage: "doc.plaintext") }
                Button { onInspectHex() } label: { Label("Hex Inspector & Editor", systemImage: "number.square") }
            }
            Divider()
            Button { onCopyItem() } label: { Label("Copy", systemImage: "doc.on.doc") }
            Button { onMoveItem() } label: { Label("Cut / Move", systemImage: "folder") }
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
