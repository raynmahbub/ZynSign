import SwiftUI
import UIKit

// MARK: - Release gating

/// Which parts of the advanced library the running build exposes.
///
/// The advanced library — scopes and smart collections, collections,
/// stacked filters, the extra orders, statistics, bulk actions beyond
/// deletion, and the quick actions beyond favouriting — ships as
/// `ReleaseFeature.libraryPowerFeatures`. Anything that reads the signing
/// journal (Signed, Unsigned, Recently Signed, Expiring Soon, the Sign
/// action) additionally needs `ReleaseFeature.smartSign`, because signing
/// state means nothing in a release that cannot sign. Debug builds expose
/// everything, like the rest of the release train.
struct LibraryFeatureAvailability: Equatable {

    /// Whether the advanced library is switched on.
    let powerFeatures: Bool

    /// Whether signing is switched on.
    let signing: Bool

    /// The availability the running build's release gate decides.
    static var current: LibraryFeatureAvailability {
        LibraryFeatureAvailability(
            powerFeatures: ReleaseTrain.isAvailable(.libraryPowerFeatures),
            signing: ReleaseTrain.isAvailable(.smartSign)
        )
    }

    /// Whether signing-derived library features are shown.
    var signingInsights: Bool {
        powerFeatures && signing
    }

    func allowsSmartCollection(_ smart: LibrarySmartCollection) -> Bool {
        powerFeatures && (!smart.dependsOnSigning || signing)
    }

    func allowsSortMode(_ mode: LibrarySortMode) -> Bool {
        guard powerFeatures else { return LibrarySortMode.coreModes.contains(mode) }
        return !mode.dependsOnSigning || signing
    }

    func allowsScope(_ scope: LibraryScope) -> Bool {
        switch scope {
        case .all: return true
        case .smart(let smart): return allowsSmartCollection(smart)
        case .collection: return powerFeatures
        }
    }

    /// The orders the sort menu offers.
    var sortModes: [LibrarySortMode] {
        LibrarySortMode.allCases.filter { allowsSortMode($0) }
    }
}

/// The preference keys the library screen remembers, shared with Home so
/// Home can open the library on a scope.
enum LibraryPreferenceKeys {
    static let showsGrid = "zynsign.library.showsGrid"
    static let sortOrder = "zynsign.library.sortOrder"
    static let scope = "zynsign.library.scope"
}

// MARK: - Navigation and sheets

/// A screen pushed from the library.
enum LibraryRoute: Hashable {
    case details(ApplicationRecordIdentifier)
    case sign(ApplicationRecordIdentifier)

    var recordID: ApplicationRecordIdentifier {
        switch self {
        case .details(let id), .sign(let id): return id
        }
    }
}

/// A request to put applications into a collection. When `source` names
/// the collection being viewed, choosing a destination moves them out of it.
struct LibraryCollectionPickerRequest: Identifiable, Equatable {
    let id = UUID()
    let recordIDs: [ApplicationRecordIdentifier]
    let source: LibraryCollectionIdentifier?
}

/// A request to name a new collection or rename an existing one.
struct LibraryCollectionNameRequest: Identifiable, Equatable {
    let id = UUID()
    let mode: LibraryCollectionNameSheet.Mode
}

/// The sheets the library screen presents itself.
enum LibrarySheet: Identifiable {
    case collectionPicker(LibraryCollectionPickerRequest)
    case nameCollection(LibraryCollectionNameRequest)
    case manageCollections

    var id: String {
        switch self {
        case .collectionPicker(let request): return "picker-\(request.id.uuidString)"
        case .nameCollection(let request): return "name-\(request.id.uuidString)"
        case .manageCollections: return "manage"
        }
    }
}

// MARK: - Accessibility

/// Speaks short status changes — selection counts, bulk outcomes — to
/// VoiceOver users, who cannot see the floating bar or a toast change.
@MainActor
enum LibraryAnnouncer {
    static func announce(_ message: String) {
        guard UIAccessibility.isVoiceOverRunning else { return }
        UIAccessibility.post(notification: .announcement, argument: message)
    }
}

