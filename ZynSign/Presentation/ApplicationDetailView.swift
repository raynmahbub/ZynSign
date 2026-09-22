import SwiftUI

/// The detail screen for one application record in the library.
///
/// The screen renders what the persisted record holds: the identity the
/// package declared, the state of the package file ZynSign keeps for it,
/// and the record's import and update information. Nothing is read from
/// storage here and no new conclusions are drawn — the entry the list
/// produced is the whole input, mapped into display values.
///
/// The screen states what a record is and is not: it records what the
/// package declared and that the package passed inspection when it was
/// imported. It is not a statement about signatures, trust, or
/// installability, none of which this build evaluates.
///
/// When the record's package is available, the screen offers the bundle
/// explorer, which lists the bundle's contents read-only. The offer follows
/// the entry's availability as the library derived it; the screen does not
/// re-examine storage to decide whether to show it.
struct ApplicationDetailView: View {

    let entry: LibraryEntry
    private let bundleInspection: IPABundleContentsInspection

    /// Creates the screen for `entry`, with the inspection use case the
    /// bundle explorer runs on.
    init(entry: LibraryEntry, bundleInspection: IPABundleContentsInspection) {
        self.entry = entry
        self.bundleInspection = bundleInspection
    }

    var body: some View {
        let content = ApplicationDetailContent(entry: entry)
        List {
            Section("Application") {
                LabeledContent("Name", value: content.name)
                LabeledContent("Identifier", value: content.bundleIdentifier)
                LabeledContent("Version", value: content.versionText)
                LabeledContent("Build", value: content.buildText)
            }
            Section {
                LabeledContent("Status", value: content.artifactStatus)
                if let explanation = content.artifactExplanation {
                    Text(explanation)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if content.canExploreBundle {
                    NavigationLink {
                        BundleExplorerView(inspection: bundleInspection, entry: entry)
                    } label: {
                        Label("Explore Bundle", systemImage: "folder")
                    }
                    .accessibilityHint("Lists the files and folders inside the application bundle.")
                }
            } header: {
                Text("Package")
            } footer: {
                if content.canExploreBundle {
                    Text("Exploring lists the files and folders inside the application bundle. It reads the package's own records of them and does not open, run, or change any file.")
                }
            }
            Section("Library Record") {
                LabeledContent("Original File", value: content.sourceFileName)
                LabeledContent("Imported") {
                    Text(content.imported, format: Date.FormatStyle(date: .abbreviated, time: .shortened))
                }
                if let updated = content.updated {
                    LabeledContent("Last Updated") {
                        Text(updated, format: Date.FormatStyle(date: .abbreviated, time: .shortened))
                    }
                }
            }
            Section {
                Text("This record states what the package declared and that it passed ZynSign's inspection when it was imported. It is not a statement about signatures, trust, or installability: signing and installation are not part of this build.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(content.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// The detail screen's display values, derived from a library entry.
///
/// The mapping is the only place the record's vocabulary becomes the
/// screen's vocabulary. Absent declarations are shown as em dashes rather
/// than invented, a record that was never updated shows only its import
/// date, and a missing or inconsistent package file is represented
/// explicitly instead of being reported as available.
struct ApplicationDetailContent: Equatable {

    /// The resolved display name, or a neutral placeholder when the
    /// package declared no usable name.
    let name: String

    /// The declared bundle identifier.
    let bundleIdentifier: String

    /// The declared marketing version, or an em dash when undeclared.
    let versionText: String

    /// The declared build version, or an em dash when undeclared.
    let buildText: String

    /// The file name the package was imported from, or an em dash when none
    /// was recorded. A provenance label only, never a path.
    let sourceFileName: String

    /// The current availability of the record's package file.
    let artifactStatus: String

    /// A user-presentable explanation shown when the package file is not
    /// what the record expects, or `nil` when it is available.
    let artifactExplanation: String?

    /// Whether the bundle explorer is offered. True exactly when the
    /// library reports the package available; a missing or inconsistent
    /// package has nothing trustworthy to explore, and the screen shows its
    /// explanation instead.
    let canExploreBundle: Bool

    /// When the record was created.
    let imported: Date

    /// When the record last changed, or `nil` when it never changed after
    /// being created.
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

// MARK: - Previews

/// Synthetic values for the detail previews: invented identifiers, names,
/// versions, and timestamps. No real package appears anywhere.
private enum PreviewFixtures {

    static func identity(
        bundleIdentifier: String,
        displayName: String?,
        shortVersion: String?,
        build: String?
    ) -> ApplicationIdentity {
        guard let identifier = BundleIdentifier(rawValue: bundleIdentifier) else {
            preconditionFailure("Preview fixture bundle identifier is not valid: \(bundleIdentifier)")
        }
        return ApplicationIdentity(
            bundleIdentifier: identifier,
            declaredDisplayName: displayName,
            shortVersionString: shortVersion,
            buildVersion: build
        )
    }

    static func fingerprint(seed: UInt8) -> ArtifactFingerprint {
        guard let fingerprint = ArtifactFingerprint(
            algorithm: .sha256,
            digestBytes: Array(repeating: seed, count: 32)
        ) else {
            preconditionFailure("A 32-byte digest must always form a fingerprint.")
        }
        return fingerprint
    }

    static func record(
        identity: ApplicationIdentity,
        sourceFileName: String?,
        importedAt: Date,
        updatedAt: Date
    ) -> ApplicationRecord {
        ApplicationRecord(
            id: ApplicationRecordIdentifier(),
            identity: identity,
            executableName: nil,
            sourceFileName: sourceFileName,
            artifact: ArtifactReference(
                artifactID: ArtifactIdentifier(),
                byteCount: 4_194_304,
                fingerprint: fingerprint(seed: 0xAB)
            ),
            inspection: ApplicationRecord.InspectionSummary(classification: .valid),
            importedAt: importedAt,
            updatedAt: updatedAt
        )
    }

    static let completeEntry = LibraryEntry(
        record: record(
            identity: identity(
                bundleIdentifier: "com.example.synthetic",
                displayName: "Example",
                shortVersion: "1.2",
                build: "34"
            ),
            sourceFileName: "Example.ipa",
            importedAt: Date(timeIntervalSinceReferenceDate: 750_000_000),
            updatedAt: Date(timeIntervalSinceReferenceDate: 750_000_900)
        ),
        artifactAvailability: .available
    )

    static let missingArtifactEntry = LibraryEntry(
        record: completeEntry.record,
        artifactAvailability: .missing
    )

    static let undeclaredMetadataEntry = LibraryEntry(
        record: record(
            identity: identity(
                bundleIdentifier: "com.example.minimal",
                displayName: nil,
                shortVersion: nil,
                build: nil
            ),
            sourceFileName: nil,
            importedAt: Date(timeIntervalSinceReferenceDate: 750_000_000),
            updatedAt: Date(timeIntervalSinceReferenceDate: 750_000_000)
        ),
        artifactAvailability: .available
    )
}

private let previewEnvironment = CompositionRoot.makeApplicationEnvironment()

#Preview("Application Detail") {
    NavigationStack {
        ApplicationDetailView(
            entry: PreviewFixtures.completeEntry,
            bundleInspection: previewEnvironment.bundleInspection
        )
    }
}

#Preview("Application Detail, Missing Package") {
    NavigationStack {
        ApplicationDetailView(
            entry: PreviewFixtures.missingArtifactEntry,
            bundleInspection: previewEnvironment.bundleInspection
        )
    }
}

#Preview("Application Detail, Undeclared Metadata") {
    NavigationStack {
        ApplicationDetailView(
            entry: PreviewFixtures.undeclaredMetadataEntry,
            bundleInspection: previewEnvironment.bundleInspection
        )
    }
}
