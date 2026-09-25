import Foundation

/// Bounds for one explicit, read-only preview.
///
/// Structure listing never uses these. A preview reads one entry, or the few
/// small metadata files a framework or extension page names, and never raises
/// the archive policy's own ceiling.
enum ExplorerReadBounds {
    static let textBytes = 256 * 1_024
    static let machoPrefixBytes = 256 * 1_024
    static let imageBytes = 4 * 1_024 * 1_024
    static let propertyListBytes = 1 * 1_024 * 1_024
    static let profileBytes = 1 * 1_024 * 1_024
    static let maximumEntitlementLines = 40
    static let maximumPropertyListFields = 48
    static let maximumTextCharacters = 120_000
    static let maximumValueCharacters = 120
}

/// On-demand, read-only inspection of one bundle entry.
///
/// The bundle explorer's structure listing still reads no file bytes. This
/// use case runs only when the user opens a file, a framework, or an
/// extension. It reads through the same archive boundary import uses, closes
/// the reader on every path, and has no write, extract, sign, or execute
/// operation. A Mach-O page is a header prefix, not a load of the executable.
/// A profile page is a declared property list, not a verification.
struct IPABundleEntryInspection {

    private let library: ApplicationLibrary
    private let readerProvider: any ArtifactArchiveReaderProvider
    private let limits: ArchiveLimits

    init(
        library: ApplicationLibrary,
        readerProvider: any ArtifactArchiveReaderProvider,
        limits: ArchiveLimits = .default
    ) {
        self.library = library
        self.readerProvider = readerProvider
        self.limits = limits
    }

    /// Inspects `entry` inside the package recorded for `id`.
    ///
    /// Throws only when the library record or the package cannot be opened.
    /// A single unreadable entry becomes an unavailable preview so the rest
    /// of the explorer stays usable. Cancellation is passed through.
    func preview(
        recordWithID id: ApplicationRecordIdentifier,
        contents: BundleContents,
        entry: BundleEntry
    ) async throws -> ExplorerEntryInspection {
        try Task.checkCancellation()
        let classification = BundleFileClassification.recognize(entry)
        switch entry.kind {
        case .symbolicLink:
            return Self.make(
                entry: entry,
                contents: contents,
                classification: classification,
                body: .unavailable(
                    title: "Symbolic Link",
                    message: "This entry is a symbolic link. ZynSign lists it and does not read or follow it, so no target is shown."
                )
            )
        case .unsupported:
            return Self.make(
                entry: entry,
                contents: contents,
                classification: classification,
                body: .unavailable(
                    title: "Unsupported Entry",
                    message: "This entry has a form ZynSign does not model. It is listed so nothing is concealed, and it is otherwise left alone."
                )
            )
        case .directory:
            if classification == .framework || classification == .appExtension {
                return try await inspectBundlePage(recordWithID: id, contents: contents, entry: entry, classification: classification)
            }
            return Self.make(
                entry: entry,
                contents: contents,
                classification: classification,
                body: .unavailable(
                    title: "Folder",
                    message: "Folders are listed in the tree. Opening a folder does not read the files inside it."
                )
            )
        case .regularFile:
            return try await inspectFile(recordWithID: id, contents: contents, entry: entry, classification: classification)
        }
    }

    /// The user-presentable message for a failure that prevented the package
    /// from being opened. Foreign errors are never rendered verbatim.
    static func failureMessage(for error: any Error) -> String {
        if let zynSignError = error as? ZynSignError {
            return zynSignError.userMessage
        }
        return "This file could not be previewed."
    }

    // MARK: - Files