// MARK: - Search highlighting

/// Marks where search terms occur in displayed text.
///
/// Matching mirrors the index — case, diacritics, and width are ignored —
/// but runs on the displayed string itself, so the highlighted ranges are
/// exactly the characters the user sees, whatever folding did to lengths.
enum LibraryHighlighter {

    /// One stretch of text and whether it matched a term.
    struct Run: Equatable {
        let text: String
        let isMatch: Bool
    }

    /// Splits `text` into runs, marking every occurrence of any term.
    /// Overlapping and adjacent occurrences merge into one run.
    static func runs(in text: String, terms: [String]) -> [Run] {
        let usable = terms.filter { !$0.isEmpty }
        guard !text.isEmpty, !usable.isEmpty else {
            return [Run(text: text, isMatch: false)]
        }
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]
        var ranges: [Range<String.Index>] = []
        for term in usable {
            var searchStart = text.startIndex
            while searchStart < text.endIndex,
                  let found = text.range(of: term, options: options, range: searchStart..<text.endIndex),
                  !found.isEmpty {
                ranges.append(found)
                searchStart = found.upperBound
            }
        }
        guard !ranges.isEmpty else {
            return [Run(text: text, isMatch: false)]
        }
        ranges.sort { $0.lowerBound < $1.lowerBound }
        var merged: [Range<String.Index>] = []
        for range in ranges {
            if let last = merged.last, range.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else {
                merged.append(range)
            }
        }
        var runs: [Run] = []
        var cursor = text.startIndex
        for range in merged {
            if cursor < range.lowerBound {
                runs.append(Run(text: String(text[cursor..<range.lowerBound]), isMatch: false))
            }
            runs.append(Run(text: String(text[range]), isMatch: true))
            cursor = range.upperBound
        }
        if cursor < text.endIndex {
            runs.append(Run(text: String(text[cursor..<text.endIndex]), isMatch: false))
        }
        return runs
    }

    /// `text` as styled text with every match emphasised and tinted.
    static func attributed(_ text: String, terms: [String]) -> AttributedString {
        var result = AttributedString()
        for run in runs(in: text, terms: terms) {
            var part = AttributedString(run.text)
            if run.isMatch {
                part[AttributeScopes.FoundationAttributes.InlinePresentationIntentAttribute.self] = .stronglyEmphasized
                part[AttributeScopes.SwiftUIAttributes.BackgroundColorAttribute.self] = Color.yellow.opacity(0.35)
            }
            result.append(part)
        }
        return result
    }

    /// `text` as a `Text`, highlighted when there are terms.
    static func text(_ text: String, terms: [String]) -> Text {
        guard !terms.isEmpty else { return Text(verbatim: text) }
        return Text(attributed(text, terms: terms))
    }
}

// MARK: - Share sheet

/// The system share sheet over prepared export files. `onComplete` runs
/// when the user finishes or cancels, so the prepared files can be
/// discarded.
struct LibraryShareSheet: UIViewControllerRepresentable {
    let items: [URL]
    let onComplete: () -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        controller.completionWithItemsHandler = { _, _, _, _ in
            onComplete()
        }
        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

// MARK: - Shared states

/// Shown where an application was pushed but the library no longer holds
/// it — deleted from another screen, for example.
struct LibraryEntryUnavailableView: View {
    var body: some View {
        ZEmptyState(
            title: "Application Unavailable",
            message: "This application is no longer in ZynSign's library. It may have been removed or replaced.",
            systemImage: "questionmark.app",
            tint: .orange
        )
    }
}

/// The empty state for collections.
struct LibraryNoCollectionsView: View {
    var onCreate: (() -> Void)?

    var body: some View {
        ZEmptyState(
            title: "No Custom Collections",
            message: "Create your first collection to group applications by project, workflow, or distribution target.",
            systemImage: "folder.badge.plus",
            tint: .indigo,
            badgeSymbol: "plus",
            primaryActionTitle: onCreate != nil ? "New Collection" : nil,
            primaryAction: onCreate
        )
    }
}
