import SwiftUI
import UIKit

// MARK: - Icon

/// Decodes item icons off the main thread, once each.
enum ImportIconDecoder {

    private static let cache = NSCache<NSString, UIImage>()

    /// The decoded icon for `data`, cached under `key`.
    static func image(for data: Data?, key: String) async -> UIImage? {
        guard let data else { return nil }
        if let cached = cache.object(forKey: key as NSString) {
            return cached
        }
        let decoded = await Task.detached(priority: .userInitiated) {
            UIImage(data: data)
        }.value
        if let decoded {
            cache.setObject(decoded, forKey: key as NSString)
        }
        return decoded
    }
}

/// An item's icon: the application's own icon once it has been analyzed,
/// the library's once it has been imported, and otherwise a symbol for the
/// kind of file.
struct ImportItemIcon: View {

    let item: ImportHub.Item
    var size: CGFloat = 44

    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else if let record = item.settlement?.record {
                ApplicationIconView(
                    artifactID: record.artifact.artifactID,
                    displayName: record.identity.displayName ?? item.fileName,
                    bundleIdentifier: record.identity.bundleIdentifier.rawValue,
                    size: size
                )
            } else {
                RoundedRectangle(cornerRadius: size * 0.2237, style: .continuous)
                    .fill(Color(.tertiarySystemFill))
                Image(systemName: placeholderSymbol)
                    .font(.system(size: size * 0.42, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.2237, style: .continuous))
        .accessibilityHidden(true)
        .task(id: item.prepared?.artifactID) {
            guard let prepared = item.prepared else { return }
            image = await ImportIconDecoder.image(for: prepared.iconData, key: prepared.artifactID.rawValue)
        }
    }

    private var placeholderSymbol: String {
        switch item.phase {
        case .awaitingSelection, .unpacked:
            return "doc.zipper"
        default:
            if item.fileName.lowercased().hasSuffix(".zip") { return "doc.zipper" }
            return item.stage == .failed ? "exclamationmark.triangle" : "app.dashed"
        }
    }
}

// MARK: - Queue row

/// One item in the queue or among the finished items: icon, name, stage,
/// progress, remaining work, and what can be done with it.
struct ImportItemRow: View {

    let item: ImportHub.Item
    let canRetry: Bool
    let onCancel: () -> Void
    let onRetry: () -> Void
    let onRemove: () -> Void
    let onShowDetails: () -> Void
    let onOpenRecord: (ApplicationRecord) -> Void

    @ScaledMetric(relativeTo: .body) private var iconSize: CGFloat = 44
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(alignment: .top, spacing: ZSpacing.sm) {
            ImportItemIcon(item: item, size: iconSize)
            VStack(alignment: .leading, spacing: ZSpacing.xxs) {
                Text(ImportQueueRendering.title(for: item))
                    .font(.body.weight(.semibold))
                    .lineLimit(2)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Label {
                    Text(ImportQueueRendering.statusLine(for: item))
                } icon: {
                    Image(systemName: item.stage.symbolName)
                }
                .font(.footnote.weight(.medium))
                .foregroundStyle(statusColor)

                if item.isActive {
                    ProgressView(value: item.fractionCompleted)
                        .progressViewStyle(.linear)
                        .tint(.accentColor)
                        .animation(reduceMotion ? nil : .linear(duration: 0.2), value: item.fractionCompleted)
                    if let remaining = ImportQueueRendering.remainingText(for: item.estimate) {
                        Text(remaining)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }

                outcome
            }
            Spacer(minLength: 0)
            if item.canCancel {
                Button(action: onCancel) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Cancel")
                .help("Cancel this import")
            }
        }
        .padding(.vertical, ZSpacing.xxs)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(ImportQueueRendering.title(for: item))
        .accessibilityValue(accessibilityValue)
        .accessibilityActions {
            if item.canCancel {
                Button("Cancel", action: onCancel)
            }
            if canRetry {
                Button("Retry", action: onRetry)
            }
            if let record = item.settlement?.record, item.settlement?.kind.isAccepted == true {
                Button("Open in Library") { onOpenRecord(record) }
            }
            Button("Details", action: onShowDetails)
            if item.isFinished {
                Button("Remove from List", action: onRemove)
            }
        }
        .contextMenu {
            Button(action: onShowDetails) {
                Label("Details", systemImage: "info.circle")
            }
            if let record = item.settlement?.record, item.settlement?.kind.isAccepted == true {
                Button { onOpenRecord(record) } label: {
                    Label("Open in Library", systemImage: "square.grid.2x2")
                }
            }
            if canRetry {
                Button(action: onRetry) {
                    Label("Retry", systemImage: "arrow.clockwise")
                }
            }
            if item.canCancel {
                Button(role: .destructive, action: onCancel) {
                    Label("Cancel Import", systemImage: "xmark.circle")
                }
            }
            if item.isFinished {
                Button(action: onRemove) {
                    Label("Remove from List", systemImage: "minus.circle")
                }
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            if item.canCancel {
                Button(role: .destructive, action: onCancel) {
                    Label("Cancel", systemImage: "xmark")
                }
            } else if item.isFinished {
                Button(action: onRemove) {
                    Label("Remove", systemImage: "minus.circle")
                }
                .tint(.gray)
            }
        }
        .swipeActions(edge: .leading) {
            if canRetry {
                Button(action: onRetry) {
                    Label("Retry", systemImage: "arrow.clockwise")
                }
                .tint(.accentColor)
            }
        }
    }

    @ViewBuilder
    private var outcome: some View {
        if let settlement = item.settlement {
            if item.stage == .failed {
                Text(settlement.failure?.message ?? ImportQueueRendering.message(for: settlement))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: ZSpacing.xs) {
                    if canRetry {
                        Button("Retry", action: onRetry)
                            .buttonStyle(.bordered)
                    }
                    Button("Details", action: onShowDetails)
                        .buttonStyle(.borderless)
                }
                .controlSize(.small)
                .padding(.top, 2)
            } else {
                Text(ImportQueueRendering.message(for: settlement))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let record = settlement.record, settlement.kind.isAccepted {
                    Button("Open in Library") { onOpenRecord(record) }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                }
            }
        }
    }

