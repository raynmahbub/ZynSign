import SwiftUI

// MARK: - Application Library Row & Card Components

/// One row in the application library: the application icon, display name,
/// identifier, declared versions, the date it was imported, and the state
/// badges its card carries. Favorite and artifact state are shown inline —
/// words first, never styling alone. While searching, the matching text is
/// highlighted, and a match the visible text does not show (a developer, a
/// team, a collection) is explained on its own line.
///
/// The row is an equatable value: SwiftUI skips re-rendering it unless one
/// of its inputs changed.
struct ApplicationLibraryRow: View, Equatable {

    let entry: LibraryEntry
    var signingState: ApplicationLibraryModel.SigningState = .notSigned
    var expiry: LibraryExpiryStatus = .unknown
    var highlightTerms: [String] = []
    var matchContext: String? = nil
    var showsSigningInsights = false

    /// `nil` outside selection mode; otherwise whether the entry is selected.
    var isSelected: Bool? = nil

    var body: some View {
        let content = ApplicationLibraryRowContent(entry: entry)
        HStack(spacing: ZSpacing.sm) {
            if let isSelected {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : Color(.tertiaryLabel))
                    .imageScale(.large)
                    .frame(minWidth: 28)
            }
            ApplicationIconView(
                artifactID: entry.record.artifact.artifactID,
                displayName: content.name,
                bundleIdentifier: content.bundleIdentifier
            )
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: ZSpacing.xxs) {
                    LibraryHighlighter.text(content.name, terms: highlightTerms)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if entry.record.isFavorite {
                        Image(systemName: "star.fill")
                            .font(.caption2)
                            .foregroundStyle(.yellow)
                            .accessibilityHidden(true)
                    }
                }
                LibraryHighlighter.text(content.bundleIdentifier, terms: highlightTerms)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: ZSpacing.xs) {
                    if let versionText = content.versionText {
                        LibraryHighlighter.text(versionText, terms: highlightTerms)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Text(entry.record.importedAt, format: .dateTime.year().month().day())
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                if let matchContext {
                    LibraryHighlighter.text(matchContext, terms: highlightTerms)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                HStack(spacing: ZSpacing.xs) {
                    signingBadge(content)
                    if showsSigningInsights {
                        expiryBadge
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        // The row is read as one element: name, identifier, versions, import
        // date, badges — so nothing depends on visual styling alone.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription(content))
        .accessibilityAddTraits(isSelected == true ? .isSelected : [])
        .accessibilityHint(isSelected == nil ? "" : "Double-tap to change the selection")
    }

    @ViewBuilder
    private func signingBadge(_ content: ApplicationLibraryRowContent) -> some View {
        switch signingState {
        case .signed:
            ZStatusBadge("Signed", systemImage: "checkmark.seal.fill", kind: .success)
        case .notSigned:
            ZStatusBadge("Not Signed", systemImage: "circle.dashed", kind: .neutral)
        case .packageProblem:
            ZStatusBadge(content.availabilityText ?? "Package Problem", systemImage: "exclamationmark.triangle.fill", kind: .warning)
        }
    }

    @ViewBuilder
    private var expiryBadge: some View {
        switch expiry {
        case .expiringSoon(let date):
            ZStatusBadge("Expires \(date.formatted(.relative(presentation: .named)))", systemImage: "clock.badge.exclamationmark", kind: .warning)
        case .expired:
            ZStatusBadge("Signing Expired", systemImage: "xmark.circle.fill", kind: .error)
        case .unknown, .valid:
            EmptyView()
        }
    }

    static func expiryDescription(_ expiry: LibraryExpiryStatus) -> String? {
        switch expiry {
        case .expiringSoon(let date):
            return "Signing expires \(date.formatted(.relative(presentation: .named)))"
        case .expired(let date):
            return "Signing expired \(date.formatted(date: .abbreviated, time: .omitted))"
        case .unknown, .valid:
            return nil
        }
    }

    private func accessibilityDescription(_ content: ApplicationLibraryRowContent) -> String {
        var parts: [String] = [content.name]
        if entry.record.isFavorite {
            parts.append("favourite")
        }
        parts.append(content.bundleIdentifier)
        if let version = content.versionText {
            parts.append(version)
        }
        switch signingState {
        case .signed:
            parts.append("signed")
        case .notSigned:
            parts.append("not signed")
        case .packageProblem:
            parts.append(content.availabilityText ?? "package problem")
        }
        switch expiry {
        case .expiringSoon(let date):
            parts.append("signing expires \(date.formatted(.relative(presentation: .named)))")
        case .expired:
            parts.append("signing expired")
        case .unknown, .valid:
            break
        }
        if let matchContext {
            parts.append("matched \(matchContext)")
        }
        return parts.joined(separator: ", ")
    }

    static func == (lhs: ApplicationLibraryRow, rhs: ApplicationLibraryRow) -> Bool {
        lhs.entry.record.id == rhs.entry.record.id &&
        lhs.entry.record.displayName == rhs.entry.record.displayName &&
        lhs.entry.record.isFavorite == rhs.entry.record.isFavorite &&
        lhs.entry.record.importedAt == rhs.entry.record.importedAt &&
        lhs.entry.artifactAvailability == rhs.entry.artifactAvailability &&
        lhs.signingState == rhs.signingState &&
        lhs.expiry == rhs.expiry &&
        lhs.highlightTerms == rhs.highlightTerms &&
        lhs.matchContext == rhs.matchContext &&
        lhs.showsSigningInsights == rhs.showsSigningInsights &&
        lhs.isSelected == rhs.isSelected
    }
}

/// A compact card representation of a library entry used in grid layout mode.
struct ApplicationLibraryCard: View, Equatable {

    let entry: LibraryEntry
    var signingState: ApplicationLibraryModel.SigningState = .notSigned

    /// `nil` outside selection mode; otherwise whether the entry is selected.
    var isSelected: Bool? = nil

    var expiry: LibraryExpiryStatus = .unknown
    var highlightTerms: [String] = []
    var showsSigningInsights = false

    var body: some View {
        let content = ApplicationLibraryRowContent(entry: entry)
        VStack(spacing: ZSpacing.xxs) {
            ZStack(alignment: .topTrailing) {
                ApplicationIconView(
                    artifactID: entry.record.artifact.artifactID,
                    displayName: content.name,
                    bundleIdentifier: content.bundleIdentifier,
                    size: 60
                )
                if entry.record.isFavorite {
                    Image(systemName: "star.fill")
                        .font(.caption2)
                        .foregroundStyle(.yellow)
                        .padding(4)
                        .background(Circle().fill(Color(.systemBackground).opacity(0.85)))
                        .offset(x: 4, y: -4)
                        .accessibilityHidden(true)
                }
                if let isSelected {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isSelected ? Color.accentColor : Color(.tertiaryLabel))
                        .background(Circle().fill(Color(.systemBackground)))
                        .offset(x: 6, y: -6)
                }
            }
            .frame(width: 60, height: 60)
            VStack(spacing: 1) {
                LibraryHighlighter.text(content.name, terms: highlightTerms)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                if let versionText = content.versionText {
                    LibraryHighlighter.text(versionText, terms: highlightTerms)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            signingBadge(content)
            if showsSigningInsights, let expiryText = expiryDescription {
                Text(expiryText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(ZSpacing.xs)
        .frame(maxWidth: .infinity, minHeight: 128)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: ZRadius.card, style: .continuous))
        .overlay {
            if isSelected == true {
                RoundedRectangle(cornerRadius: ZRadius.card, style: .continuous)
                    .stroke(Color.accentColor, lineWidth: 2)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription(content))
        .accessibilityAddTraits(isSelected == true ? .isSelected : [])
        .accessibilityHint(isSelected == nil ? "" : "Double-tap to change the selection")
    }

    @ViewBuilder
    private func signingBadge(_ content: ApplicationLibraryRowContent) -> some View {
        switch signingState {
        case .signed:
            ZStatusBadge("Signed", systemImage: "checkmark.seal.fill", kind: .success)
        case .notSigned:
            EmptyView()
        case .packageProblem:
            ZStatusBadge(content.availabilityText ?? "Package Problem", systemImage: "exclamationmark.triangle.fill", kind: .warning)
        }
    }

    private func accessibilityDescription(_ content: ApplicationLibraryRowContent) -> String {
        var parts: [String] = [content.name]
        if entry.record.isFavorite {
            parts.append("favourite")
        }
        parts.append(content.bundleIdentifier)
        if let version = content.versionText {
            parts.append(version)
        }
        switch signingState {
        case .signed:
            parts.append("signed")
        case .notSigned:
            parts.append("not signed")
        case .packageProblem:
            parts.append(content.availabilityText ?? "package problem")
        }
        if let expiryText = expiryDescription {
            parts.append(expiryText)
        }
        if let matchContext = (highlightTerms.isEmpty ? nil : content.availabilityText) {
            parts.append("matched \(matchContext)")
        }
        return parts.joined(separator: ", ")
    }

    private var expiryDescription: String? {
        switch expiry {
        case .expiringSoon(let date):
            return "Signing expires \(date.formatted(.relative(presentation: .named)))"
        case .expired(let date):
            return "Signing expired \(date.formatted(date: .abbreviated, time: .omitted))"
        case .unknown, .valid:
            return nil
        }
    }

    static func == (lhs: ApplicationLibraryCard, rhs: ApplicationLibraryCard) -> Bool {
        lhs.entry.record.id == rhs.entry.record.id &&
        lhs.entry.record.displayName == rhs.entry.record.displayName &&
        lhs.entry.record.isFavorite == rhs.entry.record.isFavorite &&
        lhs.entry.artifactAvailability == rhs.entry.artifactAvailability &&
        lhs.signingState == rhs.signingState &&
        lhs.isSelected == rhs.isSelected &&
        lhs.expiry == rhs.expiry &&
        lhs.highlightTerms == rhs.highlightTerms &&
        lhs.showsSigningInsights == rhs.showsSigningInsights
    }
}

/// The display values for one library entry.
struct ApplicationLibraryRowContent: Equatable {
    let name: String
    let bundleIdentifier: String
    let versionText: String?
    let availabilityText: String?

    init(entry: LibraryEntry) {
        let record = entry.record
        self.name = record.displayName ?? "Unnamed Application"
        self.bundleIdentifier = record.bundleIdentifier.rawValue

        var versionComponents: [String] = []
        if let short = record.identity.shortVersionString {
            versionComponents.append(short)
        }
        if let build = record.identity.buildVersion, build != record.identity.shortVersionString {
            versionComponents.append("(\(build))")
        }
        if versionComponents.isEmpty {
            self.versionText = nil
        } else {
            self.versionText = "Version " + versionComponents.joined(separator: " ")
        }

        switch entry.artifactAvailability {
        case .available:
            self.availabilityText = nil
        case .missing:
            self.availabilityText = "Package File Missing"
        case .inconsistent:
            self.availabilityText = "Package File Does Not Match Its Record"
        }
    }
}

/// Render-more row for lazy pagination in long library lists.
struct LibraryRenderMoreRow: View {
    let remaining: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: ZSpacing.xs) {
                Spacer()
                Text("Show \(remaining) More")
                    .font(.footnote.weight(.medium))
                Image(systemName: "chevron.down")
                    .font(.caption2)
                Spacer()
            }
            .foregroundStyle(Color.accentColor)
            .padding(.vertical, ZSpacing.xs)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Show \(remaining) more applications")
    }
}

/// Skeleton placeholder row for application loading.
struct LibrarySkeletonRow: View {
    var body: some View {
        HStack(spacing: ZSpacing.sm) {
            RoundedRectangle(cornerRadius: ZRadius.icon)
                .fill(Color(.tertiarySystemFill))
                .frame(width: 52, height: 52)
            VStack(alignment: .leading, spacing: ZSpacing.xxs) {
                RoundedRectangle(cornerRadius: ZRadius.xs).fill(Color(.tertiarySystemFill)).frame(height: 14)
                RoundedRectangle(cornerRadius: ZRadius.xs).fill(Color(.tertiarySystemFill)).frame(height: 10).padding(.trailing, 60)
                RoundedRectangle(cornerRadius: ZRadius.xs).fill(Color(.tertiarySystemFill)).frame(height: 10).padding(.trailing, 120)
            }
            Spacer()
        }
        .redacted(reason: .placeholder)
        .accessibilityHidden(true)
    }
}

/// The loading state: skeletons in the shape of the rows that will replace
/// them, so the screen never presents an empty library as a finding.
struct ApplicationLibraryLoadingView: View {
    var body: some View {
        ScrollView {
            VStack(spacing: ZSpacing.sm) {
                ForEach(0..<6, id: \.self) { _ in
                    ZSkeletonAppRow()
                        .padding(.horizontal)
                        .padding(.vertical, ZSpacing.xxs)
                }
            }
            .padding(.top, ZSpacing.sm)
        }
        .accessibilityLabel("Loading applications")
    }
}

/// The failure state: the library could not be read, and the screen says so
/// instead of showing an empty list.
struct ApplicationLibraryFailureView: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        ZErrorView(
            title: "Library Unavailable",
            explanation: message,
            suggestedAction: "Check device storage or restart ZynSign if the library database is locked.",
            technicalDetails: "ApplicationLibrary database read failure: \(message)",
            onRetry: { retry() }
        )
    }
}

// MARK: - Signing queue toolbar button

/// The Library's way into the signing queue: a toolbar button whose badge
/// counts the jobs running or waiting, so queued work stays visible from
/// the screen the jobs were queued on. `⌘⇧Q` opens it from a keyboard.
struct SigningQueueToolbarButton: View {

    @ObservedObject var queue: SigningQueue
    let action: () -> Void

    private var activeCount: Int {
        queue.jobs.filter { $0.isActive }.count
    }

    var body: some View {
        Button {
            ZHaptics.tap()
            action()
        } label: {
            Label("Signing Queue", systemImage: activeCount > 0 ? "tray.full.fill" : "tray.full")
                .overlay(alignment: .topTrailing) {
                    if activeCount > 0 {
                        Text("\(activeCount)")
                            .font(.caption2.weight(.bold))
                            .monospacedDigit()
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4)
                            .background(Capsule().fill(Color.accentColor))
                            .offset(x: 8, y: -6)
                            .accessibilityHidden(true)
                    }
                }
        }
        .keyboardShortcut("q", modifiers: [.command, .shift])
        .accessibilityLabel("Signing Queue")
        .accessibilityValue(activeCount == 0 ? "No active jobs" : "\(activeCount) active job\(activeCount == 1 ? "" : "s")")
    }
}
