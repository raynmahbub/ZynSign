import Foundation

/// A set of package files prepared for handing to the system share sheet.
struct LibraryExportBundle: Hashable, Sendable, Identifiable {

    /// A fresh identity per export, so the sheet presenting one export is
    /// never mistaken for another.
    let id: UUID

    /// The directory the prepared files live in. Discarded after sharing.
    let directory: URL

    /// The prepared files, one per exported application, named for people.
    let fileURLs: [URL]

    /// How many requested applications had no package file to export.
    let skippedCount: Int
}

/// Prepares library package files for export under readable names.
///
/// The library keeps each package under an identifier ZynSign minted,
/// which is the right name for storage and the wrong one for a person
/// receiving the file. Exporting therefore places, for each requested
/// application, a file named after the application — `Name 1.2 (34).ipa`
/// — in a fresh directory under the export root, and hands those files to
/// the share sheet.
///
/// **No copies where avoidable.** Each prepared file is a hard link to the
/// library's file: instant, and no extra storage for packages that can run
/// to gigabytes. Where a link cannot be made the file is copied instead.
/// Either way the library's own file is only read: nothing is moved,
/// renamed, or modified, and discarding an export removes the prepared
/// names and never the library's bytes.
///
/// **Honest about gaps.** An application whose package file is missing or
/// no longer matches its record is skipped and counted, never exported in
/// its place. When nothing at all can be exported the preparation fails
/// with a typed error rather than presenting an empty share sheet.
struct LibraryExportPreparation: Sendable {

    /// The longest file-name stem produced, in characters.
    static let maximumStemLength = 96

    /// The directory each export gets its own subdirectory in.
    let exportRoot: URL

    /// Where the library keeps the package file for an artifact.
    let artifactLocation: @Sendable (ArtifactIdentifier) -> URL

    init(exportRoot: URL, artifactLocation: @escaping @Sendable (ArtifactIdentifier) -> URL) {
        self.exportRoot = exportRoot
        self.artifactLocation = artifactLocation
    }

    /// Prepares `entries` for export, in the order given.
    func prepare(_ entries: [LibraryEntry]) throws -> LibraryExportBundle {
        let id = UUID()
        let directory = exportRoot.appendingPathComponent(id.uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw ZynSignError.libraryStorageFailure(
                diagnosticDetail: "The export directory could not be created.",
                underlyingError: error
            )
        }

        var usedNames: Set<String> = []
        var prepared: [URL] = []
        var skipped = 0
        for entry in entries {
            let source = artifactLocation(entry.record.artifact.artifactID)
            guard entry.isArtifactAvailable, FileManager.default.fileExists(atPath: source.path) else {
                skipped += 1
                continue
            }
            let name = Self.uniqueName(Self.exportFileName(for: entry.record), avoiding: &usedNames)
            let destination = directory.appendingPathComponent(name, isDirectory: false)
            do {
                try FileManager.default.linkItem(at: source, to: destination)
            } catch {
                do {
                    try FileManager.default.copyItem(at: source, to: destination)
                } catch {
                    skipped += 1
                    continue
                }
            }
            prepared.append(destination)
        }

        guard !prepared.isEmpty else {
            try? FileManager.default.removeItem(at: directory)
            throw ZynSignError.libraryExportUnavailable(
                diagnosticDetail: "None of the \(entries.count) requested entries had a package file that could be prepared."
            )
        }
        return LibraryExportBundle(id: id, directory: directory, fileURLs: prepared, skippedCount: skipped)
    }

    /// Removes the prepared files of `bundle`. The library's own files are
    /// never touched: the prepared files are separate names for them.
    func discard(_ bundle: LibraryExportBundle) {
        // Only a directory directly under the export root is ever removed.
        let parent = bundle.directory.deletingLastPathComponent().standardizedFileURL.path
        guard parent == exportRoot.standardizedFileURL.path else {
            return
        }
        try? FileManager.default.removeItem(at: bundle.directory)
    }

    /// Removes every export left behind, for example by a share sheet the
    /// system tore down without reporting completion.
    func discardAll() {
        try? FileManager.default.removeItem(at: exportRoot)
    }

    // MARK: - Naming

    /// The readable file name for a record's package: the display name (or
    /// bundle identifier), the declared version and build, and the `ipa`
    /// extension. Characters a file system or a recipient could misread are
    /// replaced, and the stem is bounded.
    static func exportFileName(for record: ApplicationRecord) -> String {
        var stem = record.displayName ?? record.bundleIdentifier.rawValue
        switch (record.identity.shortVersionString, record.identity.buildVersion) {
        case (.some(let version), .some(let build)) where version != build:
            stem += " \(version) (\(build))"
        case (.some(let version), _):
            stem += " \(version)"
        case (.none, .some(let build)):
            stem += " (\(build))"
        case (.none, .none):
            break
        }
        return sanitizedStem(stem) + ".ipa"
    }

    /// Replaces path separators, reserved punctuation, and control
    /// characters, collapses whitespace, strips leading dots, and bounds
    /// the length. Never returns an empty stem.
    static func sanitizedStem(_ raw: String) -> String {
        let reserved: Set<Character> = ["/", "\\", ":", "*", "?", "\"", "<", ">", "|"]
        let replaced = String(raw.map { character -> Character in
            if reserved.contains(character) { return "-" }
            if character.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) { return " " }
            return character
        })
        var stem = replaced.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        while stem.hasPrefix(".") {
            stem.removeFirst()
        }
        stem = String(stem.prefix(maximumStemLength)).trimmingCharacters(in: .whitespaces)
        return stem.isEmpty ? "Application" : stem
    }

    /// `name`, or `name` with " 2", " 3", … before the extension, whichever
    /// is not yet in `used`; the result is added to `used`. Compared
    /// case-insensitively, because common file systems are.
    static func uniqueName(_ name: String, avoiding used: inout Set<String>) -> String {
        let base = (name as NSString).deletingPathExtension
        let pathExtension = (name as NSString).pathExtension
        var candidate = name
        var counter = 2
        while used.contains(candidate.lowercased()) {
            candidate = pathExtension.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(pathExtension)"
            counter += 1
        }
        used.insert(candidate.lowercased())
        return candidate
    }
}
