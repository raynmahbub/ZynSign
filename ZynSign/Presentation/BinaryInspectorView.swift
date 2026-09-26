import SwiftUI

/// The Binary & Signature Inspector: a read-only, developer-grade workspace
/// for the executables inside one application bundle.
///
/// The dashboard shows one card per executable — the main executable first,
/// then frameworks, libraries, and extensions — each filling in as the
/// inspection use case establishes its structure and then its verification.
/// Search spans every inspected executable. Nothing here signs, changes, or
/// exports the package; the only file written is an inspection report the
/// user explicitly asks to share.
struct BinaryInspectorView: View {

    @StateObject private var model: BinaryInspectorModel
    @State private var showsExport = false

    /// Creates the inspector for a library entry.
    init(inspection: IPABinaryInspection, entry: LibraryEntry, generator: String) {
        _model = StateObject(wrappedValue: BinaryInspectorModel(
            inspection: inspection,
            source: .libraryRecord(entry.record.id),
            applicationName: entry.record.displayName ?? entry.record.bundleIdentifier.rawValue,
            bundleIdentifier: entry.record.bundleIdentifier.rawValue,
            generator: generator
        ))
    }

    var body: some View {
        content
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .navigationTitle("Binary Inspector")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(
                text: $model.searchText,
                prompt: "Load commands, libraries, sections, signature"
            )
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showsExport = true
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .disabled(model.completedReports.isEmpty)
                    .accessibilityLabel("Export Inspection Report")
                    .accessibilityHint("Creates a read-only report of every executable that has finished verification.")
                }
            }
            .sheet(isPresented: $showsExport) {
                BinaryExportSheet(model: model, reports: model.completedReports, scopeTitle: "All inspected executables")
            }
            .task { await model.load() }
            .refreshable { await model.reload() }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading:
            BinaryInspectorLoadingView()
        case .failed(let message):
            ContentUnavailableView {
                Label("Inspection Unavailable", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") { Task { await model.reload() } }
                    .buttonStyle(.borderedProminent)
            }
        case .loaded:
            if model.searchText.trimmingCharacters(in: .whitespaces).isEmpty {
                dashboard
            } else {
                BinarySearchResultsView(model: model, query: model.searchText)
            }
        }
    }

    private var dashboard: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: ZSpacing.md) {
                header
                BinarySectionHeading(
                    title: "Binary Overview",
                    systemImage: "square.grid.2x2",
                    subtitle: "One card per executable. Tap a card for its architectures, load commands, libraries, and signature."
                )
                ForEach(model.targets) { target in
                    NavigationLink {
                        BinaryExecutableView(model: model, target: target)
                    } label: {
                        BinaryOverviewCard(content: BinaryOverviewCardContent(
                            target: target,
                            progress: model.state(for: target),
                            verificationFraction: model.verificationFraction[target.id]
                        ))
                    }
                    .buttonStyle(.plain)
                }
                if let omitted = model.overview?.omittedTargetCount, omitted > 0 {
                    Text("\(omitted) more nested executable(s) are beyond the per-pass inspection bound. They remain visible in the bundle explorer.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                BinaryScopeNote()
            }
            .padding(.horizontal, ZSpacing.md)
            .padding(.top, ZSpacing.md)
            .padding(.bottom, ZSpacing.xl)
        }
    }

    private var header: some View {
        let total = model.targets.count
        let finished = model.finishedCount
        let nested = model.nestedSignaturesCheck
        return ZCard(variant: .material, cornerRadius: ZRadius.lg) {
            VStack(alignment: .leading, spacing: ZSpacing.sm) {
                HStack(alignment: .center, spacing: ZSpacing.sm) {
                    Image(systemName: "cpu")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 44, height: 44)
                        .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: ZRadius.icon, style: .continuous))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.applicationName)
                            .font(.title3.weight(.bold))
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityAddTraits(.isHeader)
                        Text(total == 1 ? "1 executable" : "\(total) executables")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                if total > 0 {
                    ProgressView(value: Double(finished), total: Double(max(total, 1))) {
                        Text(finished == total ? "Inspection complete" : "Inspecting \(finished) of \(total)")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityValue(finished == total ? "Complete" : "\(finished) of \(total) executables finished")
                }
                HStack(spacing: ZSpacing.xs) {
                    Text("Nested signatures")
                        .font(.subheadline.weight(.medium))
                    Spacer(minLength: ZSpacing.xs)
                    BinaryStatusBadge(presentation: BinaryStatusPresentation(nested.status), subject: "Nested signatures")
                }
                Text(nested.summary)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Overview card

/// The display values for one executable's dashboard card.
struct BinaryOverviewCardContent: Equatable {
    let title: String
    let subtitle: String
    let systemImage: String
    let architectureText: String
    let sizeText: String
    let signatureText: String
    let encryptionText: String
    /// The verdict, once structure is known.
    let verdict: BinaryVerificationVerdict?
    let healthHeadline: String
    /// A status line for states without a report.
    let statusText: String?
    let isWorking: Bool
    let verificationFraction: Double?
    let accessibilityLabel: String

    init(target: BinaryTarget, progress: BinaryTargetProgress, verificationFraction: Double?) {
        self.title = target.name
        var subtitle = target.kind.displayName
        if let container = target.containerName {
            subtitle += " · \(container)"
        }
        self.subtitle = subtitle
        self.systemImage = target.kind.systemImage
        let declaredSize = target.declaredByteCount.map(BinaryFormat.bytes) ?? "—"

        switch progress {
        case .structureReady(let report), .completed(let report):
            let health = BinaryHealthEvaluator.evaluate(report)
            self.architectureText = report.architectureSummary
            self.sizeText = BinaryFormat.bytes(report.fileSize)
            self.signatureText = report.signaturePresence.displayName
            self.encryptionText = report.encryptionState.displayName
            self.verdict = report.verdict
            self.healthHeadline = health.headline
            self.statusText = nil
            self.isWorking = report.integrity == nil
            self.verificationFraction = report.integrity == nil ? verificationFraction : nil
        case .pending:
            self.architectureText = "—"
            self.sizeText = declaredSize
            self.signatureText = "—"
            self.encryptionText = "—"
            self.verdict = nil
            self.healthHeadline = ""
            self.statusText = "Waiting to be inspected"
            self.isWorking = false
            self.verificationFraction = nil
        case .inspecting:
            self.architectureText = "—"
            self.sizeText = declaredSize
            self.signatureText = "—"
            self.encryptionText = "—"
            self.verdict = nil
            self.healthHeadline = ""
            self.statusText = "Reading and parsing…"
            self.isWorking = true
            self.verificationFraction = nil
        case .unavailable(let limitation):
            self.architectureText = "—"
            self.sizeText = declaredSize
            self.signatureText = "Not inspected"
            self.encryptionText = "Not inspected"
            self.verdict = nil
            self.healthHeadline = limitation.title
            self.statusText = limitation.explanation
            self.isWorking = false
            self.verificationFraction = nil
        }

        var spoken = "\(title), \(subtitle)."
        if let verdict {
            spoken += " Verification: \(verdict.displayName)."
            spoken += " Architecture: \(architectureText). File size: \(sizeText). Signature: \(signatureText). Encryption: \(encryptionText)."
            if !healthHeadline.isEmpty { spoken += " \(healthHeadline)." }
        } else if let statusText {
            spoken += " \(healthHeadline.isEmpty ? "" : healthHeadline + ". ")\(statusText)"
        }
        self.accessibilityLabel = spoken
    }
}

/// One executable's dashboard card.
struct BinaryOverviewCard: View {
    let content: BinaryOverviewCardContent
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var columns: [GridItem] {
        dynamicTypeSize.isAccessibilitySize
            ? [GridItem(.flexible())]
            : [GridItem(.flexible(), spacing: ZSpacing.sm), GridItem(.flexible(), spacing: ZSpacing.sm)]
    }

    var body: some View {
        ZCard {
            VStack(alignment: .leading, spacing: ZSpacing.sm) {
                HStack(alignment: .top, spacing: ZSpacing.sm) {
                    Image(systemName: content.systemImage)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 40, height: 40)
                        .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: ZRadius.sm, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(content.title)
                            .font(.headline)
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                            .truncationMode(.middle)
                        Text(content.subtitle)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: ZSpacing.xs)
                    if let verdict = content.verdict {
                        BinaryStatusBadge(presentation: BinaryStatusPresentation(verdict))
                    } else if content.isWorking {
                        ProgressView().controlSize(.small)
                    }
                }

                if content.verdict != nil {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: ZSpacing.xs) {
                        metric("Architecture", content.architectureText)
                        metric("File Size", content.sizeText)
                        metric("Signature", content.signatureText)
                        metric("Encryption", content.encryptionText)
                    }
                    if let fraction = content.verificationFraction {
                        ProgressView(value: fraction) {
                            Text("Verifying page hashes… \(BinaryFormat.percent(fraction))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if !content.healthHeadline.isEmpty {
                        Label(content.healthHeadline, systemImage: "stethoscope")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else if let status = content.statusText {
                    if !content.healthHeadline.isEmpty {
                        Text(content.healthHeadline)
                            .font(.subheadline.weight(.semibold))
                    }
                    Text(status)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .contentShape(RoundedRectangle(cornerRadius: ZRadius.card, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(content.accessibilityLabel)
        .accessibilityHint("Opens the executable's inspection page.")
        .accessibilityAddTraits(.isButton)
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Loading

/// Placeholder cards shown while the package is opened, so the layout does
/// not jump when the executables appear.
struct BinaryInspectorLoadingView: View {
    var body: some View {
        ScrollView {
            VStack(spacing: ZSpacing.md) {
                ForEach(0..<2, id: \.self) { _ in
                    ZSkeletonCard()
                }
                Text("Opening the package and finding its executables…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(ZSpacing.md)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Opening the package and finding its executables.")
    }
}

// MARK: - Search results

/// Search results across every inspected executable, updated on each
/// keystroke from in-memory indexes.
struct BinarySearchResultsView: View {
    @ObservedObject var model: BinaryInspectorModel
    let query: String

    var body: some View {
        let groups = model.searchResults(for: query)
        return Group {
            if groups.isEmpty {
                ContentUnavailableView.search(text: query)
            } else {
                List {
                    ForEach(groups) { group in
                        Section {
                            ForEach(group.entries) { entry in
                                NavigationLink {
                                    BinaryExecutableView(model: model, target: group.target)
                                } label: {
                                    BinarySearchResultRow(entry: entry)
                                }
                            }
                        } header: {
                            Text(group.target.name)
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
    }
}

/// One search result: what matched, and where.
struct BinarySearchResultRow: View {
    let entry: BinarySearchEntry

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: ZSpacing.sm) {
            Image(systemName: entry.scope.systemImage)
                .foregroundStyle(Color.accentColor)
                .frame(width: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title)
                    .font(.subheadline.weight(.semibold))
                Text(entry.detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                Text(entry.architectureName.isEmpty ? entry.scope.displayName : "\(entry.scope.displayName) · \(entry.architectureName)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(minHeight: 44, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
