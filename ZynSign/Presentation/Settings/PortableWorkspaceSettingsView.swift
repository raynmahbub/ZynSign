import SwiftUI
import UniformTypeIdentifiers
import UIKit

/// Portable Workspace (`Documents/ZynSignPortable`) mirror and external
/// workspace directory import screen.
struct PortableWorkspaceSettingsView: View {
    @Environment(\.applicationEnvironment) private var environment
    @Environment(\.settingsCenter) private var settings

    @State private var isExporting = false
    @State private var isImporting = false
    @State private var isPickingFolder = false
    @State private var statusMessage: String?

    var body: some View {
        List {
            Section {
                ZSettingsToggleRow(
                    title: "Auto-Mirror After Import",
                    subtitle: "Keep Documents/ZynSignPortable synchronized when packages arrive.",
                    symbol: "arrow.triangle.2.circlepath.doc.on.clipboard",
                    isOn: settings.binding(\.general.autoMirrorsPortableWorkspace)
                )
                Button {
                    Task { await runExportMirror() }
                } label: {
                    HStack {
                        Label(isExporting ? "Syncing Portable Folder…" : "Sync Portable Folder Now", systemImage: "folder.fill.badge.gearshape")
                        Spacer()
                        if isExporting { ProgressView() }
                    }
                    .frame(minHeight: 44)
                }
                .disabled(isExporting)
            } header: {
                Text("Files-App Survival Mirror")
            } footer: {
                Text("Writes repository URLs (Sources.json & sources.txt), provisioning profiles, tweak payloads, auto-inject rules, and Library IPAs into Documents/ZynSignPortable so you can copy them from the stock iOS Files app even if a certificate is revoked. Private keys never leave the Keychain.")
            }

            Section {
                Button {
                    isPickingFolder = true
                } label: {
                    HStack {
                        Label(isImporting ? "Importing…" : "Import External Workspace Folder…", systemImage: "square.and.arrow.down.on.square")
                        Spacer()
                        if isImporting { ProgressView() }
                    }
                    .frame(minHeight: 44)
                }
                .disabled(isImporting)
            } header: {
                Text("Workspace Directory Import")
            } footer: {
                Text("Select a ZynSignPortable directory or an exported Documents workspace folder in Files to import its repositories, profiles, tweaks, and .ipa packages in one step.")
            }

            if let statusMessage {
                Section("Result") {
                    Text(statusMessage)
                        .font(ZTypography.caption)
                        .textSelection(.enabled)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Portable Workspace")
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(isPresented: $isPickingFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let folderURL) = result {
                Task { await runFolderMigration(folderURL) }
            }
        }
    }

    private func runExportMirror() async {
        guard let service = environment.portableWorkspaceSync else {
            statusMessage = "Portable Workspace service is not composed."
            return
        }
        isExporting = true
        defer { isExporting = false }
        do {
            let report = try await service.exportPortableMirror(environment: environment)
            ZHaptics.success()
            statusMessage = "Mirrored \(report.sourcesCount) source(s), \(report.profilesCount) profile(s), \(report.tweaksCount) tweak(s), and \(report.packagesCount) package(s) to Documents/\(report.destinationPath)."
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func runFolderMigration(_ folderURL: URL) async {
        guard let service = environment.portableWorkspaceSync else { return }
        isImporting = true
        defer { isImporting = false }
        do {
            let report = try await service.importFromFolder(folderURL, environment: environment)
            ZHaptics.success()
            statusMessage = "Imported \(report.sourcesCount) source(s), \(report.profilesCount) profile(s), \(report.tweaksCount) tweak(s), and queued \(report.packagesCount) package(s)."
        } catch {
            statusMessage = error.localizedDescription
        }
    }
}

/// Live & post-run timestamped Signing Console Log viewer.
struct SigningConsoleLogSheet: View {
    let lines: [String]
    @Environment(\.dismiss) private var dismiss
    @State private var showCopied = false

    var body: some View {
        NavigationStack {
            List {
                if lines.isEmpty {
                    Text("No signing log entries recorded for this session yet. Start a signing or modify run to stream live console events.")
                        .font(ZTypography.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Section("Console Stream (\(lines.count) events)") {
                        ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(ZTypography.codeCaption)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
            .navigationTitle("Signing Console")
            .navigationBarTitleDisplayMode(.inline)
            .zToast(isPresented: $showCopied, message: "Console log copied.", style: .info)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if !lines.isEmpty {
                        Button {
                            UIPasteboard.general.string = lines.joined(separator: "\n")
                            ZHaptics.tap()
                            showCopied = true
                        } label: {
                            Label("Copy", systemImage: "doc.on.doc")
                        }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
