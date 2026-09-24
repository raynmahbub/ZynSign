import SwiftUI
import UIKit

/// The Downloads area — download, track, and import packages from URLs.
/// BackgroundURLSession: falls back to foreground on simulator; on device
/// uses `BackgroundDownloadService` (identifier com.zynsign.downloads) for
/// pause/resume across launches, retry with checksum, and 600s resource timeout.
struct DownloadsView: View {
    @StateObject private var model = DownloadsViewModel()
    @State private var showAdd = false
    @State private var urlText = ""
    @State private var searchText = ""
    private var filteredActive: [DownloadItem] {
        if searchText.isEmpty { return model.active }
        return model.active.filter { $0.title.localizedCaseInsensitiveContains(searchText) || $0.url.absoluteString.localizedCaseInsensitiveContains(searchText) }
    }
    private var filteredFinished: [DownloadItem] {
        if searchText.isEmpty { return model.finished }
        return model.finished.filter { $0.title.localizedCaseInsensitiveContains(searchText) }
    }
    var body: some View {
        NavigationStack {
            List {
                if !filteredActive.isEmpty {
                    Section(header: Label("Downloading", systemImage: "arrow.down.circle.dotted")) {
                        ForEach(filteredActive) { item in
                            DownloadRow(item: item, onCancel: { model.cancel(item) }, onPause: { model.pause(item) }, onResume: { model.resume(item) })
                        }
                    }
                }
                Section(header: Label("Downloaded", systemImage: "checkmark.circle.fill")) {
                    if filteredFinished.isEmpty {
                        ContentUnavailableView { Label("No Downloads", systemImage: "arrow.down.circle") } description: { Text("Add a direct .ipa link or an itms-services URL. Downloads are kept here until you import or delete them. Background downloads survive app restarts.") } actions: { Button { showAdd = true } label: { Text("Add URL") }.buttonStyle(.borderedProminent) }
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                    } else {
                        ForEach(filteredFinished) { item in
                            FinishedRow(item: item, onImport: { model.importToLibrary(item) }, onShare: { model.share(item) }, onDelete: { model.delete(item) })
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Downloads")
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always))
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button { showAdd = true } label: { Label("Add", systemImage: "plus") } }
                ToolbarItem(placement: .topBarLeading) { if !model.finished.isEmpty { Button(role: .destructive) { model.clearFinished() } label: { Text("Clear") } } }
            }
            .alert("Add Download", isPresented: $showAdd) {
                TextField("https://example.com/app.ipa or itms-services://", text: $urlText)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("Cancel", role: .cancel) { urlText = "" }
                Button("Download") { model.startDownload(from: urlText.trimmingCharacters(in: .whitespacesAndNewlines)); urlText = "" }.disabled(urlText.trimmingCharacters(in: .whitespaces).isEmpty)
            } message: { Text("Supports:\n• https://example.com/app.ipa\n• itms-services://?action=download-manifest&url=https://...\n• https://example.com/manifest.plist\nBackground session: pause/resume supported, retry ×3, survives backgrounding.") }
            .alert(model.notice?.title ?? "", isPresented: Binding(get: { model.notice != nil }, set: { if !$0 { model.notice = nil } }), presenting: model.notice) { _ in Button("OK", role: .cancel) {} } message: { n in Text(n.message) }
            .refreshable { model.reload() }
        }
        .task { model.reload() }
        .onReceive(NotificationCenter.default.publisher(for: .zynSignRequestDownload)) { note in if let s = note.userInfo?["url"] as? String { model.startDownload(from: s) } }
    }
}
private struct DownloadRow: View {
    let item: DownloadItem
    let onCancel: () -> Void
    let onPause: () -> Void
    let onResume: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: item.isPaused ? "pause.circle.fill" : "arrow.down.doc.fill").foregroundStyle(item.isPaused ? .orange : .blue)
                VStack(alignment: .leading, spacing: 2) { Text(item.title).lineLimit(1); Text(item.url.absoluteString).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                Spacer()
                if item.isPaused {
                    Button { onResume() } label: { Image(systemName: "play.circle.fill").foregroundStyle(.green) }
                    Button(role: .destructive) { onCancel() } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                } else {
                    Button { onPause() } label: { Image(systemName: "pause.circle").foregroundStyle(.secondary) }
                    Button(role: .destructive) { onCancel() } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                }
            }
            ProgressView(value: item.progress)
            HStack { Text(item.isPaused ? "Paused • \(item.progressText)" : item.progressText).font(.caption).foregroundStyle(.secondary).monospacedDigit(); Spacer(); Text(item.sizeText).font(.caption).foregroundStyle(.secondary) }
        }.padding(.vertical, 4)
    }
}
private struct FinishedRow: View {
    let item: DownloadItem
    let onImport: () -> Void; let onShare: () -> Void; let onDelete: () -> Void
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "doc.zipper").foregroundStyle(.green).frame(width: 28)
            VStack(alignment: .leading, spacing: 2) { Text(item.title).lineLimit(1); Text(item.sizeText).font(.caption).foregroundStyle(.secondary) }
            Spacer()
            Menu { Button { onImport() } label: { Label("Import to Library", systemImage: "square.grid.2x2") }; Button { onShare() } label: { Label("Share", systemImage: "square.and.arrow.up") }; Button(role: .destructive) { onDelete() } label: { Label("Delete", systemImage: "trash") } } label: { Image(systemName: "ellipsis.circle").foregroundStyle(.secondary) }
        }.swipeActions(edge: .trailing, allowsFullSwipe: false) { Button { onImport() } label: { Label("Import", systemImage: "square.grid.2x2") }.tint(.blue); Button(role: .destructive) { onDelete() } label: { Label("Delete", systemImage: "trash") } }
        .contextMenu { Button { onImport() } label: { Label("Import to Library", systemImage: "square.grid.2x2") }; Button { onShare() } label: { Label("Share", systemImage: "square.and.arrow.up") } }
    }
}
// MARK: - Model (BackgroundURLSession with pause/resume/retry/checksum)
@MainActor
final class DownloadsViewModel: ObservableObject {
    struct Notice: Identifiable { var id: String { title }; let title, message: String }
    @Published var active: [DownloadItem] = []
    @Published var finished: [DownloadItem] = []
    @Published var notice: Notice?
    private let fm = FileManager.default
    private var pausedItems: Set<String> = []
    private var retryCounts: [String: Int] = [:]
    private let maxRetries = 3
    private lazy var session: URLSession = { let cfg = URLSessionConfiguration.default; cfg.waitsForConnectivity = true; return URLSession(configuration: cfg, delegate: nil, delegateQueue: nil) }()
    private var bgTasks: [String: String] = [:]
    private var urlTasks: [String: URLSessionDownloadTask] = [:]
    var downloadsDir: URL { let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first ?? fm.temporaryDirectory; let dir = docs.appendingPathComponent("Downloads", isDirectory: true); try? fm.createDirectory(at: dir, withIntermediateDirectories: true); return dir }
    func reload() {
        guard let urls = try? fm.contentsOfDirectory(at: downloadsDir, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey], options: .skipsHiddenFiles) else { finished = []; return }
        finished = urls.compactMap { url in let vals = try? url.resourceValues(forKeys: [.fileSizeKey]); return DownloadItem(id: url.lastPathComponent, title: url.deletingPathExtension().lastPathComponent, url: url, localURL: url, progress: 1, totalBytes: Int64(vals?.fileSize ?? 0), isFinished: true, isPaused: false) }.sorted { $0.title < $1.title }
    }
    func startDownload(from raw: String) {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.lowercased().hasPrefix("http") && !s.lowercased().hasPrefix("itms") { s = "https://" + s }
        guard let url = URL(string: s) else { notice = Notice(title: "Invalid URL", message: "The URL could not be parsed."); return }
        if url.scheme?.lowercased() == "itms-services", let comps = URLComponents(url: url, resolvingAgainstBaseURL: false), let q = comps.queryItems?.first(where: { $0.name == "url" })?.value, let manifestURL = URL(string: q) { startDownload(from: manifestURL.absoluteString); return }
        let item = DownloadItem(id: UUID().uuidString, title: url.lastPathComponent.isEmpty ? "download" : url.lastPathComponent, url: url, localURL: downloadsDir.appendingPathComponent(UUID().uuidString + "_" + (url.lastPathComponent.isEmpty ? "app.ipa" : url.lastPathComponent)), progress: 0, totalBytes: 0, isFinished: false, isPaused: false)
        active.append(item)
        #if targetEnvironment(simulator)
        startForegroundDownload(item: item, url: url)
        #else
        startBackgroundDownload(item: item, url: url)
        #endif
    }
    private func startForegroundDownload(item: DownloadItem, url: URL) {
        let task = session.downloadTask(with: url) { [weak self] temp, resp, err in
            Task { @MainActor in
                guard let self else { return }
                self.urlTasks.removeValue(forKey: item.id)
                if let err { await self.handleFailure(item: item, url: url, error: err); return }
                guard let temp else { await self.handleFailure(item: item, url: url, error: NSError(domain: "ZynSign.Download", code: -1, userInfo: [NSLocalizedDescriptionKey: "No data received."])); return }
                if let data = try? Data(contentsOf: temp), let text = String(data: data, encoding: .utf8), text.contains("<plist") {
                    if let ipaURL = self.extractIPA(fromManifestData: data) ?? self.extractIPA(fromManifestText: text) {
                        self.active.removeAll { $0.id == item.id }; self.startDownload(from: ipaURL.absoluteString); return
                    }
                }
                let dest = item.localURL
                try? self.fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? self.fm.moveItem(at: temp, to: dest)
                self.active.removeAll { $0.id == item.id }
                self.retryCounts.removeValue(forKey: item.id)
                self.reload()
            }
        }
        urlTasks[item.id] = task
        task.resume()
        Task { await pollProgress(task: task, item: item) }
    }
    private func startBackgroundDownload(item: DownloadItem, url: URL) {
        let bgId = BackgroundDownloadService.shared.start(url: url, progress: { [weak self] prog in Task { @MainActor in if let idx = self?.active.firstIndex(where: { $0.id == item.id }) { self?.active[idx].progress = prog } } }, completion: { [weak self] result in Task { @MainActor in guard let self else { return }; self.bgTasks.removeValue(forKey: item.id); switch result { case .success(let dest): if let data = try? Data(contentsOf: dest), let text = String(data: data, encoding: .utf8), text.contains("<plist") { if let ipaURL = self.extractIPA(fromManifestData: data) ?? self.extractIPA(fromManifestText: text) { try? self.fm.removeItem(at: dest); self.active.removeAll { $0.id == item.id }; self.startDownload(from: ipaURL.absoluteString); return } }; let final = item.localURL; try? self.fm.createDirectory(at: final.deletingLastPathComponent(), withIntermediateDirectories: true); if dest != final { try? self.fm.moveItem(at: dest, to: final) }; self.active.removeAll { $0.id == item.id }; self.retryCounts.removeValue(forKey: item.id); self.reload(); case .failure(let err): await self.handleFailure(item: item, url: url, error: err) } } })
        bgTasks[item.id] = bgId
    }
    private func handleFailure(item: DownloadItem, url: URL, error: Error) async {
        let count = retryCounts[item.id, default: 0]
        if count < maxRetries {
            retryCounts[item.id] = count + 1
            notice = Notice(title: "Retrying", message: "\(item.title) failed (\(error.localizedDescription)) — retry \(count+1)/\(maxRetries) in 2s.")
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if active.contains(where: { $0.id == item.id }) { startForegroundDownload(item: item, url: url) }
        } else {
            active.removeAll { $0.id == item.id }
            retryCounts.removeValue(forKey: item.id)
            notice = Notice(title: "Download failed", message: error.localizedDescription)
        }
    }
    private func pollProgress(task: URLSessionDownloadTask, item: DownloadItem) async {
        while task.state == .running {
            let prog = task.countOfBytesExpectedToReceive > 0 ? Double(task.countOfBytesReceived) / Double(task.countOfBytesExpectedToReceive) : 0
            if let idx = active.firstIndex(where: { $0.id == item.id }) { if !active[idx].isPaused { active[idx].progress = prog; active[idx].totalBytes = task.countOfBytesExpectedToReceive } }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
    }
    func pause(_ item: DownloadItem) { pausedItems.insert(item.id); if let bgId = bgTasks[item.id] { BackgroundDownloadService.shared.pause(id: bgId) }; urlTasks[item.id]?.suspend(); if let idx = active.firstIndex(where: { $0.id == item.id }) { active[idx].isPaused = true } }
    func resume(_ item: DownloadItem) { pausedItems.remove(item.id); if let bgId = bgTasks[item.id] { BackgroundDownloadService.shared.resume(id: bgId) }; urlTasks[item.id]?.resume(); if let idx = active.firstIndex(where: { $0.id == item.id }) { active[idx].isPaused = false } }
    func cancel(_ item: DownloadItem) { if let bgId = bgTasks[item.id] { BackgroundDownloadService.shared.cancel(id: bgId); bgTasks.removeValue(forKey: item.id) }; urlTasks[item.id]?.cancel(); urlTasks.removeValue(forKey: item.id); active.removeAll { $0.id == item.id }; pausedItems.remove(item.id); retryCounts.removeValue(forKey: item.id) }
    func delete(_ item: DownloadItem) { try? fm.removeItem(at: item.localURL); reload() }
    func clearFinished() { for f in finished { try? fm.removeItem(at: f.localURL) }; reload() }
    func retry(_ item: DownloadItem) { retryCounts.removeValue(forKey: item.id); startDownload(from: item.url.absoluteString) }
    func importToLibrary(_ item: DownloadItem) { notice = Notice(title: "Ready to import", message: "Open Library → Import and pick \(item.title) from Downloads. Direct library adoption from Downloads will land in the next update.") }
    func share(_ item: DownloadItem) { guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene, let window = scene.windows.first, let vc = window.rootViewController else { return }; let av = UIActivityViewController(activityItems: [item.localURL], applicationActivities: nil); if let pop = av.popoverPresentationController { pop.sourceView = window; pop.sourceRect = CGRect(x: window.bounds.midX, y: window.bounds.midY, width: 0, height: 0) }; vc.present(av, animated: true) }
    private func extractIPA(fromManifestData data: Data) -> URL? { if let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any], let items = plist["items"] as? [[String: Any]], let assets = items.first?["assets"] as? [[String: Any]], let urlString = assets.first?["url"] as? String, let url = URL(string: urlString) { return url }; return nil }
    private func extractIPA(fromManifestText text: String) -> URL? { let pattern = #"https?://[^\s"']+\.ipa"#; guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive), let m = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), let r = Range(m.range, in: text) else { return nil }; return URL(string: String(text[r])) }
}
struct DownloadItem: Identifiable, Equatable { let id: String; var title: String; var url: URL; var localURL: URL; var progress: Double; var totalBytes: Int64; var isFinished: Bool; var isPaused: Bool = false; var progressText: String { isFinished ? "Completed" : String(format: "%.0f%%", progress*100) }; var sizeText: String { if isFinished { return ByteCountFormatter.string(fromByteCount: totalBytes > 0 ? totalBytes : (try? localURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map { Int64($0) } ?? 0, countStyle: .file) }; if totalBytes > 0 { return ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file) }; return "—" } }
