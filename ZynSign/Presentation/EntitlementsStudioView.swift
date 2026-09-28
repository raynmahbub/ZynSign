import SwiftUI
import UniformTypeIdentifiers

struct EntitlementStatusLabel: View {
    let status: EntitlementStudioStatus
    @Environment(\.preferredColorSchemeContrast) private var contrast
    var body: some View {
        Label(status.rawValue, systemImage: status.symbol)
            .font(.subheadline.weight(.semibold))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(color)
            .accessibilityLabel("Status: \(status.rawValue)")
    }
    private var color: Color {
        if contrast == .increased { return .primary }
        switch status {
        case .compatible: return .green
        case .warning: return .primary // Text stays legible at increased contrast.
        case .blocked: return .red
        case .unknown: return .secondary
        }
    }
}

@MainActor
struct EntitlementsStudioView: View {
    let entry: LibraryEntry
    @ObservedObject var studio: EntitlementsStudioModel
    @Environment(\.applicationEnvironment) private var env
    @State private var query = ""
    @State private var filter: EntitlementStudioStatus?
    @State private var comparison = false
    @State private var showProfileImporter = false
    @State private var inputError: String?
    @State private var exportDocument = EntitlementReportDocument(data: Data())
    @State private var showExporter = false
    @State private var exporting = false
    @State private var exportError: String?

