import SwiftUI

/// Exports a read-only inspection report through the share sheet.
///
/// The report is rendered when the sheet appears and whenever the format
/// changes, written to the temporary export directory, and handed to the
/// system share sheet only when the user chooses to share it. The sheet
/// states what the report contains and what it deliberately leaves out.
struct BinaryExportSheet: View {

    @ObservedObject var model: BinaryInspectorModel
    let reports: [BinaryInspectionReport]
    let scopeTitle: String

    @State private var format: BinaryInspectionExportFormat = .text
    @State private var fileURL: URL?
    @State private var failure: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    BinaryFieldRow(label: "Scope", value: scopeTitle)
                    BinaryFieldRow(label: "Executables", value: reports.count.formatted())
                    Picker("Format", selection: $format) {
                        ForEach(BinaryInspectionExportFormat.allCases) { item in
                            Text(item.displayName).tag(item)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityLabel("Report format")
                } header: {
                    Text("Report")
                } footer: {
                    Text("Text is easy to read and paste into a ticket. JSON is structured for tools.")
                }

                Section("Includes") {
                    Label("Executable summary and health", systemImage: "doc.text")
                    Label("Architectures", systemImage: "cpu")
                    Label("Signature summary and entitlement names", systemImage: "signature")
                    Label("Verification results", systemImage: "checklist")
                    Label("Timestamps", systemImage: "clock")
                }

                Section("Never Included") {
                    Text(BinaryInspectionReportRenderer.exclusionStatement)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section {
                    if reports.isEmpty {
                        Text("No executable has finished verification yet, so there is nothing to export.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else if let fileURL {
                        ShareLink(item: fileURL) {
                            Label("Share Report", systemImage: "square.and.arrow.up")
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .accessibilityHint("Opens the share sheet with the read-only report.")
                    } else if let failure {
                        Text(failure)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        ProgressView()
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Export Report")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear { prepare() }
            .onChange(of: format) { _, _ in prepare() }
        }
    }

    private func prepare() {
        guard !reports.isEmpty else { return }
        do {
            fileURL = try model.exportFile(for: reports, format: format)
            failure = nil
        } catch {
            fileURL = nil
            failure = "The report could not be written. Nothing was shared."
        }
    }
}
