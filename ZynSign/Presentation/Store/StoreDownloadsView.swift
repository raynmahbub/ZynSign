import SwiftUI

struct StoreDownloadsView: View {
    @ObservedObject var queue: StoreDownloadQueue
    @Environment(\.applicationEnvironment) private var environment
    @Environment(\.importPresentation) private var importPresentation
    var body: some View {
        List {
            Section {
                Text("Packages stay in isolated Store storage until you import them for inspection. Up to two transfers run at once. Pause keeps a live transfer suspended; after app termination, retry starts over.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if queue.jobs.isEmpty { ContentUnavailableView("No Store Downloads", systemImage: "arrow.down.circle", description: Text("Choose an app in the Store to queue a download.")) }
            ForEach(queue.jobs) { job in
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(job.name).font(.headline)
                        Label("\(job.sourceName) · \(job.release.version)", systemImage: "globe").font(.caption)
                        Text(job.state.rawValue.capitalized).font(.subheadline.weight(.semibold))
                        if job.state == .downloading || job.state == .paused {
                            if let progress = job.progress {
                                ProgressView(value: progress).accessibilityLabel("Download progress for \(job.name)")
                                Text(progress, format: .percent.precision(.fractionLength(0))).font(.caption.monospacedDigit())
                            } else { ProgressView("Waiting for download size") }
                        }
                        if let failure = job.failure { Text(failure).font(.caption).foregroundStyle(.red) }
                    }
                    controls(job)
                }
            }
        }
        .navigationTitle("Store Downloads")
        .task { queue.restore() }
        .storeNotice($queue.problem)
    }
    @ViewBuilder private func controls(_ job: StoreDownloadJob) -> some View {
        switch job.state {
        case .queued:
            Button("Cancel", role: .destructive) { queue.cancel(job.id) }
        case .downloading:
            Button("Pause") { queue.pause(job.id) }
            Button("Cancel", role: .destructive) { queue.cancel(job.id) }
        case .paused:
            Button("Resume") { queue.resume(job.id) }
            Button("Cancel", role: .destructive) { queue.cancel(job.id) }
        case .ready:
            Button("Import to Library") {
                if queue.importPackage(job, into: environment.importHub) { importPresentation.present() }
            }.disabled(!importPresentation.isAvailable)
            Text("Ready for inspection — not verified or installed.").font(.caption).foregroundStyle(.secondary)
            Button("Delete Package", role: .destructive) { queue.remove(job.id) }
        case .failed, .cancelled:
            Button("Retry") { queue.retry(job.id) }
            Button("Remove Job", role: .destructive) { queue.remove(job.id) }
        }
    }
}