    var body: some View {
        List {
            Section {
                Text("Entitlements Studio").font(.title2.bold()).accessibilityAddTraits(.isHeader)
                Text("Read-only insight into what this app requests and what your selected profile declares.")
                Text("Local checks only — not a prediction of installation, trust or platform acceptance.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            configurationSection
            if studio.isLoading { Section { ProgressView("Reading app entitlements…") } }
            if let error = studio.inspectionError {
                Section("Inspection unavailable") {
                    Text(error)
                    Button("Retry Inspection") { Task { await studio.retry(entry: entry, inspection: env.bundleInspection) } }
                        .frame(minHeight: 44)
                }
            }
            if let analysis = studio.analysis {
                dashboard(analysis)
                Section("Profile Compatibility") {
                    ForEach(analysis.checks) { finding in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(finding.title).font(.headline)
                            EntitlementStatusLabel(status: finding.status)
                            Text(finding.message).font(.footnote).foregroundStyle(.secondary)
                        }.padding(.vertical, 4)
                    }
                    NavigationLink { EntitlementDiagnosticsView(studio: studio) } label: {
                        Label("Smart Diagnostics", systemImage: "stethoscope")
                    }.frame(minHeight: 44)
                }
                entitlementSections(analysis)
                Section("Export") {
                    Button {
                        export(analysis)
                    } label: {
                        Label(exporting ? "Preparing Report…" : "Export Read-Only Report…", systemImage: "square.and.arrow.up")
                    }.frame(minHeight: 44).disabled(exporting)
                    Text("Exports this architecture's complete list, not just search results, plus checks and a timestamp. Unknown-key values and binary contents are omitted for privacy. Reports can still contain app identifiers; share thoughtfully.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            } else if !studio.isLoading { Section { ProgressView("Updating compatibility…") } }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Entitlements")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "Name, raw key, capability or status")
        .task {
            do { studio.identities = try env.identityStore.listIdentities() }
            catch { inputError = "Certificates could not be read. Open Certificates to check secure storage." }
            await studio.load(entry: entry, inspection: env.bundleInspection)
        }
        .fileImporter(isPresented: $showProfileImporter, allowedContentTypes: [.data, .item], allowsMultipleSelection: false, onCompletion: importProfile)
        .fileExporter(isPresented: $showExporter, document: exportDocument, contentType: .json, defaultFilename: "ZynSign-Entitlements-Report") { result in
            if case .failure = result { exportError = "The report could not be saved. Choose a writable location and try again." }
        }
        .alert("Report Export", isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })) {
            Button("OK", role: .cancel) { exportError = nil }
        } message: { Text(exportError ?? "") }
    }

    private var configurationSection: some View {
        Section("Comparison Context") {
            Picker("Certificate", selection: $studio.selectedIdentityID) {
                Text("Not selected").tag(nil as SigningIdentityIdentifier?)
                ForEach(studio.identities, id: \.id) { identity in
                    Text(identity.displayName).tag(Optional(identity.id))
                }
            }.pickerStyle(.navigationLink)
            LabeledContent("Profile", value: studio.profileFileName ?? "Not selected")
            Button("Choose Provisioning Profile…") { showProfileImporter = true }.frame(minHeight: 44)
            if studio.profileData != nil {
                Button("Remove Profile", role: .destructive) { studio.removeProfile() }.frame(minHeight: 44)
            }
            if studio.isParsingProfile { ProgressView("Parsing profile…") }
            if let error = studio.profileError ?? inputError { Text(error).font(.footnote).foregroundStyle(.red) }
            Toggle("Emit DER when signing", isOn: $studio.emitDEREntitlements)
            if studio.targets.count > 1 {
                Picker("Main executable architecture", selection: $studio.selectedTargetID) {
                    ForEach(studio.targets) { target in Text(target.name).tag(target.id) }
                }
            }
            Text("Certificate, profile and DER selections are shared with Sign Application in this App Details session. Changing them automatically replaces the analysis. No entitlement values are changed.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private func dashboard(_ analysis: EntitlementStudioAnalysis) -> some View {
        Section("Dashboard • \(studio.target?.name ?? "Main executable")") {
            EntitlementStatusLabel(status: analysis.status)
            Text(analysis.summary).font(.headline)
            if studio.signingBlocked && analysis.status != .blocked {
                Label("Another architecture has blocking mismatches. Signing is blocked; inspect each architecture.", systemImage: "xmark.octagon.fill")
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), alignment: .leading)], alignment: .leading, spacing: 16) {
                metric("Total entitlements", analysis.rows.count)
                metric("Supported matches", analysis.count(.compatible))
                metric("Warnings", analysis.count(.warning))
                metric("Blocking mismatches", analysis.count(.blocked))
                metric("Unknown", analysis.count(.unknown))
            }.padding(.vertical, 8)
            Text("Counts describe entitlement cards. Overall status also includes context checks below. Compatible: no detected conflict in that check. Attention: review recommended. Blocked: signing should not proceed.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private func metric(_ label: String, _ count: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(count.formatted()).font(.title2.bold()).monospacedDigit()
            Text(label).font(.caption)
        }.accessibilityElement(children: .ignore).accessibilityLabel("\(label): \(count)")
    }

    @ViewBuilder
    private func entitlementSections(_ analysis: EntitlementStudioAnalysis) -> some View {
        let rows = analysis.filtered(query: query, status: filter)
        let groups = Dictionary(grouping: rows, by: { $0.capability.category })
        Section("Entitlement List") {
            Picker("Status filter", selection: $filter) {
                Text("All statuses").tag(nil as EntitlementStudioStatus?)
                ForEach(EntitlementStudioStatus.allCases, id: \.self) { status in
                    Text(status.rawValue).tag(Optional(status))
                }
            }
            Toggle("Side-by-side comparison", isOn: $comparison)
            Text("\(rows.count) of \(analysis.rows.count) entitlements").font(.caption).foregroundStyle(.secondary)
            if rows.isEmpty {
                Text(analysis.rows.isEmpty ? "No decoded entitlement cards are available. See Inspection scope above; missing data is not evidence of compatibility." : "No matching entitlements. Try another search or status filter.")
                    .foregroundStyle(.secondary)
            }
        }
        ForEach(groups.keys.sorted(), id: \.self) { category in
            Section(category) {
                ForEach(groups[category] ?? []) { row in
                    VStack(alignment: .leading, spacing: 10) {
                        NavigationLink {
                            EntitlementInspectorView(key: row.key, studio: studio)
                        } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(row.capability.name).font(.headline)
                                Text(row.key).font(.caption.monospaced()).foregroundStyle(.secondary)
                            }.fixedSize(horizontal: false, vertical: true)
                        }.frame(minHeight: 44)
                        EntitlementStatusLabel(status: row.finding.status)
                        if comparison { EntitlementComparisonValues(row: row) }
                        else { Text(EntitlementStudioValue.summary(row.value)).font(.body.monospaced()).lineLimit(3) }
                        DisclosureGroup("Technical details") {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(row.capability.explanation)
                                Text("Type: \(EntitlementStudioValue.typeName(row.value))")
                                Text(row.finding.message)
                            }.font(.footnote).padding(.vertical, 8)
                        }.frame(minHeight: 44)
                    }.padding(.vertical, 8)
                }
            }
        }
    }

    private func importProfile(_ result: Result<[URL], any Error>) {
        guard case .success(let urls) = result, let url = urls.first else { return }
        inputError = nil
        studio.selectProfileFile(url)
    }

    private func export(_ analysis: EntitlementStudioAnalysis) {
        exporting = true
        let name = entry.record.displayName ?? "Unnamed Application"
        let bundleID = entry.record.bundleIdentifier.rawValue
        let target = studio.target?.name ?? "Unavailable"
        Task {
            let data = await Task.detached(priority: .userInitiated) {
                try? EntitlementsStudioReport(name: name, bundleID: bundleID, target: target, analysis: analysis).data()
            }.value
            exporting = false
            guard let data else { exportError = "The report could not be prepared."; return }
            exportDocument = EntitlementReportDocument(data: data)
            showExporter = true
        }
    }
}