    private var subtitle: String? {
        var parts: [String] = []
        if item.identity != nil {
            parts.append(item.fileName)
        }
        if let container = item.containerFileName {
            parts.append("from \(container)")
        }
        if let byteCount = item.byteCount {
            parts.append(ImportQueueRendering.bytes(byteCount))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var statusColor: Color {
        switch item.stage {
        case .failed: return .red
        case .complete: return item.settlement?.kind.bucket == .skipped ? .secondary : .green
        default: return .secondary
        }
    }

    private var accessibilityValue: String {
        var parts = [ImportQueueRendering.statusLine(for: item)]
        if item.isActive {
            parts.append("\(Int((item.fractionCompleted * 100).rounded())) percent")
            if let remaining = ImportQueueRendering.remainingText(for: item.estimate) {
                parts.append(remaining)
            }
        }
        if let failure = item.settlement?.failure, item.stage == .failed {
            parts.append(failure.message)
        }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Preview row

/// One analyzed package in the preview: selection, icon, name, bundle ID,
/// version and build, size, what the analysis found, and any conflict.
struct ImportPreviewRow: View {

    let item: ImportHub.Item
    let onToggle: () -> Void
    let onResolve: (ConflictResolution?) -> Void
    let onOpenResolutionCenter: () -> Void
    let onCancel: () -> Void

    @ScaledMetric(relativeTo: .body) private var iconSize: CGFloat = 48

    var body: some View {
        HStack(alignment: .top, spacing: ZSpacing.sm) {
            Button(action: onToggle) {
                Image(systemName: item.isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundStyle(item.isSelected ? Color.accentColor : Color.secondary)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .accessibilityHidden(true)

            ImportItemIcon(item: item, size: iconSize)

            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: ZSpacing.xs) {
                    Text(ImportQueueRendering.title(for: item))
                        .font(.body.weight(.semibold))
                        .lineLimit(2)
                    Spacer(minLength: ZSpacing.xs)
                    if let byteCount = item.byteCount {
                        Text(ImportQueueRendering.bytes(byteCount))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                if let identity = item.identity {
                    Text(identity.bundleIdentifier.rawValue)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("Version \(ImportQueueRendering.versionText(identity))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let analysis = item.prepared?.analysis {
                    Text(Self.contents(of: analysis))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ZStatusBadge(
                        analysis.signingState.displayName,
                        systemImage: analysis.signingState.symbolName,
                        kind: analysis.signingState == .signaturePresent ? .info : .neutral
                    )
                }
                if let conflict = item.conflict {
                    conflictControl(conflict)
                }
                if let note = item.note {
                    Label(ImportQueueRendering.text(for: note), systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let container = item.containerFileName {
                    Text("From \(container)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, ZSpacing.xxs)
        .opacity(item.isSelected ? 1 : 0.62)
        .contentShape(Rectangle())
        .onTapGesture(perform: onToggle)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(item.isSelected ? "Selected for import" : "Not selected")
        .accessibilityAddTraits(item.isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityHint("Double-tap to include or exclude this app.")
        .accessibilityAction(named: item.isSelected ? "Exclude from Import" : "Include in Import", onToggle)
        .accessibilityActions {
            if item.conflict != nil {
                ForEach(ConflictResolution.allCases, id: \.self) { resolution in
                    Button(resolution.displayName) { onResolve(resolution) }
                }
            }
            Button("Cancel Import", action: onCancel)
        }
        .contextMenu {
            Button(action: onToggle) {
                Label(
                    item.isSelected ? "Don't Import" : "Include in Import",
                    systemImage: item.isSelected ? "circle" : "checkmark.circle"
                )
            }
            if item.conflict != nil {
                Menu {
                    ForEach(ConflictResolution.allCases, id: \.self) { resolution in
                        Button {
                            onResolve(resolution)
                        } label: {
                            Label(resolution.displayName, systemImage: resolution.symbolName)
                        }
                    }
                } label: {
                    Label("Resolve Conflict", systemImage: "square.on.square")
                }
            }
            Button(role: .destructive, action: onCancel) {
                Label("Cancel Import", systemImage: "xmark.circle")
            }
        }
    }

    @ViewBuilder
    private func conflictControl(_ conflict: ImportConflict) -> some View {
        Button(action: onOpenResolutionCenter) {
            HStack(spacing: ZSpacing.xxs) {
                ZStatusBadge(
                    ImportQueueRendering.headline(for: conflict),
                    systemImage: "square.on.square",
                    kind: item.resolution == nil ? .warning : .info
                )
                if let resolution = item.resolution {
                    ZStatusBadge(resolution.displayName, systemImage: resolution.symbolName, kind: resolution.isDestructive ? .warning : .neutral)
                } else if item.isSelected {
                    Text("Needs a choice")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.orange)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityHidden(true)
    }

    private var accessibilityLabel: String {
        var parts = [ImportQueueRendering.title(for: item)]
        if let identity = item.identity {
            parts.append("version \(ImportQueueRendering.versionText(identity))")
        }
        if let byteCount = item.byteCount {
            parts.append(ImportQueueRendering.bytes(byteCount))
        }
        if let analysis = item.prepared?.analysis {
            parts.append(Self.contents(of: analysis))
            parts.append(analysis.signingState.displayName)
        }
        if let conflict = item.conflict {
            parts.append(ImportQueueRendering.headline(for: conflict))
            parts.append(item.resolution.map { "Choice: \($0.displayName)" } ?? "Needs a choice")
        }
        if let note = item.note {
            parts.append(ImportQueueRendering.text(for: note))
        }
        return parts.joined(separator: ", ")
    }

    static func contents(of analysis: ApplicationAnalysis) -> String {
        let frameworks = analysis.frameworkCount == 1 ? "1 framework" : "\(analysis.frameworkCount) frameworks"
        let extensions = analysis.extensionCount == 1 ? "1 extension" : "\(analysis.extensionCount) extensions"
        return "\(frameworks) · \(extensions)"
    }
}

// MARK: - Archive offer

/// An archive that holds packages, offering to extract them.
struct ArchiveOfferRow: View {

    let item: ImportHub.Item
    let candidates: [NestedPackageCandidate]
    let onExtractSingle: () -> Void
    let onChoose: () -> Void
    let onDecline: () -> Void

    @ScaledMetric(relativeTo: .body) private var iconSize: CGFloat = 44

    var body: some View {
        VStack(alignment: .leading, spacing: ZSpacing.sm) {
            HStack(alignment: .top, spacing: ZSpacing.sm) {
                ImportItemIcon(item: item, size: iconSize)
                VStack(alignment: .leading, spacing: ZSpacing.xxs) {
                    Text(item.fileName)
                        .font(.body.weight(.semibold))
                        .lineLimit(2)
                    Text(ImportQueueRendering.statusLine(for: item))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Text(ImportQueueRendering.archiveOffer(for: candidates))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if candidates.count == 1, let only = candidates.first {
                Label("\(only.fileName) · \(ImportQueueRendering.bytes(only.byteCount))", systemImage: "app.dashed")
                    .font(.footnote)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: ZSpacing.xs) { buttons }
                VStack(alignment: .leading, spacing: ZSpacing.xs) { buttons }
            }
            .controlSize(.small)
        }
        .padding(.vertical, ZSpacing.xxs)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var buttons: some View {
        if candidates.count == 1 {
            Button(action: onExtractSingle) {
                Label("Extract App", systemImage: "arrow.down.doc")
            }
            .buttonStyle(.borderedProminent)
        } else {
            Button(action: onChoose) {
                Label("Choose Apps…", systemImage: "checklist")
            }
            .buttonStyle(.borderedProminent)
        }
        Button("Don't Import", action: onDecline)
            .buttonStyle(.bordered)
    }
}

// MARK: - Summary

/// The outcome of everything in the hub, in the four numbers the summary
/// promises: Imported, Skipped, Replaced, Failed.
struct ImportSummaryCard: View {

    let summary: ImportSummary
    let retryableCount: Int
    let onRetryFailed: () -> Void
    let onOpenLibrary: () -> Void
    let onClear: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: ZSpacing.sm) {
            Text(ImportQueueRendering.headline(for: summary))
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: ZSpacing.xs), count: dynamicTypeSize.isAccessibilitySize ? 2 : 4),
                spacing: ZSpacing.xs
            ) {
                ForEach(ImportOutcomeBucket.allCases, id: \.self) { bucket in
                    tile(for: bucket)
                }
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: ZSpacing.xs) { actions }
                VStack(alignment: .leading, spacing: ZSpacing.xs) { actions }
            }
            .controlSize(.small)
        }
        .padding(ZSpacing.md)
        .zynCardBackground(cornerRadius: ZRadius.lg)
    }

    @ViewBuilder
    private var actions: some View {
        if retryableCount > 0 {
            Button(action: onRetryFailed) {
                Label(retryableCount == 1 ? "Retry Failed" : "Retry \(retryableCount) Failed", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
        }
        if summary.addedCount > 0 {
            Button(action: onOpenLibrary) {
                Label("Open Library", systemImage: "square.grid.2x2")
            }
            .buttonStyle(.bordered)
        }
        Button("Clear Finished", action: onClear)
            .buttonStyle(.borderless)
    }

    private func tile(for bucket: ImportOutcomeBucket) -> some View {
        let count = summary.count(of: bucket)
        return VStack(spacing: 2) {
            Image(systemName: bucket.symbolName)
                .font(.body)
                .foregroundStyle(count > 0 ? color(for: bucket) : .secondary)
            Text("\(count)")
                .font(.title3.weight(.bold))
                .monospacedDigit()
                .contentTransition(.numericText())
            Text(bucket.displayName)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, ZSpacing.xs)
        .background(Color(.tertiarySystemFill).opacity(0.6), in: RoundedRectangle(cornerRadius: ZRadius.sm))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(count) \(bucket.displayName)")
    }

    private func color(for bucket: ImportOutcomeBucket) -> Color {
        switch bucket {
        case .imported: return .green
        case .skipped: return .secondary
        case .replaced: return .blue
        case .failed: return .red
        }
    }
}

// MARK: - Home banner

/// Home's view of the Import Hub while it has work or needs the user.
@MainActor
struct ImportHubStatusBanner: View {

    @ObservedObject var hub: ImportHub
    let onOpen: () -> Void

    var body: some View {
        if let status {
            Button(action: onOpen) {
                HStack(spacing: ZSpacing.sm) {
                    Image(systemName: status.symbol)
                        .font(.title3)
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(status.title)
                            .font(.subheadline.weight(.semibold))
                        Text(status.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(ZSpacing.md)
                .zynCardBackground(cornerRadius: ZRadius.lg)
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityHint("Opens the Import Hub.")
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    private var status: (title: String, detail: String, symbol: String)? {
        let active = hub.items.filter(\.isActive).count
        let ready = hub.readyItems.count
        let archives = hub.items.filter(\.isAwaitingSelection).count
        let conflicts = hub.unresolvedConflictCount
        guard active + ready + archives > 0 || hub.receivingDropCount > 0 else { return nil }

        var parts: [String] = []
        if active > 0 { parts.append(active == 1 ? "1 in progress" : "\(active) in progress") }
        if ready > 0 { parts.append(ready == 1 ? "1 ready to review" : "\(ready) ready to review") }
        if archives > 0 { parts.append(archives == 1 ? "1 archive needs a choice" : "\(archives) archives need a choice") }
        if conflicts > 0 { parts.append(conflicts == 1 ? "1 conflict to resolve" : "\(conflicts) conflicts to resolve") }

        if hub.isPaused {
            return ("Imports Paused", parts.joined(separator: " · "), "pause.circle")
        }
        if active > 0 || hub.receivingDropCount > 0 {
            return ("Importing", parts.joined(separator: " · "), "arrow.down.circle")
        }
        return ("Waiting for You", parts.joined(separator: " · "), "checklist")
    }
}

// MARK: - Details

/// Everything known about one item: where it came from, how far it got,
/// what the analysis found, and what happened.
struct ImportItemDetailView: View {

    let item: ImportHub.Item
    let canRetry: Bool
    let onRetry: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("File") {
                    LabeledContent("Name", value: item.fileName)
                    if let container = item.containerFileName {
                        LabeledContent("From Archive", value: container)
                    }
                    LabeledContent("Source", value: item.origin.displayName)
                    LabeledContent("Added") {
                        Text(item.enqueuedAt, format: Date.FormatStyle(date: .abbreviated, time: .shortened))
                    }
                    if let byteCount = item.byteCount {
                        LabeledContent("Size", value: ImportQueueRendering.bytes(byteCount))
                    }
                }

                Section("Stages") {
                    ForEach(ImportQueueStage.track, id: \.self) { stage in
                        stageRow(stage)
                    }
                    if item.stage == .failed {
                        Label(ImportQueueStage.failed.displayName, systemImage: ImportQueueStage.failed.symbolName)
                            .foregroundStyle(.red)
                    }
                }

                if let settlement = item.settlement {
                    Section(settlement.failure?.title ?? "Outcome") {
                        Text(settlement.failure?.message ?? ImportQueueRendering.message(for: settlement))
                            .fixedSize(horizontal: false, vertical: true)
                        if let failure = settlement.failure, failure.recovery != .none {
                            Label(failure.recovery.displayName, systemImage: failure.recovery.symbolName)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if let prepared = item.prepared {
                    Section("Application") {
                        LabeledContent("Name", value: prepared.identity.displayName ?? "\u{2014}")
                        LabeledContent("Bundle ID", value: prepared.identity.bundleIdentifier.rawValue)
                        LabeledContent("Version", value: prepared.identity.shortVersionString ?? "\u{2014}")
                        LabeledContent("Build", value: prepared.identity.buildVersion ?? "\u{2014}")
                        LabeledContent("Package Size", value: ImportQueueRendering.bytes(prepared.byteCount))
                    }
                    ApplicationAnalysisSection(analysis: prepared.analysis)
                }

                Section {
                    Text("The original file was only read. ZynSign worked on its own copy.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Import Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
                if canRetry {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Retry") {
                            onRetry()
                            dismiss()
                        }
                    }
                }
            }
        }
    }

    private func stageRow(_ stage: ImportQueueStage) -> some View {
        let track = ImportQueueStage.track
        let reached = track.firstIndex(of: item.stage == .failed ? item.furthestStage : item.stage) ?? 0
        let position = track.firstIndex(of: stage) ?? 0
        let isDone = item.stage == .complete || position < reached
        let isCurrent = !item.isFinished && position == reached
        let symbol = isDone ? "checkmark.circle.fill" : (isCurrent ? "circle.inset.filled" : "circle")
        let color: Color = isDone ? .green : (isCurrent ? .accentColor : .secondary)
        return Label(stage.displayName, systemImage: symbol)
            .foregroundStyle(color)
            .accessibilityValue(isDone ? "Done" : (isCurrent ? "Current" : "Not reached"))
    }
}

/// The analysis facts, as a list section, shared by the import details and
/// the library's application details.
struct ApplicationAnalysisSection: View {

    let analysis: ApplicationAnalysis

    var body: some View {
        Section {
            LabeledContent("Signing", value: analysis.signingState.displayName)
            LabeledContent("Provisioning Profile", value: analysis.includesProvisioningProfile ? "Embedded" : "None")
            LabeledContent("Frameworks", value: "\(analysis.frameworkCount)")
            LabeledContent("Extensions", value: "\(analysis.extensionCount)")
            if let minimum = analysis.minimumOSVersion {
                LabeledContent("Minimum OS", value: minimum)
            }
            if !analysis.supportedDevices.isEmpty {
                LabeledContent("Devices", value: analysis.supportedDevices.joined(separator: ", "))
            }
            LabeledContent("Files", value: "\(analysis.fileCount)")
            LabeledContent("Unpacked Size", value: ImportQueueRendering.bytes(analysis.unpackedByteCount))
        } header: {
            Text("Analysis")
        } footer: {
            Text(analysis.signingState.explanation)
        }
    }
}
