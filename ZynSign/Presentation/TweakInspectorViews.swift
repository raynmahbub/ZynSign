import SwiftUI

/// Sheet displaying Mach-O architecture slices, `LC_LOAD_DYLIB` dependencies,
/// detected hooking framework (`CydiaSubstrate` / `ElleKit` / `libhooker`),
/// Debian `.deb` `control` metadata, and recommended injection settings.
struct TweakMachOAnalyzerSheet: View {
    let tweak: TweakDescriptor
    let service: TweakLibraryService
    @Environment(\.dismiss) private var dismiss

    @State private var report: TweakMachOAnalyzer.AnalysisReport?
    @State private var debInfo: DebArchiveParser.UnpackedDeb?
    @State private var loadError: String?

    var body: some View {
        NavigationStack {
            List {
                Section("Tweak Summary") {
                    LabeledContent("Name", value: tweak.name)
                    LabeledContent("File", value: tweak.fileName)
                    LabeledContent("Type", value: tweak.kind.displayName)
                    LabeledContent("Size", value: StorageGaugeReading.humanReadable(tweak.byteSize))
                }

                if let deb = debInfo {
                    Section("Debian Package (.deb) Metadata") {
                        if let pkg = deb.control.packageIdentifier { LabeledContent("Package", value: pkg) }
                        if let ver = deb.control.version { LabeledContent("Version", value: ver) }
                        if let auth = deb.control.author ?? deb.control.maintainer { LabeledContent("Author", value: auth) }
                        if let arch = deb.control.architecture { LabeledContent("Architecture", value: arch) }
                        if let dep = deb.control.depends { LabeledContent("Depends", value: dep) }
                        if let desc = deb.control.summary {
                            Text(desc).font(ZTypography.caption).foregroundStyle(.secondary)
                        }
                        LabeledContent("Embedded Payloads", value: "\(deb.payloads.count)")
                    }
                }

                if let report, report.isValidMachO {
                    Section("Mach-O Slices & Runtime") {
                        LabeledContent("Hooking Runtime", value: report.hookingRuntime.rawValue)
                        ForEach(report.slices) { slice in
                            HStack {
                                Text(slice.architecture).font(ZTypography.codeCaption)
                                Spacer()
                                if slice.hasLegacyArm64eSubtype {
                                    ZStatusBadge("Legacy arm64e", systemImage: "exclamationmark.triangle", kind: .warning)
                                } else {
                                    ZStatusBadge("OK", systemImage: "checkmark.circle", kind: .success)
                                }
                            }
                        }
                    }

                    Section("Recommended Injection Settings") {
                        LabeledContent("Inject Base", value: report.recommendation.injectBase.title)
                        LabeledContent("Inject Folder", value: report.recommendation.injectFolder.title)
                        LabeledContent("ElleKit @rpath Rewrite", value: report.recommendation.replaceSubstrateWithElleKit ? "Recommended" : "Not Needed")
                        LabeledContent("Fix Legacy arm64e", value: report.recommendation.fixLegacyArm64eSlice ? "Recommended" : "Not Needed")
                        Text(report.recommendation.rationale)
                            .font(ZTypography.caption)
                            .foregroundStyle(.secondary)
                    }

                    Section("Linked Libraries (\(report.linkedLibraries.count))") {
                        ForEach(report.linkedLibraries, id: \.self) { dep in
                            Text(dep)
                                .font(ZTypography.codeCaption)
                                .textSelection(.enabled)
                        }
                    }
                } else if let loadError {
                    Section {
                        Text(loadError).font(ZTypography.caption).foregroundStyle(.orange)
                    }
                }
            }
            .navigationTitle("Analyze Tweak")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { analyzePayload() }
        }
    }

    private func analyzePayload() {
        guard let bytes = try? service.payload(for: tweak.id) else {
            loadError = "Payload bytes could not be loaded."
            return
        }
        if tweak.kind == .debPackage {
            do {
                let unpacked = try DebArchiveReader.unpack(bytes)
                debInfo = unpacked
                if let firstDylib = unpacked.payloads.first(where: { $0.kind == .dylib }) {
                    report = TweakMachOAnalyzer.analyze(firstDylib.bytes)
                }
            } catch let err as DebArchiveParser.DebError {
                loadError = err.message
            } catch {
                loadError = error.localizedDescription
            }
        } else {
            report = TweakMachOAnalyzer.analyze(bytes)
        }
    }
}

/// Sheet configuring per-tweak Auto-Inject rules (All Apps, Bundle ID patterns, Exclusions).
struct TweakAutoInjectRuleSheet: View {
    let tweak: TweakDescriptor
    let ruleStore: any TweakAutoInjectRuleStore
    @Environment(\.dismiss) private var dismiss

