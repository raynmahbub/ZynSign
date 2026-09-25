import SwiftUI
import UIKit

/// Diagnostics — what ZynSign records about itself, and what it will hand you.
///
/// Everything this section controls stays on the device. There is no sender,
/// no endpoint, and no sync anywhere in ZynSign, so a diagnostic report is
/// written to a file the user shares themselves or not at all.
///
/// Technical logging is opt-in and off by default: the toggle explains what
/// turning it on writes, and the log says what it holds and can be cleared in
/// one tap.
struct DiagnosticsPreferencesSection: View {

    @Environment(\.settingsCenter) private var settings
    @State private var entryCount: Int?
    @State private var isConfirmingLogClear = false
    @State private var shareItem: SettingsShareItem?

    static let descriptor = SettingsSectionDescriptor(
        identifier: .diagnostics,
        title: "Diagnostics",
        symbolName: "stethoscope",
        summary: "Health analysis, history, technical logs, and reports.",
        footer: "Diagnostics describe ZynSign's own behaviour. They are redacted, on-device, and never transmitted."
    )

    var body: some View {
        List {
            analysisSection
            loggingSection
            developerSection
            logSection
            guaranteeSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle(Self.descriptor.title)
        .navigationBarTitleDisplayMode(.inline)
        .task { await reload() }
        .sheet(item: $shareItem) { item in
            SettingsShareSheet(url: item.url)
        }
        .alert("Clear Technical Log?", isPresented: $isConfirmingLogClear) {
            Button("Cancel", role: .cancel) {}
            Button("Clear", role: .destructive) { Task { await clearLog() } }
        } message: {
            Text("Every entry is deleted from this device. Nothing was ever transmitted, so nothing needs recalling.")
        }
    }

    // MARK: - Analysis

    private var analysisSection: some View {
        Section {
            ZSettingsToggleRow(
                title: "Automatic Health Analysis",
                subtitle: "Assess the library, identities, and profiles without being asked.",
                symbol: "heart.text.square",
                isOn: settings.binding(\.diagnostics.automaticHealthAnalysis)
            )
            ZSettingsToggleRow(
                title: "Keep Diagnostic History",
                subtitle: "Retain what was recorded between launches.",
                symbol: "clock.arrow.circlepath",
                isOn: settings.binding(\.diagnostics.keepDiagnosticHistory)
            )
        } header: {
            Text("Analysis")
        } footer: {
            Text("With history off, nothing new is recorded and what is already there is left alone — a cleared log stays cleared.")
        }
    }

    // MARK: - Logging

    private var loggingSection: some View {
        Section {
            ZSettingsToggleRow(
                title: "Detailed Technical Logs",
                subtitle: "Record what ZynSign did, entry by entry.",
                symbol: "doc.text.magnifyingglass",
                isOn: settings.binding(\.diagnostics.detailedTechnicalLogs)
            )
        } header: {
            Text("Technical Logging")
        } footer: {
            Text("Off by default. When on, ZynSign records fixed entries — a category, a time, and a fixed slug such as \"storage.temporary.cleared\" — never a file name, a path, a bundle identifier, or anything about your certificates.")
        }
    }

    // MARK: - Developer

    private var developerSection: some View {
        Section {
            ZSettingsToggleRow(
                title: "Developer Diagnostics",
                subtitle: "Show raw categories, counts, and schema versions.",
                symbol: "hammer",
                isOn: settings.binding(\.diagnostics.developerDiagnostics)
            )
        } header: {
            Text("Developer")
        } footer: {
            Text("For reading a report next to the screen that produced it. Nothing here changes what ZynSign does; it changes what it shows.")
        }
    }

    // MARK: - Log

    private var logSection: some View {
        Section {
            ZSettingsValueRow(
                title: "Entries",
                symbol: "list.bullet.rectangle",
                subtitle: "How many entries the technical log holds."
            ) {
                Text(entryCount.map { "\($0)" } ?? "—")
                    .foregroundStyle(.secondary)
            }
            NavigationLink {
                DiagnosticLogView()
            } label: {
                ZSettingsLabel(
                    title: "View Technical Log",
                    subtitle: "Read what ZynSign recorded.",
                    symbol: "doc.text"
                )
            }
            ZSettingsButtonRow(
                title: "Export Diagnostic Report",
                subtitle: "Write a report you can read and share.",
                symbol: "square.and.arrow.up",
                action: exportReport
            )
            ZSettingsButtonRow(
                title: "Clear Technical Log",
                subtitle: "Delete every entry on this device.",
                symbol: "trash",
                isDestructive: true,
                action: { isConfirmingLogClear = true }
            )
            .disabled((entryCount ?? 0) == 0)
        } header: {
            Text("Technical Log")
        } footer: {
            Text("A report holds counts, versions, and preference flags — never a bundle identifier, a file name, a path, or certificate detail. Export writes it to a file you share yourself.")
        }
    }

    // MARK: - Guarantee

    private var guaranteeSection: some View {
        Section {
            ForEach(AnalyticsPolicy.Guarantee.allCases, id: \.self) { guarantee in
                Label(guarantee.message, systemImage: "checkmark.shield")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Guarantees")
        }
    }

    // MARK: - Actions

    private func reload() async {
        entryCount = await settings.diagnosticEntryCount()
    }

    private func clearLog() async {
        await settings.clearDiagnosticLog()
        await reload()
    }

    private func exportReport() {
        Task {
            if let url = await settings.exportDiagnosticReport() {
                shareItem = SettingsShareItem(url: url)
            }
        }
    }
}

/// The technical log's entries.
private struct DiagnosticLogView: View {

    @Environment(\.settingsCenter) private var settings
    @State private var entries: [DiagnosticLogEntry] = []

    var body: some View {
        List {
            if entries.isEmpty {
                ContentUnavailableView {
                    Label("No Entries", systemImage: "doc.text")
                } description: {
                    Text("Nothing has been recorded. Turn on detailed technical logging and ZynSign will record what it does here.")
                }
            } else {
                ForEach(entries) { entry in
                    HStack(alignment: .firstTextBaseline, spacing: ZSpacing.sm) {
                        Image(systemName: "circle.fill")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.detail)
                                .font(.footnote.monospaced())
                            Text("\(entry.category.displayName) · \(entry.timestamp.formatted(date: .abbreviated, time: .standard))")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Technical Log")
        .navigationBarTitleDisplayMode(.inline)
        .task { entries = await settings.diagnosticEntries() }
    }
}

/// One exported file, handed to the system share sheet.
private struct SettingsShareItem: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

private struct SettingsShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

#Preview {
    NavigationStack {
        DiagnosticsPreferencesSection()
    }
    .environment(\.settingsCenter, SettingsCenterModel(
        store: FilePreferencesStore(location: ZynSignStorageLayout.preferencesDocument()),
        environment: CompositionRoot.makeApplicationEnvironment()
    ))
}
