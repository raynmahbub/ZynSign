import SwiftUI
import UIKit

/// The read-only inspection panel for one explorer node.
///
/// Folders are described from the entry table already in memory. Files,
/// frameworks, and extensions ask the preview use case for one bounded read.
/// This view has no editing control.
struct ExplorerInspectorHost: View {

    let recordID: ApplicationRecordIdentifier
    let contents: BundleContents
    let node: ExplorerNodeID
    var onReveal: (ExplorerNodeID) -> Void
    var onOpen: (ExplorerNodeID) -> Void
    var onCopy: (String, String) -> Void

    @Environment(\.applicationEnvironment) private var environment
    @State private var phase: Phase = .idle

    private enum Phase {
        case idle
        case loading
        case loaded(ExplorerEntryInspection)
        case failed(String)
    }

    var body: some View {
        List {
            breadcrumbSection
            headerSection
            inspectionSections
            actionsSection
            footnoteSection
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: node) { await loadIfNeeded() }
    }

    private var title: String {
        ExplorerTreeProjection.name(of: node, contents: contents)
    }

    private var locationText: String {
        ExplorerTreeProjection.location(of: node, contents: contents)
    }

    private var needsRead: Bool {
        guard let entry = ExplorerTreeProjection.entry(for: node, contents: contents) else { return false }
        if entry.isDirectory {
            return BundleFileClassification.recognize(entry).hasBundlePage
        }
        return entry.kind == .regularFile
    }

    // MARK: - Sections

    private var breadcrumbSection: some View {
        Section {
            ExplorerBreadcrumbBar(
                crumbs: ExplorerTreeProjection.breadcrumb(for: node, contents: contents)
            ) { crumb in
                onOpen(crumb)
            }
            .listRowInsets(EdgeInsets(top: ZSpacing.xs, leading: ZSpacing.sm, bottom: ZSpacing.xs, trailing: ZSpacing.sm))
        }
    }

