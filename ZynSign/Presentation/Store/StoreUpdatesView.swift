import SwiftUI

struct StoreUpdatesView: View {
    @ObservedObject var model: StoreBrowserModel
    @Environment(\.applicationEnvironment) private var environment
    @State private var confirmAll = false
    var body: some View {
        List {
            Section {
                Text("Updates compare source releases with packages in your Library, not the device's installed apps. Choose a preferred source for each app; ZynSign never switches it automatically.")
                    .font(.footnote).foregroundStyle(.secondary)
                Text("Only numeric dotted versions are ordered. Prerelease and custom version strings require manual review.").font(.caption).foregroundStyle(.secondary)
                NavigationLink("View Download Jobs") { StoreDownloadsView(queue: model.downloads) }
            }
            Section("Available Updates · \(model.updates.count)") {
                if model.updates.isEmpty { ContentUnavailableView("No Available Updates", systemImage: "checkmark.circle", description: Text("No newer comparable versions were found in your enabled, preferred sources.")) }
                ForEach(model.updates) { update in
                    VStack(alignment: .leading, spacing: 10) {
                        StoreAppLink(app: update.app, model: model)
                        LabeledContent("Library → Latest", value: "\(update.installed) → \(update.app.latest.version)")
                        Text(update.app.latest.notes ?? "No release notes supplied.").font(.caption).lineLimit(4)
                        if !model.liveSources.contains(update.app.sourceID) { Label("Based on saved metadata", systemImage: "internaldrive").font(.caption) }
                        Button("Update") { model.download(update.app) }.frame(minHeight: 44)
                        Button("Ignore Version \(update.app.latest.version)") { Task { await model.ignore(update.app) } }.frame(minHeight: 44)
                    }
                }
            }
            Section("Choose a Source") {
                ForEach(model.needsSourceChoice) { StoreAppLink(app: $0, model: model) }
                if model.needsSourceChoice.isEmpty { Text("No apps awaiting a source choice.").foregroundStyle(.secondary) }
                ForEach(unavailablePreferences, id: \.self) { bundle in
                    VStack(alignment: .leading) {
                        Text(bundle).font(.headline)
                        Text("Your preferred source is disabled, removed, or no longer lists this app. No automatic fallback is used.").font(.caption)
                        if let alternative = model.apps.first(where: { $0.bundleID == bundle }) {
                            StoreAppLink(app: alternative, model: model)
                        }
                    }
                }
            }
            if !model.snapshot.ignoredVersions.isEmpty {
                Section { Button("Restore Ignored Versions") { Task { await model.clearIgnored() } } }
            }
        }
        .navigationTitle("Updates")
        .toolbar { Button("Update All") { confirmAll = true }.disabled(model.updates.isEmpty) }
        .confirmationDialog("Queue \(model.updates.count) updates?", isPresented: $confirmAll, titleVisibility: .visible) {
            Button("Download All Updates") { model.updateAll() }
        } message: { Text("Each job keeps its chosen source. Downloads do not automatically import, sign, or install packages.") }
        .task { await model.load(library: environment.library) }
        .refreshable { await model.refreshDue(); await model.load(library: environment.library) }
        .storeNotice($model.problem)
    }
    private var unavailablePreferences: [String] {
        model.snapshot.preferredSources.keys.filter { bundle in
            model.installed[bundle] != nil && !model.apps.contains { $0.bundleID == bundle && $0.sourceID == model.snapshot.preferredSources[bundle] }
        }.sorted()
    }
}
