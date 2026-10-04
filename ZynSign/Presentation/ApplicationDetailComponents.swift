import SwiftUI

// MARK: - Reusable detail components

struct DetailSectionCard<Content: View>: View {
    let title: String
    let subtitle: String?
    let symbol: String
    @Binding var isExpanded: Bool
    let content: Content

    init(
        title: String,
        subtitle: String? = nil,
        symbol: String,
        isExpanded: Binding<Bool>,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.symbol = symbol
        self._isExpanded = isExpanded
        self.content = content()
    }

    var body: some View {
        ZCard {
            DisclosureGroup(isExpanded: $isExpanded) {
                VStack(alignment: .leading, spacing: ZSpacing.sm) {
                    content
                }
                .padding(.top, ZSpacing.sm)
            } label: {
                HStack(spacing: ZSpacing.sm) {
                    Image(systemName: symbol)
                        .font(.headline)
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 28)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title)
                            .font(.headline)
                            .foregroundStyle(.primary)
                        if let subtitle {
                            Text(subtitle)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .animation(ZMotion.standard, value: isExpanded)
        }
    }
}

struct SectionHeading: View {
    let title: String
    let symbol: String

    var body: some View {
        HStack(spacing: ZSpacing.xs) {
            Image(systemName: symbol)
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)
            Text(title)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
        }
    }
}

struct DetailValueRow: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

struct QuickActionTile: View {
    let title: String
    let subtitle: String
    let symbol: String
    let tint: Color

