import SwiftUI

/// One directory of an application bundle, listed from an already loaded
/// `BundleContents` value.
///
/// The view is a pure rendering of the value it is given: it looks entries
/// up in the loaded structure and never reads the package, the library, or
/// any filesystem. Descending into a directory pushes another instance over
/// the same value, so the whole bundle can be browsed from the single read
/// the explorer performed. Tapping a regular file, link, or unsupported
/// entry shows the entry's recorded metadata; nothing opens, previews, or
/// changes the object it describes.
struct BundleDirectoryView: View {

    let contents: BundleContents
    let directory: BundlePath

    var body: some View {
        let listing = BundleDirectoryListingContent(contents: contents, directory: directory)
        Group {
            if listing.entries.isEmpty {
                BundleDirectoryEmptyView()
            } else {
                list(for: listing)
            }
        }
        .navigationTitle(listing.title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func list(for listing: BundleDirectoryListingContent) -> some View {
        List {
            if !listing.notableEntries.isEmpty {
                Section {
                    ForEach(listing.notableEntries, id: \.path) { entry in
                        row(for: entry)
                    }
                } header: {
                    Text("Notable Entries")
                } footer: {
                    Text(BundleDirectoryListingContent.notableEntriesNote)
                }
            }
            Section {
                ForEach(listing.entries, id: \.path) { entry in
                    row(for: entry)
                }
            } header: {
                Text(listing.entriesHeader)
            } footer: {
                VStack(alignment: .leading, spacing: 8) {
                    if let location = listing.locationText {
                        Text(location)
                    }
                    Text(listing.itemCountText)
                    if let omitted = listing.omittedEntriesText {
                        Text(omitted)
                    }
                }
            }
        }
    }

    private func row(for entry: BundleEntry) -> some View {
        let rowContent = BundleEntryRowContent(entry: entry, childCount: contents.childCount(of: entry.path))
        return NavigationLink {
            if entry.isDirectory {
                BundleDirectoryView(contents: contents, directory: entry.path)
            } else {
                BundleEntryDetailView(entry: entry)
            }
        } label: {
            BundleEntryRow(content: rowContent)
        }
    }
}

// MARK: - Row

/// One bundle entry in a directory listing: its kind as a symbol, its name,
/// and one line of recorded metadata — what it conventionally is, how many
/// items a directory holds, or how many bytes a file declares.
struct BundleEntryRow: View {

    let content: BundleEntryRowContent

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: content.symbolName)
                .foregroundStyle(content.isDirectory ? Color.accentColor : Color.secondary)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(content.name)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                HStack(spacing: 4) {
                    Text(content.detailText)
                    if let byteCount = content.byteCount {
                        Text("·")
                        Text(Int64(byteCount), format: .byteCount(style: .file))
                    }
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        }
        // The row is read as one element: name, kind, role, and size, so
        // nothing depends on the symbol alone.
        .accessibilityElement(children: .combine)
        .accessibilityLabel(content.accessibilityLabel)
    }
}

/// The display values for one entry row, derived from the entry and the
/// number of items a directory holds.
///
/// Symbolic links and unsupported entries are named as such in words, not
/// only by symbol, and are never presented as something that can be opened
/// or followed. A role, when the entry has one, is shown as a description of
/// the location; the note beneath the notable entries says what such a
/// description is and is not.
struct BundleEntryRowContent: Equatable {

    /// The entry's own name.
    let name: String

    /// The SF Symbol for the entry's kind.
    let symbolName: String

    /// Whether the row leads into a directory listing.
    let isDirectory: Bool

    /// One line beneath the name: the role when the entry has one, the
    /// item count for a directory, or the kind for everything else.
    let detailText: String

    /// The byte count the package declares for a regular file, or `nil`.
    /// Formatted by the view, so tests can assert the number.
    let byteCount: Int?

    /// The row's spoken description.
    let accessibilityLabel: String