    private func inspectFile(
        recordWithID id: ApplicationRecordIdentifier,
        contents: BundleContents,
        entry: BundleEntry,
        classification: BundleFileClassification
    ) async throws -> ExplorerEntryInspection {
        let opened = try await open(recordWithID: id)
        defer { opened.reader.close() }
        try Task.checkCancellation()
        guard let archivePath = Self.archivePath(for: entry.path, within: opened.bundlePath) else {
            return Self.unavailable(entry: entry, contents: contents, classification: classification, title: "Preview Unavailable", message: "This location is not a readable path inside the bundle.")
        }
        do {
            switch classification {
            case .image:
                return try inspectImage(reader: opened.reader, table: opened.table, archivePath: archivePath, entry: entry, contents: contents, classification: classification)
            case .provisioningProfile:
                return try inspectProfileFile(reader: opened.reader, table: opened.table, archivePath: archivePath, entry: entry, contents: contents, classification: classification)
            case .metadata, .propertyList, .text:
                return try inspectTextFile(reader: opened.reader, table: opened.table, archivePath: archivePath, entry: entry, contents: contents, classification: classification)
            case .executable, .generic, .assetCatalog, .framework, .appExtension, .folder, .localization, .symbolicLink, .unsupported:
                return try inspectOpaqueFile(reader: opened.reader, table: opened.table, archivePath: archivePath, entry: entry, contents: contents, classification: classification)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return Self.unavailable(
                entry: entry,
                contents: contents,
                classification: classification,
                title: "Preview Unavailable",
                message: Self.failureMessage(for: error)
            )
        }
    }

    private func inspectImage(
        reader: any ArchiveReader,
        table: [ArchiveEntry],
        archivePath: ArchivePath,
        entry: BundleEntry,
        contents: BundleContents,
        classification: BundleFileClassification
    ) throws -> ExplorerEntryInspection {
        let maximum = bound(ExplorerReadBounds.imageBytes)
        guard (entry.declaredByteCount ?? 0) <= maximum else {
            return Self.unavailable(
                entry: entry,
                contents: contents,
                classification: classification,
                title: "Image Too Large",
                message: "This image is larger than the preview limit. It was not read, and nothing was changed."
            )
        }
        guard let read = try readRegularFile(reader: reader, table: table, path: archivePath, maximumBytes: maximum) else {
            return Self.unavailable(entry: entry, contents: contents, classification: classification, title: "Preview Unavailable", message: "The package does not record this image as a regular file.")
        }
        return Self.make(
            entry: entry,
            contents: contents,
            classification: classification,
            body: .image(ExplorerImagePreview(data: read.data, checksumVerified: read.checksumVerified))
        )
    }

    private func inspectProfileFile(
        reader: any ArchiveReader,
        table: [ArchiveEntry],
        archivePath: ArchivePath,
        entry: BundleEntry,
        contents: BundleContents,
        classification: BundleFileClassification
    ) throws -> ExplorerEntryInspection {
        guard let read = try readRegularFile(reader: reader, table: table, path: archivePath, maximumBytes: bound(ExplorerReadBounds.profileBytes)) else {
            return Self.unavailable(entry: entry, contents: contents, classification: classification, title: "Preview Unavailable", message: "The package does not record this profile as a regular file.")
        }
        let summary = Self.profileSummary(from: read.data)
        return Self.make(entry: entry, contents: contents, classification: classification, body: .profile(summary))
    }

    private func inspectTextFile(
        reader: any ArchiveReader,
        table: [ArchiveEntry],
        archivePath: ArchivePath,
        entry: BundleEntry,
        contents: BundleContents,
        classification: BundleFileClassification
    ) throws -> ExplorerEntryInspection {
        let maximum = classification == .text ? bound(ExplorerReadBounds.textBytes) : bound(ExplorerReadBounds.propertyListBytes)
        guard let read = try readRegularFile(reader: reader, table: table, path: archivePath, maximumBytes: maximum) else {
            return Self.unavailable(entry: entry, contents: contents, classification: classification, title: "Preview Unavailable", message: "The package does not record this file as a regular file.")
        }
        let truncated = !read.checksumVerified || read.data.count < (entry.declaredByteCount ?? read.data.count)
        let preview = Self.textPreview(from: read.data, classification: classification, truncated: truncated, checksumVerified: read.checksumVerified)
        return Self.make(entry: entry, contents: contents, classification: classification, body: .text(preview))
    }

    private func inspectOpaqueFile(
        reader: any ArchiveReader,
        table: [ArchiveEntry],
        archivePath: ArchivePath,
        entry: BundleEntry,
        contents: BundleContents,
        classification: BundleFileClassification
    ) throws -> ExplorerEntryInspection {
        let maximum = bound(ExplorerReadBounds.machoPrefixBytes)
        guard let read = try readRegularFile(reader: reader, table: table, path: archivePath, maximumBytes: maximum) else {
            return Self.unavailable(entry: entry, contents: contents, classification: classification, title: "Preview Unavailable", message: "The package does not record this file as a regular file.")
        }
        if let report = MachOPrefixInspector.inspect(
            prefix: read.data,
            declaredByteCount: entry.declaredByteCount,
            checksumVerified: read.checksumVerified
        ) {
            return Self.make(entry: entry, contents: contents, classification: classification, body: .macho(report))
        }
        if Self.looksLikeText(read.data) {
            let preview = Self.textPreview(
                from: read.data,
                classification: .text,
                truncated: !read.checksumVerified,
                checksumVerified: read.checksumVerified
            )
            return Self.make(entry: entry, contents: contents, classification: classification, body: .text(preview))
        }
        return Self.make(
            entry: entry,
            contents: contents,
            classification: classification,
            body: .binary(ExplorerBinaryFacts(
                readByteCount: read.data.count,
                checksumVerified: read.checksumVerified,
                message: "A bounded prefix was inspected. It is not text, an image, or a Mach-O image, so there is no preview. Nothing was changed."
            ))
        )
    }

    // MARK: - Frameworks and extensions

    private func inspectBundlePage(
        recordWithID id: ApplicationRecordIdentifier,
        contents: BundleContents,
        entry: BundleEntry,
        classification: BundleFileClassification
    ) async throws -> ExplorerEntryInspection {
        let opened = try await open(recordWithID: id)
        defer { opened.reader.close() }
        try Task.checkCancellation()
        let fresh = BundleContents(
            entryTable: opened.table,
            bundlePath: opened.bundlePath,
            declaredExecutableName: nil
        )
        guard fresh.entry(at: entry.path) != nil else {
            return Self.unavailable(
                entry: entry,
                contents: contents,
                classification: classification,
                title: "Preview Unavailable",
                message: "This folder is no longer recorded in the package."
            )
        }
        let plist = try readPropertyList(reader: opened.reader, table: opened.table, directory: entry.path, within: opened.bundlePath)
        if classification == .framework {
            let report = try frameworkReport(reader: opened.reader, table: opened.table, bundlePath: opened.bundlePath, entry: entry, contents: fresh, plist: plist)
            return Self.make(entry: entry, contents: contents, classification: classification, body: .framework(report))
        }
        let report = try extensionReport(reader: opened.reader, table: opened.table, bundlePath: opened.bundlePath, entry: entry, contents: fresh, plist: plist)
        return Self.make(entry: entry, contents: contents, classification: classification, body: .appExtension(report))
    }

    private func frameworkReport(
        reader: any ArchiveReader,
        table: [ArchiveEntry],
        bundlePath: ArchivePath,
        entry: BundleEntry,
        contents: BundleContents,
        plist: [String: Any]?
    ) throws -> ExplorerFrameworkReport {
        let executable = Self.executable(in: entry, contents: contents, plist: plist, suffix: ".framework")
        let signature = try signaturePresence(reader: reader, table: table, bundlePath: bundlePath, executable: executable)
        var note = ExplorerSignaturePresence.disclaimer
        if plist == nil {
            note += " Version was not read from an information file."
        }
        if executable == nil {
            note += " No executable file was found under the conventional name."
        }
        return ExplorerFrameworkReport(
            name: entry.name,
            version: Self.string("CFBundleShortVersionString", in: plist),
            build: Self.string("CFBundleVersion", in: plist),
            bundleIdentifier: Self.string("CFBundleIdentifier", in: plist),
            executableName: executable?.name,
            executablePath: executable?.path,
            signature: signature,
            declaredByteCount: ExplorerMeasurements.declaredByteCount(within: entry.path, contents: contents),
            path: entry.path,
            note: note
        )
    }

    private func extensionReport(
        reader: any ArchiveReader,
        table: [ArchiveEntry],
        bundlePath: ArchivePath,
        entry: BundleEntry,
        contents: BundleContents,
        plist: [String: Any]?
    ) throws -> ExplorerExtensionReport {
        let executable = Self.executable(in: entry, contents: contents, plist: plist, suffix: ".appex")
        let point = Self.extensionPoint(in: plist)
        let entitlements = try entitlementSummary(reader: reader, table: table, directory: entry.path, within: bundlePath)
        return ExplorerExtensionReport(
            name: entry.name,
            kind: ExplorerExtensionKind.recognize(pointIdentifier: point),
            bundleIdentifier: Self.string("CFBundleIdentifier", in: plist),
            executableName: executable?.name,
            executablePath: executable?.path,
            version: Self.string("CFBundleShortVersionString", in: plist),
            path: entry.path,
            entitlementLines: entitlements.lines,
            entitlementsTruncated: entitlements.truncated,
            entitlementsNote: entitlements.note
        )
    }

    private func signaturePresence(
        reader: any ArchiveReader,
        table: [ArchiveEntry],
        bundlePath: ArchivePath,
        executable: BundleEntry?
    ) throws -> ExplorerSignaturePresence {
        guard let executable,
              let archivePath = Self.archivePath(for: executable.path, within: bundlePath) else {
            return .unreadable
        }
        do {
            guard let read = try readRegularFile(
                reader: reader,
                table: table,
                path: archivePath,
                maximumBytes: bound(ExplorerReadBounds.machoPrefixBytes)
            ) else {
                return .unreadable
            }
            guard let report = MachOPrefixInspector.inspect(
                prefix: read.data,
                declaredByteCount: executable.declaredByteCount,
                checksumVerified: read.checksumVerified
            ) else {
                return .unreadable
            }
            let values = report.slices.map(\.signature)
            if values.contains(.commandPresent) { return .commandPresent }
            if values.contains(.commandAbsent) && values.allSatisfy({ $0 == .commandAbsent }) { return .commandAbsent }
            return .unreadable
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return .unreadable
        }
    }

    private func entitlementSummary(
        reader: any ArchiveReader,
        table: [ArchiveEntry],
        directory: BundlePath,
        within bundlePath: ArchivePath
    ) throws -> (lines: [ExplorerEntitlementLine], truncated: Bool, note: String) {
        guard let profilePath = directory.appending(component: IPALayout.embeddedProvisioningProfileFileName),
              let archivePath = Self.archivePath(for: profilePath, within: bundlePath) else {
            return ([], false, "No embedded profile was recorded in this extension. Entitlements were not taken from the executable.")
        }
        do {
            guard let read = try readRegularFile(
                reader: reader,
                table: table,
                path: archivePath,
                maximumBytes: bound(ExplorerReadBounds.profileBytes)
            ) else {
                return ([], false, "No embedded profile was recorded as a regular file. Entitlements were not taken from the executable.")
            }
            let summary = Self.profileSummary(from: read.data)
            if summary.entitlementLines.isEmpty && summary.name == nil && summary.teamIdentifiers.isEmpty {
                return ([], false, summary.note)
            }
            return (summary.entitlementLines, summary.entitlementsTruncated, summary.note)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return ([], false, "The embedded profile could not be read. Entitlements were not taken from the executable.")
        }
    }

    // MARK: - Opening

    private struct OpenedPackage {
        let reader: any ArchiveReader
        let bundlePath: ArchivePath
        let table: [ArchiveEntry]
    }

    private func open(recordWithID id: ApplicationRecordIdentifier) async throws -> OpenedPackage {
        do {
            try Task.checkCancellation()
            guard let libraryEntry = try await library.entry(withID: id) else {
                throw ZynSignError.libraryRecordNotFound(
                    diagnosticDetail: "No record '\(id.rawValue)' exists to preview."
                )
            }
            switch libraryEntry.artifactAvailability {
            case .available:
                break
            case .missing:
                throw ZynSignError.bundleArtifactMissing(
                    diagnosticDetail: "The library holds no artifact for record '\(id.rawValue)'."
                )
            case .inconsistent(let recorded, let observed):
                throw ZynSignError.bundleArtifactInconsistent(
                    diagnosticDetail: "Artifact for record '\(id.rawValue)' holds \(observed) bytes; the record expects \(recorded)."
                )
            }
            let reader = try readerProvider.archiveReader(for: libraryEntry.record.artifact.artifactID)
            do {
                let table = try reader.readEntryTable()
                try Task.checkCancellation()
                switch ApplicationBundleDiscovery.discover(in: table).outcome {
                case .exactlyOne(let bundlePath):
                    return OpenedPackage(reader: reader, bundlePath: bundlePath, table: table)
                case .ambiguous(let candidates):
                    reader.close()
                    throw ZynSignError.ambiguousArtifact(
                        diagnosticDetail: "The package for record '\(id.rawValue)' holds \(candidates.count) application bundles."
                    )
                case .missingPayloadDirectory, .none:
                    reader.close()
                    throw ZynSignError.missingApplicationBundle(
                        diagnosticDetail: "The package for record '\(id.rawValue)' holds no application bundle."
                    )
                }
            } catch {
                reader.close()
                throw error
            }
        } catch {
            throw Self.normalized(error)
        }
    }

    private func readRegularFile(
        reader: any ArchiveReader,
        table: [ArchiveEntry],
        path: ArchivePath,
        maximumBytes: Int
    ) throws -> (data: Data, checksumVerified: Bool)? {
        guard let recorded = table.first(where: { $0.path == path }) else { return nil }
        guard recorded.kind == .regularFile else { return nil }
        let maximum = bound(maximumBytes)
        if recorded.uncompressedSize <= maximum && recorded.compressedSize <= maximum {
            let data = try reader.readEntryData(at: path, maximumBytes: maximum)
            return (data, data.count == recorded.uncompressedSize)
        }
        let data = try reader.readEntryPrefix(at: path, maximumBytes: maximum)
        return (data, false)
    }

    private func readPropertyList(
        reader: any ArchiveReader,
        table: [ArchiveEntry],
        directory: BundlePath,
        within bundlePath: ArchivePath
    ) throws -> [String: Any]? {
        guard let relative = directory.appending(component: IPALayout.bundleInformationFileName),
              let archivePath = Self.archivePath(for: relative, within: bundlePath) else {
            return nil
        }
        do {
            guard let read = try readRegularFile(
                reader: reader,
                table: table,
                path: archivePath,
                maximumBytes: bound(ExplorerReadBounds.propertyListBytes)
            ), read.checksumVerified else {
                return nil
            }
            return Self.propertyListRoot(read.data)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return nil
        }
    }

    private func bound(_ requested: Int) -> Int {
        min(max(0, requested), limits.maximumInspectionReadBytes)
    }

    private static func normalized(_ error: any Error) -> any Error {
        if error is ZynSignError || error is CancellationError {
            return error
        }
        return ZynSignError.bundleInspectionFailure(
            diagnosticDetail: "Entry preview failed with \(String(describing: type(of: error))).",
            underlyingError: error
        )
    }

    // MARK: - Decoding

    private static func textPreview(
        from data: Data,
        classification: BundleFileClassification,
        truncated: Bool,
        checksumVerified: Bool
    ) -> ExplorerTextPreview {
        if classification == .metadata || classification == .propertyList || Self.looksLikePropertyList(data),
           let root = propertyListRoot(data) {
            let text = propertyListText(from: root)
            let (shown, cut) = clip(text)
            return ExplorerTextPreview(
                text: shown,
                kind: .propertyList,
                truncated: truncated || cut || root.count > ExplorerReadBounds.maximumPropertyListFields,
                byteCount: data.count,
                checksumVerified: checksumVerified
            )
        }
        let extensionHint = classification == .text
        if let json = jsonText(from: data), extensionHint || Self.looksLikeJSON(data) {
            let (shown, cut) = clip(json)
            return ExplorerTextPreview(text: shown, kind: .json, truncated: truncated || cut, byteCount: data.count, checksumVerified: checksumVerified)
        }
        let raw = String(data: data, encoding: .utf8) ?? ""
        let kind: ExplorerTextPreview.Kind = (classification == .text && (raw.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<"))) || raw.hasPrefix("<?xml") || raw.hasPrefix("<")
            ? .xml
            : .plain
        let (shown, cut) = clip(raw.isEmpty ? "This file did not decode as text." : raw)
        return ExplorerTextPreview(
            text: shown,
            kind: raw.isEmpty ? .plain : kind,
            truncated: truncated || cut || raw.isEmpty,
            byteCount: data.count,
            checksumVerified: checksumVerified
        )
    }

    private static func profileSummary(from data: Data) -> ExplorerProfileSummary {
        let payload = unwrappedProfilePayload(data) ?? data
        guard let root = propertyListRoot(payload) else {
            return ExplorerProfileSummary(
                name: nil,
                teamIdentifiers: [],
                expiration: nil,
                expirationFallback: nil,
                entitlementLines: [],
                entitlementsTruncated: false,
                note: "The profile could not be read as a property list. It was not verified, and nothing was changed."
            )
        }
        let entitlements = (root["Entitlements"] as? [String: Any]) ?? [:]
        let lines = entitlementLines(from: entitlements)
        let expiration = root["ExpirationDate"] as? Date
        let expirationFallback = expiration == nil ? string("ExpirationDate", in: root) : nil
        return ExplorerProfileSummary(
            name: string("Name", in: root),
            teamIdentifiers: stringList("TeamIdentifier", in: root),
            expiration: expiration,
            expirationFallback: expirationFallback,
            entitlementLines: lines.lines,
            entitlementsTruncated: lines.truncated,
            note: ExplorerProfileSummary.unverifiedNote
        )
    }

    private static func unwrappedProfilePayload(_ data: Data) -> Data? {
        guard data.first == 0x30 else { return nil }
        guard let structure = try? CMSStructureReader.read(data) else { return nil }
        return structure.encapsulatedContent
    }

    private static func propertyListRoot(_ data: Data) -> [String: Any]? {
        var format = PropertyListSerialization.PropertyListFormat.xml
        guard let root = try? PropertyListSerialization.propertyList(from: data, options: [], format: &format),
              format != .openStep,
              let dictionary = root as? [String: Any] else {
            return nil
        }
        return dictionary
    }

    private static func propertyListText(from root: [String: Any]) -> String {
        let keys = root.keys.sorted { $0.unicodeScalars.lexicographicallyPrecedes($1.unicodeScalars) }
        let shown = keys.prefix(ExplorerReadBounds.maximumPropertyListFields)
        var lines = shown.map { key in "\(key): \(valueText(root[key] as Any))" }
        if keys.count > shown.count {
            lines.append("… \(keys.count - shown.count) more keys")
        }
        return lines.joined(separator: "\n")
    }

    private static func entitlementLines(from values: [String: Any]) -> (lines: [ExplorerEntitlementLine], truncated: Bool) {
        let keys = values.keys.sorted { $0.unicodeScalars.lexicographicallyPrecedes($1.unicodeScalars) }
        let shown = keys.prefix(ExplorerReadBounds.maximumEntitlementLines)
        let lines = shown.map { ExplorerEntitlementLine(key: $0, valueText: valueText(values[$0] as Any)) }
        return (lines, keys.count > shown.count)
    }

    private static func jsonText(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return nil }
        if JSONSerialization.isValidJSONObject(object),
           let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
           pretty.count <= ExplorerReadBounds.textBytes,
           let text = String(data: pretty, encoding: .utf8) {
            return text
        }
        return String(data: data, encoding: .utf8)
    }

    private static func looksLikePropertyList(_ data: Data) -> Bool {
        if data.starts(with: Data("bplist".utf8)) { return true }
        guard let prefix = String(data: data.prefix(64), encoding: .utf8) else { return false }
        let trimmed = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("<?xml") || trimmed.hasPrefix("<plist")
    }

    private static func looksLikeJSON(_ data: Data) -> Bool {
        guard let prefix = String(data: data.prefix(16), encoding: .utf8) else { return false }
        let trimmed = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("{") || trimmed.hasPrefix("[")
    }

    private static func looksLikeText(_ data: Data) -> Bool {
        guard !data.isEmpty else { return false }
        guard let text = String(data: data.prefix(8_192), encoding: .utf8), !text.isEmpty else { return false }
        var controls = 0
        var total = 0
        for scalar in text.unicodeScalars {
            total += 1
            if scalar.value < 32 && scalar.value != 9 && scalar.value != 10 && scalar.value != 13 {
                controls += 1
            }
        }
        return total > 0 && controls * 20 < total
    }

    private static func valueText(_ value: Any) -> String {
        switch value {
        case let boolean as Bool:
            return boolean ? "Yes" : "No"
        case let text as String:
            if text.count > ExplorerReadBounds.maximumValueCharacters {
                return String(text.prefix(ExplorerReadBounds.maximumValueCharacters)) + "…"
            }
            return text
        case let number as Int:
            return String(number)
        case let number as Double:
            return String(number)
        case let date as Date:
            return dateText(date)
        case let array as [Any]:
            return "\(array.count) values"
        case let dictionary as [String: Any]:
            return "\(dictionary.count) fields"
        case let data as Data:
            return "Data (\(data.count) bytes)"
        default:
            return "Value"
        }
    }

    private static func dateText(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }

    private static func clip(_ text: String) -> (String, Bool) {
        guard text.count > ExplorerReadBounds.maximumTextCharacters else { return (text, false) }
        let end = text.index(text.startIndex, offsetBy: ExplorerReadBounds.maximumTextCharacters)
        return (String(text[..<end]) + "…", true)
    }

    private static func string(_ key: String, in root: [String: Any]?) -> String? {
        guard let value = root?[key] as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func stringList(_ key: String, in root: [String: Any]) -> [String] {
        if let one = root[key] as? String {
            let trimmed = one.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? [] : [trimmed]
        }
        guard let values = root[key] as? [Any] else { return [] }
        return values.compactMap { $0 as? String }.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    private static func extensionPoint(in root: [String: Any]?) -> String? {
        guard let container = root?["NSExtension"] as? [String: Any] else { return nil }
        return string("NSExtensionPointIdentifier", in: container)
    }

    private static func executable(in entry: BundleEntry, contents: BundleContents, plist: [String: Any]?, suffix: String) -> BundleEntry? {
        if let declared = string("CFBundleExecutable", in: plist),
           let path = entry.path.appending(component: declared),
           let match = contents.entry(at: path),
           match.kind == .regularFile {
            return match
        }
        return ExplorerMeasurements.conventionalExecutable(
            in: entry.path,
            bundleFileName: entry.name,
            suffix: suffix,
            contents: contents
        )
    }

    private static func archivePath(for entry: BundlePath, within bundle: ArchivePath) -> ArchivePath? {
        var path = bundle
        for component in entry.components {
            guard let next = path.appending(component: component) else { return nil }
            path = next
        }
        return path
    }

    private static func make(
        entry: BundleEntry,
        contents: BundleContents,
        classification: BundleFileClassification,
        body: ExplorerEntryInspection.Body
    ) -> ExplorerEntryInspection {
        ExplorerEntryInspection(
            name: entry.name,
            locationText: ExplorerLocation.displayPath(bundleName: contents.bundleName, entry: entry.path),
            declaredByteCount: entry.declaredByteCount,
            classification: classification,
            body: body
        )
    }

    private static func unavailable(
        entry: BundleEntry,
        contents: BundleContents,
        classification: BundleFileClassification,
        title: String,
        message: String
    ) -> ExplorerEntryInspection {
        make(entry: entry, contents: contents, classification: classification, body: .unavailable(title: title, message: message))
    }
}