    var body: some View {
        HStack(alignment: .top, spacing: ZSpacing.sm) {
            Image(systemName: symbol)
                .font(.headline)
                .foregroundStyle(tint)
                .frame(width: 32, height: 32)
                .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(ZSpacing.sm)
        .frame(maxWidth: .infinity, minHeight: 68, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: ZRadius.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: ZRadius.card, style: .continuous)
                .stroke(Color(.separator).opacity(0.35), lineWidth: 0.5)
        }
        .contentShape(RoundedRectangle(cornerRadius: ZRadius.card, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

struct CountPill: View {
    let title: String
    let count: Int
    let symbol: String

    var body: some View {
        Label {
            Text("\(count) \(title)")
                .font(.caption.weight(.medium))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        } icon: {
            Image(systemName: symbol)
                .font(.caption)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, ZSpacing.xs)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity)
        .background(Color(.tertiarySystemFill), in: Capsule())
    }
}

struct ComponentCountTile: View {
    let title: String
    let count: Int
    let symbol: String

    var body: some View {
        HStack(spacing: ZSpacing.xs) {
            Image(systemName: symbol)
                .foregroundStyle(Color.accentColor)
                .frame(width: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(count.formatted())
                    .font(.headline.monospacedDigit())
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(ZSpacing.sm)
        .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: ZRadius.card, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(count) \(title)")
    }
}

struct ComponentDisclosureList: View {
    let title: String
    let symbol: String
    let components: [ApplicationBundleComponent]

    var body: some View {
        DisclosureGroup("\(title) (\(components.count))") {
            if components.isEmpty {
                Text("None detected")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            } else {
                LazyVStack(alignment: .leading, spacing: ZSpacing.xs) {
                    ForEach(components) { component in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(alignment: .firstTextBaseline) {
                                Label(component.name, systemImage: symbol)
                                    .font(.subheadline.weight(.medium))
                                    .lineLimit(2)
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: ZSpacing.xs)
                                if component.isWidget {
                                    ZStatusBadge("Widget", systemImage: "rectangle.stack", kind: .info)
                                }
                            }
                            Text(component.path.rawValue)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                            if let point = component.extensionPointIdentifier {
                                Text(point)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                    .textSelection(.enabled)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 5)
                        if component.id != components.last?.id { Divider() }
                    }
                }
            }
        }
        .font(.subheadline.weight(.medium))
        .animation(ZMotion.fast, value: components)
        .accessibilityHint("Expands to list detected \(title.lowercased()).")
    }
}

struct ValidationStatusBadge: View {
    let classification: ValidationClassification

    var body: some View {
        let badge: ZStatusBadge
        switch classification {
        case .valid:
            badge = ZStatusBadge("Valid", systemImage: "checkmark.circle.fill", kind: .success)
        case .invalid:
            badge = ZStatusBadge("Invalid", systemImage: "xmark.circle.fill", kind: .error)
        case .unsupported:
            badge = ZStatusBadge("Unsupported", systemImage: "questionmark.circle.fill", kind: .unsupported)
        case .ambiguous:
            badge = ZStatusBadge("Ambiguous", systemImage: "exclamationmark.triangle.fill", kind: .warning)
        }
        return badge.accessibilityLabel("Validation status: \(classification.displayName)")
    }
}

struct DiagnosticRow: View {
    let diagnostic: ApplicationInspectionDiagnostic

    var body: some View {
        HStack(alignment: .top, spacing: ZSpacing.sm) {
            severityBadge
            VStack(alignment: .leading, spacing: 4) {
                Text(diagnostic.title)
                    .font(.subheadline.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Text(diagnostic.detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(diagnostic.severity.displayName): \(diagnostic.title). \(diagnostic.detail)")
    }

    private var severityBadge: some View {
        let kind: ZStatusBadge.Kind
        let symbol: String
        switch diagnostic.severity {
        case .success:
            kind = .success
            symbol = "checkmark.circle.fill"
        case .warning:
            kind = .warning
            symbol = "exclamationmark.triangle.fill"
        case .error:
            kind = .error
            symbol = "xmark.circle.fill"
        case .unsupported:
            kind = .unsupported
            symbol = "questionmark.circle.fill"
        }
        return ZStatusBadge(diagnostic.severity.displayName, systemImage: symbol, kind: kind)
    }
}

// MARK: - Visual bundle tree

struct BundleTreeView: View {
    let bundlePath: ArchivePath
    let contents: BundleContents
    @State private var isRootExpanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label("Payload/", systemImage: "folder.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.vertical, 4)
                .accessibilityLabel("Payload folder")

            Button {
                withAnimation(ZMotion.fast) { isRootExpanded.toggle() }
            } label: {
                HStack(spacing: ZSpacing.xs) {
                    Image(systemName: isRootExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.bold))
                        .frame(width: 14)
                        .accessibilityHidden(true)
                    Image(systemName: "app.gift.fill")
                        .foregroundStyle(Color.accentColor)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(bundlePath.lastComponent + "/")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("\(contents.folderCount) folders · \(contents.fileCount) files")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(bundlePath.lastComponent) app folder, \(contents.folderCount) folders, \(contents.fileCount) files")
            .accessibilityHint(isRootExpanded ? "Collapse the app's bundle tree." : "Expand the app's bundle tree.")

            if isRootExpanded {
                if contents.rootEntries.isEmpty {
                    Text("This app bundle has no recorded entries.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 6)
                        .padding(.leading, 26)
                } else {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        ForEach(contents.rootEntries, id: \.path) { child in
                            BundleTreeEntryView(contents: contents, entry: child)
                        }
                    }
                    .padding(.leading, 24)
                    .padding(.top, 3)
                }
            }
        }
        .padding(ZSpacing.sm)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: ZRadius.card, style: .continuous))
        .accessibilityElement(children: .contain)
    }
}

struct BundleTreeEntryView: View {
    let contents: BundleContents
    let entry: BundleEntry
    @State private var isExpanded = false

    private var isExpandable: Bool {
        entry.isDirectory && !(contents.entries(in: entry.path) ?? []).isEmpty
    }

    private var fileCountText: String? {
        guard entry.isDirectory, let counts = contents.directCounts(in: entry.path) else { return nil }
        var pieces: [String] = []
        if counts.folders > 0 { pieces.append("\(counts.folders) folders") }
        if counts.files > 0 { pieces.append("\(counts.files) files") }
        if counts.otherEntries > 0 { pieces.append("\(counts.otherEntries) other") }
        return pieces.isEmpty ? "Empty folder" : pieces.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if entry.isDirectory {
                Button {
                    withAnimation(ZMotion.fast) { isExpanded.toggle() }
                } label: {
                    entryLabel(isExpanded: isExpanded)
                }
                .buttonStyle(.plain)
                .disabled(!isExpandable)
                .accessibilityLabel(directoryAccessibilityLabel)
                .accessibilityHint(isExpandable ? (isExpanded ? "Collapse folder." : "Expand folder.") : "Empty folder.")

                if isExpanded, let children = contents.entries(in: entry.path), !children.isEmpty {
                    nestedChildrenView(children)
                        .padding(.leading, 18)
                        .padding(.top, 2)
                }
            } else {
                entryLabel(isExpanded: false)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(fileAccessibilityLabel)
            }
        }
    }

    /// Type-erases the recursive level so deeply nested bundle trees remain
    /// finite at compile time while each expanded folder stays lazy.
    private func nestedChildrenView(_ children: [BundleEntry]) -> AnyView {
        AnyView(
            LazyVStack(alignment: .leading, spacing: 3) {
                ForEach(children, id: \.path) { child in
                    BundleTreeEntryView(contents: contents, entry: child)
                }
            }
        )
    }

    private func entryLabel(isExpanded: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: ZSpacing.xs) {
            Image(systemName: entry.isDirectory
                  ? (isExpanded ? "chevron.down" : "chevron.right")
                  : BundleEntryRowContent.symbolName(for: entry.kind))
                .font(.caption.weight(.semibold))
                .foregroundStyle(entry.isDirectory ? Color.accentColor : Color.secondary)
                .frame(width: 15)
                .accessibilityHidden(true)
            Text(entry.name + (entry.isDirectory ? "/" : ""))
                .font(.system(.subheadline, design: entry.isDirectory ? .default : .monospaced))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .truncationMode(.middle)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 3)
            if let countText = fileCountText {
                Text(countText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
                    .lineLimit(2)
            } else if let byteCount = entry.declaredByteCount {
                Text(ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var directoryAccessibilityLabel: String {
        let summary = fileCountText ?? "Folder"
        return "\(entry.name), folder, \(summary)"
    }

    private var fileAccessibilityLabel: String {
        let kind = BundleEntryRowContent.kindText(for: entry.kind)
        let size = entry.declaredByteCount.map {
            ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file)
        }
        return "\(entry.name), \(kind)\(size.map { ", \($0)" } ?? "")"
    }
}

enum InfoPlistDisplayMode: Hashable {
    case friendly
    case raw
}

struct FriendlyInfoField: Identifiable {
    let title: String
    let rawKey: String
    let value: String

    var id: String { rawKey }
}

// MARK: - Persisted record projection

/// The detail screen's values derived from the library record. Absent
/// declarations remain absent, and an unavailable package is represented
/// explicitly instead of being reported as available.
struct ApplicationDetailContent: Equatable {
    let name: String
    let bundleIdentifier: String
    let versionText: String
    let buildText: String
    let sourceFileName: String
    let artifactStatus: String
    let artifactExplanation: String?
    let canExploreBundle: Bool
    let imported: Date
    let updated: Date?

    init(entry: LibraryEntry) {
        let record = entry.record
        self.name = record.displayName ?? "Unnamed Application"
        self.bundleIdentifier = record.bundleIdentifier.rawValue
        self.versionText = record.identity.shortVersionString ?? "—"
        self.buildText = record.identity.buildVersion ?? "—"
        self.sourceFileName = record.sourceFileName ?? "—"
        self.imported = record.importedAt
        self.updated = record.updatedAt > record.importedAt ? record.updatedAt : nil
        self.canExploreBundle = entry.isArtifactAvailable
        switch entry.artifactAvailability {
        case .available:
            self.artifactStatus = entry.artifactAvailability.displayName
            self.artifactExplanation = nil
        case .missing:
            self.artifactStatus = entry.artifactAvailability.displayName
            self.artifactExplanation = "The package file kept for this record could not be found in ZynSign's storage. The record's information is preserved; the package itself is gone."
        case .inconsistent:
            self.artifactStatus = entry.artifactAvailability.displayName
            self.artifactExplanation = "The package file kept for this record has changed since it was imported: it no longer matches what the record captured. The file may have been damaged or replaced."
        }
    }
}