    @State private var scope: TweakAutoInjectRule.Scope = .disabled
    @State private var targetPatterns: [String] = []
    @State private var excludedPatterns: [String] = []
    @State private var newTarget = ""
    @State private var newExcluded = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Auto-Inject Mode", selection: $scope) {
                        ForEach(TweakAutoInjectRule.Scope.allCases, id: \.self) { item in
                            Text(item.title).tag(item)
                        }
                    }
                } header: {
                    Text(tweak.name)
                } footer: {
                    Text("Matching tweaks are pre-selected automatically when you open Signing for a compatible app.")
                }

                if scope == .matchingBundleIDs {
                    Section("Target Bundle IDs (Exact or com.example.*)") {
                        HStack(spacing: ZSpacing.sm) {
                            TextField("com.google.ios.youtube", text: $newTarget)
                                .font(ZTypography.codeCaption)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                            Button("Add") {
                                let clean = newTarget.trimmingCharacters(in: .whitespacesAndNewlines)
                                if !clean.isEmpty, !targetPatterns.contains(clean) {
                                    targetPatterns.append(clean)
                                    newTarget = ""
                                }
                            }
                            .frame(minHeight: 44)
                        }
                        ForEach(targetPatterns, id: \.self) { pattern in
                            HStack {
                                Text(pattern).font(ZTypography.codeCaption)
                                Spacer()
                                Button(role: .destructive) {
                                    targetPatterns.removeAll { $0 == pattern }
                                } label: {
                                    Image(systemName: "minus.circle.fill").frame(width: 44, height: 44)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }

                if scope != .disabled {
                    Section("Excluded Bundle IDs") {
                        HStack(spacing: ZSpacing.sm) {
                            TextField("com.apple.*", text: $newExcluded)
                                .font(ZTypography.codeCaption)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                            Button("Exclude") {
                                let clean = newExcluded.trimmingCharacters(in: .whitespacesAndNewlines)
                                if !clean.isEmpty, !excludedPatterns.contains(clean) {
                                    excludedPatterns.append(clean)
                                    newExcluded = ""
                                }
                            }
                            .frame(minHeight: 44)
                        }
                        ForEach(excludedPatterns, id: \.self) { pattern in
                            HStack {
                                Text(pattern).font(ZTypography.codeCaption)
                                Spacer()
                                Button(role: .destructive) {
                                    excludedPatterns.removeAll { $0 == pattern }
                                } label: {
                                    Image(systemName: "minus.circle.fill").frame(width: 44, height: 44)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Auto-Inject Rule")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let rule = TweakAutoInjectRule(
                            tweakID: tweak.id,
                            scope: scope,
                            targetBundleIdentifiers: targetPatterns,
                            excludedBundleIdentifiers: excludedPatterns
                        )
                        try? ruleStore.saveRule(rule)
                        dismiss()
                    }
                }
            }
            .task {
                if let existing = (try? ruleStore.allRules())?.first(where: { $0.id == tweak.id }) {
                    scope = existing.scope
                    targetPatterns = existing.targetBundleIdentifiers
                    excludedPatterns = existing.excludedBundleIdentifiers
                }
            }
        }
    }
}

/// Sheet scanning imported Library `.ipa` packages for embedded `.dylib`,
/// `.framework`, `.bundle`, and `.appex` items to extract into the Tweak Library.
struct IPATweakExtractorSheet: View {
    let service: TweakLibraryService
    let onExtracted: () -> Void
    @Environment(\.applicationEnvironment) private var env
    @Environment(\.dismiss) private var dismiss

    @State private var entries: [LibraryEntry] = []
    @State private var selectedEntryID: ApplicationRecordIdentifier?
    @State private var candidates: [IPATweakExtractor.Candidate] = []
    @State private var statusMessage: String?

    private let extractor = IPATweakExtractor()

    var body: some View {
        NavigationStack {
            List {
                Section("Select Library Application") {
                    if entries.isEmpty {
                        Text("Import an application into Library first to extract embedded tweaks or frameworks.")
                            .font(ZTypography.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("Application", selection: $selectedEntryID) {
                            Text("Choose Application…").tag(nil as ApplicationRecordIdentifier?)
                            ForEach(entries, id: \.record.id) { item in
                                Text(item.record.displayName ?? item.record.bundleIdentifier.rawValue)
                                    .tag(Optional(item.record.id))
                            }
                        }
                    }
                }

                if let statusMessage {
                    Section {
                        Text(statusMessage).font(ZTypography.caption).foregroundStyle(.secondary)
                    }
                }

                if selectedEntryID != nil {
                    Section("Discoverable Tweaks & Bundles (\(candidates.count))") {
                        if candidates.isEmpty {
                            Text("No embedded .dylib, .framework, .bundle, or .appex items found in this package.")
                                .font(ZTypography.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(candidates) { item in
                                HStack(spacing: ZSpacing.sm) {
                                    Image(systemName: item.kind.symbolName)
                                        .foregroundStyle(Color.accentColor)
                                    VStack(alignment: .leading, spacing: ZSpacing.xxs) {
                                        Text(item.name).font(ZTypography.subheadline)
                                        Text("\(item.kind.displayName) · \(StorageGaugeReading.humanReadable(item.byteSize))")
                                            .font(ZTypography.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Button("Extract") {
                                        extractCandidate(item)
                                    }
                                    .buttonStyle(.bordered)
                                    .frame(minHeight: 44)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Extract from IPA")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                entries = ((try? await env.library.entries()) ?? []).filter(\.isArtifactAvailable)
                if selectedEntryID == nil {
                    selectedEntryID = entries.first?.record.id
                }
            }
            .onChange(of: selectedEntryID) { _, _ in
                scanSelectedEntry()
            }
        }
    }

    private func scanSelectedEntry() {
        statusMessage = nil
        guard let id = selectedEntryID,
              let chosen = entries.first(where: { $0.record.id == id }) else {
            candidates = []
            return
        }
        let url = env.artifactFileURL(for: chosen.record.artifact.artifactID)
        candidates = (try? extractor.discoverExtractableItems(in: url)) ?? []
    }

    private func extractCandidate(_ item: IPATweakExtractor.Candidate) {
        guard let id = selectedEntryID,
              let chosen = entries.first(where: { $0.record.id == id }) else { return }
        let url = env.artifactFileURL(for: chosen.record.artifact.artifactID)
        let groupName = chosen.record.displayName ?? "Extracted"
        do {
            switch try extractor.extract(item, from: url, into: service, group: groupName) {
            case .success(let outcome):
                ZHaptics.success()
                statusMessage = "Extracted “\(outcome.descriptor.name)” into Tweak Library."
                onExtracted()
            case .failure(let refusal):
                statusMessage = refusal.message
            }
        } catch {
            statusMessage = error.localizedDescription
        }
    }
}