/// Two columns normally; stacked at accessibility sizes, with explicit labels
/// in both layouts so differences never depend on color or spatial position.
private struct EntitlementComparisonValues: View {
    let row: EntitlementStudioRow
    var fullValues = false
    @Environment(\.dynamicTypeSize) private var typeSize
    var body: some View {
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12)) : AnyLayout(HStackLayout(alignment: .top, spacing: 16))
        layout {
            column("App", value: row.value)
            column("Profile", value: row.profileValue)
        }
        if row.profileValue != row.value {
            Label("Values differ or profile value is unavailable", systemImage: "not.equal")
                .font(.caption)
        }
    }
    private func column(_ label: String, value: ProvisioningProfileValue?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.subheadline.bold())
            Text(value.map { fullValues ? EntitlementStudioValue.raw($0) : EntitlementStudioValue.preview($0) } ?? "Not declared / unavailable")
                .font(.caption.monospaced()).textSelection(.enabled)
        }.frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
    }
}

private struct EntitlementInspectorView: View {
    let key: String
    @ObservedObject var studio: EntitlementsStudioModel
    var body: some View {
        List {
            if let row = studio.analysis?.rows.first(where: { $0.key == key }) {
                Section("Overview") {
                    Text(row.capability.name).font(.title2.bold())
                    Text(row.key).font(.body.monospaced()).textSelection(.enabled)
                    Text(row.capability.explanation)
                    Text(EntitlementStudioValue.raw(row.value)).font(.body.monospaced()).textSelection(.enabled)
                }
                Section("Compatibility") {
                    EntitlementStatusLabel(status: row.finding.status)
                    Text(row.finding.message)
                    LabeledContent("Profile support", value: row.profileValue == nil ? "Not declared / unavailable" : "Declared; comparison below")
                    Text(studio.analysis?.teamRelationship ?? "Team relationship not evaluated")
                    EntitlementComparisonValues(row: row, fullValues: true)
                }
                Section("Technical") {
                    LabeledContent("Value type", value: EntitlementStudioValue.typeName(row.value))
                    LabeledContent("Related capability", value: row.capability.category)
                    Text("Raw representation (typed, binary bytes omitted)").font(.headline)
                    Text(EntitlementStudioValue.raw(row.value)).font(.caption.monospaced()).textSelection(.enabled)
                }
                Section { Text("Read only. The Studio never strips, adds or rewrites entitlement claims.").foregroundStyle(.secondary) }
            } else {
                Text("This claim is unavailable in the current analysis. Compatibility updates automatically when the selection changes.")
            }
        }.navigationTitle("Entitlement Inspector").navigationBarTitleDisplayMode(.inline)
    }
}

struct EntitlementDiagnosticsView: View {
    @ObservedObject var studio: EntitlementsStudioModel
    var body: some View {
        List {
            Section {
                Text("Actionable findings from the same analysis used by Entitlements Studio and the signing preflight. These messages contain no entitlement values and are not written to the activity journal.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if let analysis = studio.analysis {
                ForEach(analysis.findings) { finding in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(finding.title).font(.headline)
                        EntitlementStatusLabel(status: finding.status)
                        Text(finding.message)
                        if let category = finding.diagnosticCategory {
                            Text(category.rawValue).font(.caption).foregroundStyle(.secondary)
                        }
                    }.padding(.vertical, 4)
                }
            } else { ProgressView("Updating diagnostics…") }
        }.navigationTitle("Smart Diagnostics").navigationBarTitleDisplayMode(.inline)
    }
}

private struct EntitlementReportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    let data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}
