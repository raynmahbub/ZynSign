import SwiftUI

/// The recorded metadata of one bundle entry that is not a directory: its
/// name, its location relative to the bundle root, its kind, and the byte
/// count the package declares for it.
///
/// This is a metadata screen, not a viewer. It shows what the package
/// records about the entry and offers no way to open, preview, export, or
/// change it. A symbolic link is shown as a link with no target, because
/// the target is content the explorer never reads; an unsupported entry is
/// shown as such and left alone.
struct BundleEntryDetailView: View {

    let entry: BundleEntry

    var body: some View {
        let content = BundleEntryDetailContent(entry: entry)
        List {
            Section("Entry") {
                LabeledContent("Name") {
                    Text(content.name)
                        .multilineTextAlignment(.trailing)
                }
                LabeledContent("Location") {
                    Text(content.locationText)
                        .multilineTextAlignment(.trailing)
                }
                LabeledContent("Kind", value: content.kindText)
                if let byteCount = content.byteCount {
                    LabeledContent("Declared Size") {
                        Text(Int64(byteCount), format: .byteCount(style: .file))
                    }
                }
            }
            if let roleTitle = content.roleTitle, let explanation = content.roleExplanation {
                Section(roleTitle) {
                    Text(explanation)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Section {
                Text(content.kindNote)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(content.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// The display values for one entry's metadata screen.
struct BundleEntryDetailContent: Equatable {

    /// The entry's own name.
    let name: String

    /// The entry's location relative to the bundle root.
    let locationText: String

    /// The user-facing name of the entry's kind.
    let kindText: String

    /// The byte count the package declares for a regular file, or `nil`.
    let byteCount: Int?

    /// The role's label, when the entry's location has one.
    let roleTitle: String?

    /// The role's explanation, when the entry's location has one.
    let roleExplanation: String?

    /// What the explorer does and does not do with an entry of this kind.
    let kindNote: String

    init(entry: BundleEntry) {
        self.name = entry.name
        self.locationText = entry.path.rawValue
        self.kindText = BundleEntryRowContent.kindText(for: entry.kind)
        self.byteCount = entry.declaredByteCount
        self.roleTitle = entry.role?.displayName
        self.roleExplanation = entry.role?.explanation
        self.kindNote = Self.kindNote(for: entry.kind)
    }

    /// The note for an entry kind: a statement of the explorer's boundary.
    static func kindNote(for kind: ArchiveEntryKind) -> String {
        switch kind {
        case .directory:
            return "ZynSign lists what the package records inside this folder and does not open or change any of it."
        case .regularFile:
            return "ZynSign lists this file as the package records it. The size is the package's declaration and has not been verified; the file has not been opened, read, or changed."
        case .symbolicLink:
            return "This entry is a symbolic link. ZynSign lists it and does not read or follow it, so no target is shown and the link cannot lead outside the bundle."
        case .unsupported:
            return "This entry has a form ZynSign does not model. It is listed so that nothing in the bundle is concealed, and it is otherwise left alone."
        }
    }
}
