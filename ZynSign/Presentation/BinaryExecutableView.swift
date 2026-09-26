import SwiftUI

/// The inspection page for one executable.
///
/// It shows, for the selected architecture: the architecture itself, links
/// to the load commands, library dependencies, and CodeDirectory, the code
/// signature as expandable cards, the hash and integrity panel, the signature
/// timeline, and the verification details — then offers comparison and a
/// read-only export. Structure appears as soon as it is known; verification
/// results replace their placeholders when hashing finishes. Search on this
/// page is scoped to this executable.
struct BinaryExecutableView: View {

    @ObservedObject var model: BinaryInspectorModel
    let target: BinaryTarget

    @State private var selectedArchitecture = 0
    @State private var searchText = ""
    @State private var showsExport = false
    @State private var showsComparison = false

    var body: some View {
        content
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .navigationTitle(target.name)
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: "Search this executable")
    }

    @ViewBuilder
    private var content: some View {
        switch model.state(for: target) {
        case .pending, .inspecting:
            VStack(spacing: ZSpacing.sm) {
                ProgressView()
                Text(model.state(for: target) == .pending ? "Waiting for earlier executables to finish…" : "Reading and parsing \(target.name)…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(ZSpacing.lg)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .combine)
        case .unavailable(let limitation):
            ContentUnavailableView {
                Label(limitation.title, systemImage: "exclamationmark.triangle")
            } description: {
                Text(limitation.explanation)
            }
        case .structureReady(let report), .completed(let report):
            if searchText.trimmingCharacters(in: .whitespaces).isEmpty {
                page(report)
            } else {
                scopedSearch(report)
            }
        }
    }

    // MARK: - Page

    private func page(_ report: BinaryInspectionReport) -> some View {
        let architecture = report.architecture(at: selectedArchitecture) ?? report.architectures.first
        let integrity = report.integrity
        let sliceIntegrity = architecture.flatMap { selected in
            integrity?.architectures.first { $0.architectureIndex == selected.index }
        }
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: ZSpacing.md) {
                BinaryExecutableHeader(report: report)

                if report.architectures.count > 1 {
                    Picker("Architecture", selection: $selectedArchitecture) {
                        ForEach(report.architectures) { item in
                            Text(item.name).tag(item.index)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityLabel("Architecture")
                    .accessibilityHint("Chooses which architecture's details the page shows.")
                }

                if let architecture {
                    BinarySectionHeading(
                        title: "Architecture Inspector",
                        systemImage: "cpu",
                        subtitle: report.container.displayName
                    )
                    ArchitectureInspectorCard(report: report, architecture: architecture)

                    BinarySectionHeading(title: "Structure", systemImage: "list.bullet.indent")
                    NavigationLink {
                        LoadCommandExplorerView(architecture: architecture)
                    } label: {
                        BinaryNavigationRow(
                            title: "Load Command Explorer",
                            subtitle: "Every command, grouped as Executable, Libraries, Security, Metadata, and Linking.",
                            systemImage: "list.bullet.rectangle",
                            value: architecture.loadCommands.count.formatted()
                        )
                    }
                    .buttonStyle(.plain)
                    NavigationLink {
                        LibraryDependencyView(model: model, report: report, architecture: architecture)
                    } label: {
                        BinaryNavigationRow(
                            title: "Library Dependencies",
                            subtitle: "The libraries and frameworks this executable loads, as a tree.",
                            systemImage: "point.3.connected.trianglepath.dotted",
                            value: architecture.libraries.count.formatted()
                        )
                    }
                    .buttonStyle(.plain)

                    BinarySectionHeading(
                        title: "Code Signature Inspector",
                        systemImage: "signature",
                        subtitle: "Each part of the signature, explained. Expand a card for its details."
                    )
                    CodeSignatureInspectorSection(
                        architecture: architecture,
                        integrity: sliceIntegrity
                    )

                    BinarySectionHeading(title: "Hash & Integrity", systemImage: "number.square")
                    HashIntegrityPanel(
                        report: report,
                        architecture: architecture,
                        sliceIntegrity: sliceIntegrity,
                        verificationFraction: model.verificationFraction[target.id],
                        sealedState: model.sealedResourceState(for: target),
                        canVerifySealedFiles: target.containerPath != nil,
                        verifySealedFiles: { Task { await model.verifySealedResources(for: target) } }
                    )
                }

                BinarySectionHeading(title: "Signature Timeline", systemImage: "timeline.selection")
                SignatureTimelineView(steps: BinarySignatureTimeline.steps(for: report))

                BinarySectionHeading(
                    title: "Verification Details",
                    systemImage: "checklist",
                    subtitle: "What ZynSign checked on this device, and why anything could not be checked."
                )
                VerificationDetailsView(
                    report: report,
                    nestedSignatures: target.kind == .mainExecutable ? model.nestedSignaturesCheck : nil
                )

                BinarySectionHeading(title: "Actions", systemImage: "ellipsis.circle")
                actions(report)

                BinaryScopeNote()
            }
            .padding(.horizontal, ZSpacing.md)
            .padding(.top, ZSpacing.md)
            .padding(.bottom, ZSpacing.xl)
        }
        .sheet(isPresented: $showsExport) {
            BinaryExportSheet(model: model, reports: [report], scopeTitle: target.name)
        }
        .sheet(isPresented: $showsComparison) {
            NavigationStack {
                BinaryComparisonView(
                    inspection: model.inspection,
                    source: model.source,
                    before: report,
                    beforeTitle: model.applicationName,
                    bundleIdentifier: model.bundleIdentifier
                )
            }
        }
    }

    private func actions(_ report: BinaryInspectionReport) -> some View {
        VStack(spacing: ZSpacing.sm) {
            Button {
                showsComparison = true
            } label: {
                Label("Compare With Another Package…", systemImage: "arrow.left.arrow.right")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.bordered)
            .accessibilityHint("Compares this executable with the same executable in another imported or signed package.")

            Button {
                showsExport = true
            } label: {
                Label("Export Inspection Report…", systemImage: "square.and.arrow.up")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .disabled(report.integrity == nil)
            .accessibilityHint(report.integrity == nil
                ? "Available when verification finishes."
                : "Creates a read-only report without certificates, keys, or entitlement values.")
        }
    }

    // MARK: - Scoped search

    private func scopedSearch(_ report: BinaryInspectionReport) -> some View {
        let results = model.searchIndex(for: report).search(searchText)
        return Group {
            if results.isEmpty {
                ContentUnavailableView.search(text: searchText)
            } else {
                List {
                    ForEach(BinarySearchEntry.Scope.allCases, id: \.self) { scope in
                        let scoped = results.filter { $0.scope == scope }
                        if !scoped.isEmpty {
                            Section(scope.displayName) {
                                ForEach(scoped) { entry in
                                    Button {
                                        open(entry, in: report)
                                    } label: {
                                        BinarySearchResultRow(entry: entry)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
    }

    /// Shows the architecture a result belongs to and returns to the page.
    private func open(_ entry: BinarySearchEntry, in report: BinaryInspectionReport) {
        let index: Int
        switch entry.destination {
        case .architecture(let value), .section(let value), .signature(let value), .codeDirectory(let value):
            index = value
        case .loadCommand(let value, _), .library(let value, _):
            index = value
        }
        if report.architecture(at: index) != nil {
            selectedArchitecture = index
        }
        searchText = ""
    }
}

// MARK: - Header

/// The executable's identity, verdict, and health summary.
struct BinaryExecutableHeader: View {
    let report: BinaryInspectionReport

    var body: some View {
        let health = BinaryHealthEvaluator.evaluate(report)
        return ZCard(variant: .material, cornerRadius: ZRadius.lg) {
            VStack(alignment: .leading, spacing: ZSpacing.sm) {
                HStack(alignment: .top, spacing: ZSpacing.sm) {
                    Image(systemName: report.target.kind.systemImage)
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 44, height: 44)
                        .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: ZRadius.icon, style: .continuous))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(report.target.name)
                            .font(.title3.weight(.bold))
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityAddTraits(.isHeader)
                        Text(report.target.kind.displayName)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text(report.target.executablePath.rawValue)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    BinaryStatusBadge(presentation: BinaryStatusPresentation(report.verdict), subject: "Verification")
                }

                Text(report.verdict.explanation)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Divider()

                Label(health.headline, systemImage: "stethoscope")
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(health.findings) { finding in
                    HStack(alignment: .top, spacing: ZSpacing.sm) {
                        BinaryStatusBadge(presentation: BinaryStatusPresentation(finding.severity))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(finding.title)
                                .font(.subheadline.weight(.semibold))
                            Text(finding.detail)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(finding.severity.displayName): \(finding.title). \(finding.detail)")
                }
            }
        }
    }
}