    private var headerSection: some View {
        Section {
            HStack(alignment: .center, spacing: ZSpacing.sm) {
                ExplorerFileIcon(symbol: headerSymbol, classification: headerClassification)
                    .font(.title2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(headerClassification.displayName)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: ZSpacing.sm)
                ZStatusBadge("Read-only", systemImage: "eye", kind: .neutral)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(title), \(headerClassification.displayName), read-only")
        }
    }

    @ViewBuilder
    private var inspectionSections: some View {
        if needsRead {
            switch phase {
            case .idle, .loading:
                Section {
                    ProgressView("Reading…")
                        .frame(maxWidth: .infinity, alignment: .center)
                        .accessibilityLabel("Reading a read-only preview")
                }
            case .failed(let message):
                Section {
                    ContentUnavailableView {
                        Label("Preview Unavailable", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(message)
                    }
                    .listRowBackground(Color.clear)
                }
            case .loaded(let inspection):
                inspectionBody(inspection)
            }
        } else {
            folderSections
        }
    }

    private var actionsSection: some View {
        Section("Actions") {
            Button {
                onReveal(node)
            } label: {
                Label(ExplorerQuickAction.revealInTree.rawValue, systemImage: ExplorerQuickAction.revealInTree.systemImage)
            }
            .accessibilityHint("Shows this item in the bundle tree. Does not modify the package.")
            Button {
                onCopy(locationText, "Path copied")
            } label: {
                Label(ExplorerQuickAction.copyPath.rawValue, systemImage: ExplorerQuickAction.copyPath.systemImage)
            }
            Button {
                onCopy(title, "Filename copied")
            } label: {
                Label(ExplorerQuickAction.copyFilename.rawValue, systemImage: ExplorerQuickAction.copyFilename.systemImage)
            }
        }
    }

    private var footnoteSection: some View {
        Section {
            Text(ExplorerPresentationCopy.readOnlyNote)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Folder

    @ViewBuilder
    private var folderSections: some View {
        Section("Location") {
            LabeledContent("Path") {
                Text(locationText)
                    .multilineTextAlignment(.trailing)
                    .textSelection(.enabled)
            }
            if let count = childCount {
                LabeledContent("Items", value: ExplorerTreeProjection.itemCountText(count))
            }
        }
        if let children, !children.isEmpty {
            Section("Contents") {
                ForEach(children.prefix(12), id: \.path) { child in
                    Button {
                        onOpen(.entry(child.path))
                    } label: {
                        HStack {
                            ExplorerFileIcon(
                                symbol: BundleFileClassification.recognize(child).symbolName,
                                classification: BundleFileClassification.recognize(child)
                            )
                            Text(child.name)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Text(BundleFileClassification.recognize(child).displayName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityHint("Opens a read-only view of this item.")
                }
                if children.count > 12 {
                    Text("\(children.count - 12) more in the tree")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var children: [BundleEntry]? {
        switch node {
        case .payload:
            return nil
        case .application:
            return contents.rootEntries
        case .entry(let path):
            return contents.entries(in: path)
        }
    }

    private var childCount: Int? {
        switch node {
        case .payload: return 1
        case .application: return contents.rootEntries.count
        case .entry(let path): return contents.childCount(of: path)
        }
    }

    // MARK: - Inspection bodies

    @ViewBuilder
    private func inspectionBody(_ inspection: ExplorerEntryInspection) -> some View {
        switch inspection.body {
        case .text(let preview):
            textSections(preview, inspection: inspection)
        case .image(let preview):
            imageSections(preview, inspection: inspection)
        case .macho(let report):
            machoSections(report, inspection: inspection)
        case .profile(let summary):
            profileSections(summary, inspection: inspection)
        case .framework(let report):
            frameworkSections(report)
        case .appExtension(let report):
            extensionSections(report)
        case .binary(let facts):
            binarySections(facts, inspection: inspection)
        case .unavailable(let title, let message):
            Section {
                ContentUnavailableView {
                    Label(title, systemImage: "doc")
                } description: {
                    Text(message)
                }
                .listRowBackground(Color.clear)
            }
        }
    }

    @ViewBuilder
    private func textSections(_ preview: ExplorerTextPreview, inspection: ExplorerEntryInspection) -> some View {
        locationSection(inspection.locationText, bytes: inspection.declaredByteCount)
        Section(preview.kindTitle) {
            Text(preview.text)
                .font(.system(.footnote, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel("\(preview.kindTitle) preview")
        }
        if preview.truncated {
            Section {
                Text("The preview is truncated. The rest of the file was not read, and nothing was changed.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func imageSections(_ preview: ExplorerImagePreview, inspection: ExplorerEntryInspection) -> some View {
        locationSection(inspection.locationText, bytes: inspection.declaredByteCount)
        Section("Preview") {
            ExplorerImagePreviewView(data: preview.data, name: inspection.name)
        }
    }

    @ViewBuilder
    private func machoSections(_ report: ExplorerMachOReport, inspection: ExplorerEntryInspection) -> some View {
        Section("Mach-O") {
            LabeledContent("Architecture", value: report.architectureSummary)
            LabeledContent("Executable", value: inspection.name)
            LabeledContent("File Size") {
                byteText(inspection.declaredByteCount)
            }
            LabeledContent("Load Commands", value: report.loadCommandSummary)
            LabeledContent("Encryption") {
                encryptionBadge(report.encryptionSummary)
            }
            LabeledContent("Signature") {
                signatureBadge(report.signatureSummary)
            }
            LabeledContent("Executable Type", value: report.fileTypeSummary)
        }
        if report.slices.count > 1 {
            Section("Architectures") {
                ForEach(report.slices) { slice in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(slice.architectureName).font(.body)
                        Text("\(slice.fileTypeName) · \(slice.loadCommandCount) load commands")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        HStack {
                            encryptionBadge(slice.encryption)
                            signatureBadge(slice.signature.displayName)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
        if inspection.classification != .executable {
            Section {
                Text("Recognized from the file header, not from its name.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        noteSection(report.note)
    }

    @ViewBuilder
    private func profileSections(_ summary: ExplorerProfileSummary, inspection: ExplorerEntryInspection) -> some View {
        locationSection(inspection.locationText, bytes: inspection.declaredByteCount)
        Section("Profile") {
            LabeledContent("Name", value: summary.name ?? "—")
            LabeledContent("Team", value: summary.teamIdentifiers.isEmpty ? "—" : summary.teamIdentifiers.joined(separator: ", "))
            LabeledContent("Expiration") {
                if let date = summary.expiration {
                    Text(date, format: .dateTime.year().month().day())
                } else {
                    Text(summary.expirationFallback ?? "—")
                }
            }
        }
        entitlementSection(summary.entitlementLines, truncated: summary.entitlementsTruncated)
        noteSection(summary.note)
    }

    @ViewBuilder
    private func frameworkSections(_ report: ExplorerFrameworkReport) -> some View {
        Section("Framework") {
            LabeledContent("Name", value: report.name)
            LabeledContent("Version", value: report.version ?? "—")
            LabeledContent("Build", value: report.build ?? "—")
            LabeledContent("Identifier", value: report.bundleIdentifier ?? "—")
            LabeledContent("Executable", value: report.executableName ?? "—")
            LabeledContent("Signature") {
                signatureBadge(report.signature.displayName)
            }
            LabeledContent("Size") {
                byteText(report.declaredByteCount)
            }
            LabeledContent("Path") {
                Text(ExplorerLocation.displayPath(bundleName: contents.bundleName, entry: report.path))
                    .multilineTextAlignment(.trailing)
                    .textSelection(.enabled)
            }
        }
        if let executable = report.executablePath {
            Section {
                Button {
                    onOpen(.entry(executable))
                } label: {
                    Label("Open Executable", systemImage: "cpu")
                }
                .accessibilityHint("Opens a read-only Mach-O inspection of the framework executable.")
            }
        }
        noteSection(report.note)
    }

    @ViewBuilder
    private func extensionSections(_ report: ExplorerExtensionReport) -> some View {
        Section("Extension") {
            LabeledContent("Kind") {
                Text(report.kind.displayName)
            }
            if let point = report.kind.pointIdentifier, case .other = report.kind {
                LabeledContent("Point Identifier") {
                    Text(point)
                        .multilineTextAlignment(.trailing)
                        .textSelection(.enabled)
                }
            }
            LabeledContent("Bundle ID", value: report.bundleIdentifier ?? "—")
            LabeledContent("Executable", value: report.executableName ?? "—")
            LabeledContent("Version", value: report.version ?? "—")
            LabeledContent("Path") {
                Text(ExplorerLocation.displayPath(bundleName: contents.bundleName, entry: report.path))
                    .multilineTextAlignment(.trailing)
                    .textSelection(.enabled)
            }
        }
        entitlementSection(report.entitlementLines, truncated: report.entitlementsTruncated)
        if let executable = report.executablePath {
            Section {
                Button {
                    onOpen(.entry(executable))
                } label: {
                    Label("Open Executable", systemImage: "cpu")
                }
            }
        }
        noteSection(report.entitlementsNote)
    }

    @ViewBuilder
    private func binarySections(_ facts: ExplorerBinaryFacts, inspection: ExplorerEntryInspection) -> some View {
        locationSection(inspection.locationText, bytes: inspection.declaredByteCount)
        Section("Binary") {
            LabeledContent("Kind", value: inspection.classification.displayName)
            LabeledContent("Prefix Read") {
                byteText(facts.readByteCount)
            }
            Text(facts.message)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func locationSection(_ path: String, bytes: Int?) -> some View {
        Section("Location") {
            LabeledContent("Path") {
                Text(path)
                    .multilineTextAlignment(.trailing)
                    .textSelection(.enabled)
            }
            LabeledContent("Declared Size") {
                byteText(bytes)
            }
        }
    }

    @ViewBuilder
    private func entitlementSection(_ lines: [ExplorerEntitlementLine], truncated: Bool) -> some View {
        Section("Entitlements") {
            if lines.isEmpty {
                Text("No entitlement keys were read.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(lines) { line in
                    LabeledContent(line.key) {
                        Text(line.valueText)
                            .multilineTextAlignment(.trailing)
                            .textSelection(.enabled)
                    }
                }
            }
            if truncated {
                Text("Further entitlement keys were not shown.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func noteSection(_ note: String) -> some View {
        Section {
            Text(note)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func encryptionBadge(_ status: ExplorerEncryptionStatus) -> some View {
        let kind: ZStatusBadge.Kind = {
            switch status {
            case .encrypted: return .warning
            case .notEncrypted, .commandAbsent: return .neutral
            case .unreadable: return .info
            }
        }()
        return ZStatusBadge(status.displayName, systemImage: status == .notEncrypted || status == .commandAbsent ? "lock.open" : "lock", kind: kind)
    }

    private func signatureBadge(_ text: String) -> some View {
        let present = text == ExplorerSignaturePresence.commandPresent.displayName
        return ZStatusBadge(text, systemImage: "signature", kind: present ? .info : .neutral)
    }

    @ViewBuilder
    private func byteText(_ bytes: Int?) -> some View {
        if let bytes {
            Text(Int64(bytes), format: .byteCount(style: .file))
        } else {
            Text("—")
        }
    }

    private var headerSymbol: String {
        if node == .application { return "app.fill" }
        return headerClassification.symbolName
    }

    private var headerClassification: BundleFileClassification {
        if node == .payload || node == .application { return .folder }
        if let entry = ExplorerTreeProjection.entry(for: node, contents: contents) {
            return BundleFileClassification.recognize(entry)
        }
        return .generic
    }

    // MARK: - Load

    private func loadIfNeeded() async {
        guard needsRead, let entry = ExplorerTreeProjection.entry(for: node, contents: contents) else {
            phase = .idle
            return
        }
        phase = .loading
        do {
            let inspection = try await environment.bundleEntryInspection.preview(
                recordWithID: recordID,
                contents: contents,
                entry: entry
            )
            if Task.isCancelled { return }
            phase = .loaded(inspection)
        } catch is CancellationError {
            return
        } catch {
            if Task.isCancelled { return }
            phase = .failed(IPABundleEntryInspection.failureMessage(for: error))
        }
    }
}

private struct ExplorerImagePreviewView: View {
    let data: Data
    let name: String

    var body: some View {
        if let image = UIImage(data: data) {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: 360)
                .clipShape(RoundedRectangle(cornerRadius: ZRadius.card, style: .continuous))
                .accessibilityLabel("Image preview of \(name)")
        } else {
            ContentUnavailableView {
                Label("Preview Unavailable", systemImage: "photo")
            } description: {
                Text("The file was read, but it could not be shown as an image. Nothing was changed.")
            }
        }
    }
}