    init(entry: BundleEntry, childCount: Int?) {
        let name = entry.name
        let kindText = Self.kindText(for: entry.kind)
        self.name = name
        self.isDirectory = entry.isDirectory
        self.symbolName = Self.symbolName(for: entry.kind)
        self.byteCount = entry.declaredByteCount

        var details: [String] = []
        if let role = entry.role {
            details.append(role.displayName)
        }
        if entry.isDirectory {
            details.append(Self.itemCountText(for: childCount ?? 0))
        } else if entry.role == nil || entry.kind != .regularFile {
            details.append(kindText)
        }
        self.detailText = details.joined(separator: " · ")

        var label = "\(name), \(kindText)"
        if let role = entry.role {
            label += ", \(role.displayName)"
        }
        if entry.isDirectory {
            label += ", \(Self.itemCountText(for: childCount ?? 0))"
        }
        self.accessibilityLabel = label
    }

    /// The user-facing name of an entry kind.
    static func kindText(for kind: ArchiveEntryKind) -> String {
        switch kind {
        case .directory: return "Folder"
        case .regularFile: return "File"
        case .symbolicLink: return "Symbolic link"
        case .unsupported: return "Unsupported entry"
        }
    }

    /// The SF Symbol for an entry kind.
    static func symbolName(for kind: ArchiveEntryKind) -> String {
        switch kind {
        case .directory: return "folder"
        case .regularFile: return "doc"
        case .symbolicLink: return "link"
        case .unsupported: return "questionmark.square.dashed"
        }
    }

    /// A count of items in words, pluralised by hand so the text is the
    /// same on every device.
    static func itemCountText(for count: Int) -> String {
        count == 1 ? "1 item" : "\(count) items"
    }
}

// MARK: - Listing content

/// The display values for one directory listing, derived from the loaded
/// structure and the directory being shown.
///
/// The bundle root additionally surfaces the conventionally significant
/// entries, so that the information file, the executable, the code
/// signature directory, and the like can be found without scrolling through
/// every resource. They are the same entries the full listing shows; the
/// section is a shortcut, not a second source.
struct BundleDirectoryListingContent: Equatable {

    /// The screen title: the bundle's name at the root, otherwise the
    /// directory's own name.
    let title: String

    /// The directory's location relative to the bundle root, or `nil` at
    /// the root.
    let locationText: String?

    /// The header of the full listing.
    let entriesHeader: String

    /// The entries in the directory, in listing order.
    let entries: [BundleEntry]

    /// The conventionally significant entries, shown at the root only.
    let notableEntries: [BundleEntry]

    /// How many items the directory holds, in words.
    let itemCountText: String

    /// A note about package entries that could not be listed, shown at the
    /// root when there are any; otherwise `nil`.
    let omittedEntriesText: String?

    init(contents: BundleContents, directory: BundlePath) {
        let entries = contents.entries(in: directory) ?? []
        self.entries = entries
        self.itemCountText = BundleEntryRowContent.itemCountText(for: entries.count)
        if directory.isRoot {
            self.title = contents.bundleName
            self.locationText = nil
            self.entriesHeader = "Bundle Contents"
            self.notableEntries = contents.notableEntries
            self.omittedEntriesText = contents.omittedEntryCount > 0
                ? Self.omittedEntriesText(for: contents.omittedEntryCount)
                : nil
        } else {
            self.title = directory.name ?? contents.bundleName
            self.locationText = directory.rawValue
            self.entriesHeader = "Contents"
            self.notableEntries = []
            self.omittedEntriesText = nil
        }
    }

    /// The note beneath the notable entries: what a label is and is not.
    static let notableEntriesNote = "These labels describe what a file at a conventional location usually is. They are drawn from names alone: nothing here has been opened, and the presence of a signature directory or a provisioning profile is not evidence that the application is signed, trusted, or installable."

    /// The note for package entries whose names failed the safety rules.
    static func omittedEntriesText(for count: Int) -> String {
        let noun = count == 1 ? "entry" : "entries"
        return "\(count) \(noun) in the package could not be listed because the recorded name did not pass ZynSign's path safety rules."
    }
}

// MARK: - Empty presentation

/// The presentation for a directory that holds nothing. Shown only after
/// the bundle has been read, so it is a finding and never a placeholder.
struct BundleDirectoryEmptyView: View {

    var body: some View {
        ContentUnavailableView {
            Label("Empty Folder", systemImage: "folder")
        } description: {
            Text("The package records nothing inside this folder.")
        }
    }
}
