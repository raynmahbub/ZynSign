import SwiftUI

/// The Home area — the dashboard the user lands on.
///
/// Home summarizes what ZynSign actually holds and offers the operations that
/// matter most: bringing a package in and seeing what is already there.
struct HomeView: View {

    @Environment(\.applicationEnvironment) private var environment
    @StateObject private var missionControl = MissionControlService()
    @State private var libraryCount: Int = 0
    @State private var failedLoad = false
    @State private var isShowingImporter = false
    @State private var importNotice: String?
    @State private var importInProgress = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: ZSpacing.lg) {
                    headerCard
                    if ReleaseTrain.isAvailable(.missionControl) {
                        missionControlCard
                    }
                    quickActions
                    librarySummary
                    if importInProgress {
                        HStack { ProgressView(); Text("Importing…").font(.footnote).foregroundStyle(.secondary) }
                            .frame(maxWidth: .infinity).padding().zynCardBackground()
                    }
                    if let notice = importNotice {
                        Text(notice).font(.footnote).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading).padding().zynCardBackground()
                    }
                    capabilitiesCard
                    tipsCard
                }
                .padding()
            }
            .navigationTitle("Home")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { isShowingImporter = true } label: {
                        Label("Import", systemImage: "square.and.arrow.down")
                    }
                    .disabled(importInProgress)
                }
            }
            .fileImporter(
                isPresented: $isShowingImporter,
                allowedContentTypes: ImportablePackage.contentTypes,
                allowsMultipleSelection: false
            ) { result in handlePicker(result) }
            .task { await reloadCount() }
            .refreshable { await reloadCount() }
        }
    }

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: ZSpacing.sm) {
            HStack(spacing: ZSpacing.sm) {
                Image(systemName: "signature")
                    .font(.system(size: 36, weight: .regular))
                    .foregroundStyle(.white)
                    .frame(width: 56, height: 56)
                    .background(Color.accentColor)
                    .clipShape(RoundedRectangle(cornerRadius: ZRadius.icon))
                VStack(alignment: .leading, spacing: 2) {
                    Text("ZynSign")
                        .font(.title2.weight(.bold))
                    Text("\(environment.applicationInfo.marketingVersion) (\(environment.applicationInfo.buildVersion))")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            Text("On-device package inspection, library, and — when the pipeline is composed — signing and deterministic packaging. Nothing leaves the device, no desktop helper.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding()
        .zynHeaderBackground()
    }

    private var missionControlCard: some View {
        ZCard(variant: .material, cornerRadius: ZRadius.lg) {
            VStack(alignment: .leading, spacing: ZSpacing.sm) {
                HStack {
                    Label("Mission Control", systemImage: "command").font(.headline)
                    Spacer()
                    if missionControl.isRunning { ProgressView() }
                }
                Text("One tap: refresh sources → check library → cache cleanup. Re-sign is policy-checked, never auto-triggered without your confirm.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let report = missionControl.lastReport {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: ZSpacing.xs) {
                            ZStatusBadge(report.repository.status, systemImage: "globe", kind: report.repository.status == "Completed" ? .success : .neutral)
                            ZStatusBadge("\(report.library.count) apps", systemImage: "square.grid.2x2", kind: .neutral)
                            ZStatusBadge("\(report.cacheCleanup.count) cleaned", systemImage: "trash", kind: .neutral)
                        }
                        Text("Last run \(report.durationMilliseconds) ms • \(report.repository.detail) • \(report.cacheCleanup.detail)")
                            .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                    }
                    .padding(.vertical, 4)
                }
                Button {
                    ZHaptics.tap()
                    Task {
                        _ = await missionControl.refreshEverything(
                            refreshRepositories: {
                                // Trigger AppStore refresh via notification; count sources from persistence
                                let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
                                let storeURL = docs?.appendingPathComponent("ZynSignSources.json")
                                if let data = try? Data(contentsOf: storeURL!), let arr = try? JSONDecoder().decode([[String:String]].self, from: data) {
                                    return arr.count
                                }
                                return 0
                            },
                            checkLibrary: {
                                if let entries = try? await environment.library.entries() { return entries.count }
                                return 0
                            },
                            cleanupCache: { missionControl.defaultCleanup() }
                        )
                        await reloadCount()
                        ZHaptics.success()
                    }
                } label: {
                    HStack { Spacer(); Label(missionControl.isRunning ? "Refreshing…" : "Refresh Everything", systemImage: "arrow.triangle.2.circlepath"); Spacer() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(missionControl.isRunning)
            }
        }
    }

    private var quickActions: some View {
        VStack(alignment: .leading, spacing: ZSpacing.xs) {
            Text("Quick Actions")
                .font(.headline)
            HStack(spacing: ZSpacing.sm) {
                HomeActionButton(title: "Import IPA", icon: "square.and.arrow.down.fill", color: .blue) {
                    isShowingImporter = true
                }
                HomeActionButton(title: "Library", icon: "square.grid.2x2.fill", color: .purple) {}
                HomeActionButton(title: "Files", icon: "folder.fill", color: .orange) {}
            }
        }
    }

    private var librarySummary: some View {
        VStack(alignment: .leading, spacing: ZSpacing.xs) {
            HStack {
                Text("Library")
                    .font(.headline)
                Spacer()
                if failedLoad {
                    Text("Unavailable").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("\(libraryCount) app\(libraryCount == 1 ? "" : "s")")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            if libraryCount == 0 && !failedLoad {
                ContentUnavailableView {
                    Label("No Apps Yet", systemImage: "square.stack.3d.up")
                } description: {
                    Text("Import an .ipa to see it here. ZynSign reads its structure and declared metadata and keeps it across launches.")
                }
                .frame(height: 160)
                .zynCardBackground()
            } else if !failedLoad {
                HStack(spacing: ZSpacing.sm) {
                    StatPill(value: "\(libraryCount)", label: "Imported")
                    if ReleaseTrain.isAvailable(.smartSign) {
                        StatPill(value: "—", label: "Signed")
                    }
                    if ReleaseTrain.isAvailable(.appStore) {
                        StatPill(value: "—", label: "Sources")
                    }
                }
            }
        }
        .padding()
        .zynCardBackground(cornerRadius: ZRadius.lg)
    }

    private var capabilitiesCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("What this build does", systemImage: "checkmark.shield").font(.headline)
            VStack(alignment: .leading, spacing: 6) {
                CapabilityRow(icon: "doc.zipper", text: "Reads ZIP entry table, validates layout, classifies findings in precedence order")
                CapabilityRow(icon: "info.circle", text: "Extracts bundle metadata (bundle ID, display name, versions) deterministically")
                CapabilityRow(icon: "externaldrive", text: "Persists accepted packages in Application Support with SHA-256 fingerprint, versioned catalog")
                CapabilityRow(icon: "folder", text: "Bundle explorer lists files inside the .app read-only — no extraction, no link following")
            }
            .font(.footnote).foregroundStyle(.secondary)
        }
        .padding().zynCardBackground(cornerRadius: ZRadius.lg)
    }

    private var tipsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Tips", systemImage: "lightbulb").font(.headline)
            Text(tips.map { "• \($0)" }.joined(separator: "\n"))
                .font(.footnote).foregroundStyle(.secondary)
        }
        .padding().zynCardBackground(cornerRadius: ZRadius.lg)
    }

    /// Tips only mention areas this release actually shows.
    private var tips: [String] {
        var tips = ["Files tab browses the same storage the Library uses — share or move an IPA without leaving ZynSign."]
        if ReleaseTrain.isAvailable(.downloads) {
            tips.append("Downloads tab accepts direct .ipa URLs and itms-services manifests.")
        }
        if ReleaseTrain.isAvailable(.appStore) {
            tips.append("App Store tab aggregates your configured sources.")
        }
        if !ReleaseTrain.isAvailable(.downloads) && !ReleaseTrain.isAvailable(.appStore) {
            tips.append("Open an application in Library to explore the files inside its bundle, read-only.")
        }
        return tips
    }

    private func handlePicker(_ result: Result<URL, any Error>) {
        switch result {
        case .success(let url):
            importInProgress = true
            importNotice = nil
            Task {
                do {
                    let res = try await environment.packageImport.importArtifact(from: url)
                    if res.isAccepted {
                        importNotice = "Imported \(res.artifact.metadata?.identity.bundleIdentifier.rawValue ?? "package") — added to Library."
                    } else {
                        let code = res.artifact.validation?.errors.first?.code
                        importNotice = code.map { "Import rejected: \($0)" } ?? "This file is not a valid application package."
                    }
                } catch let e as ZynSignError {
                    importNotice = e.userMessage
                } catch is CancellationError {
                    importNotice = "Import cancelled."
                } catch {
                    importNotice = "The import could not be completed."
                }
                importInProgress = false
                await reloadCount()
            }
        case .failure(let err):
            let ns = err as NSError
            if ns.domain == NSCocoaErrorDomain && ns.code == NSUserCancelledError { return }
            importNotice = (err as? ZynSignError)?.userMessage ?? "The picker could not provide the selected file."
        }
    }

    private func reloadCount() async {
        do {
            let entries = try await environment.library.entries()
            libraryCount = entries.count
            failedLoad = false
        } catch {
            failedLoad = true
        }
    }
}

private struct HomeActionButton: View {
    let title: String; let icon: String; let color: Color; let action: () -> Void
    var body: some View {
        Button {
            ZHaptics.tap()
            action()
        } label: {
            VStack(spacing: ZSpacing.xs) {
                Image(systemName: icon).font(.title2).foregroundStyle(color)
                Text(title).font(.caption.weight(.medium)).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity).padding(.vertical, ZSpacing.sm)
            .zynCardBackground()
        }.buttonStyle(.plain)
        .sensoryFeedback(.impact(weight: .light), trigger: title)
    }
}
private struct StatPill: View {
    let value: String; let label: String
    var body: some View {
        VStack(spacing: 2) {
            Text(value).font(.title3.weight(.bold)).monospacedDigit()
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity).padding(.vertical, ZSpacing.xs).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: ZRadius.sm))
    }
}
private struct CapabilityRow: View {
    let icon: String; let text: String
    var body: some View { Label(text, systemImage: icon).labelStyle(.titleAndIcon) }
}
