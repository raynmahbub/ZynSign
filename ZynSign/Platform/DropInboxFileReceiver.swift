import Foundation
import UniformTypeIdentifiers

/// The platform implementation of `DroppedFileReceiving`.
///
/// A file dragged in from another app is only readable while the drop is
/// being handled: the system hands over a temporary file that disappears as
/// soon as the handler returns. The receiver therefore copies each dropped
/// file into a ZynSign-owned inbox — one freshly named folder per file, so
/// two drops of files with the same name can never collide — and gives the
/// Import Hub the inbox copy.
///
/// The inbox is ZynSign's own scratch space. The dragged original is only
/// read. Inbox copies are removed with `release(_:)` once the hub no longer
/// needs them, and the drop inbox alone is swept at launch; `release(_:)`
/// refuses anything ZynSign did not park itself, so it can never touch a
/// user's file.
///
/// A provider is read through whichever route it actually offers. A registered
/// type that names the file's own data can be copied straight out of the
/// provider; a file dragged from another app frequently offers nothing but
/// `public.file-url`, and asking *that* for a file representation returns the
/// reference rather than the bytes it names, so the URL has to be resolved and
/// copied. Taking only the first route is what made a drag from Files look like
/// a dead control.
final class DropInboxFileReceiver: DroppedFileReceiving, @unchecked Sendable {

    /// How one dropped provider's bytes reach the inbox.
    enum LoadPlan: Equatable, Sendable {

        /// Ask the provider for a temporary copy of the type it registered.
        case representation(typeIdentifier: String)

        /// Resolve the file URL the provider carries and copy that file.
        case referencedFile
    }

    /// The inbox directory. Everything inside it belongs to the receiver.
    let directory: URL

    /// Where the system parks the copy it makes for a share-sheet or Open In
    /// hand-off, on platforms that have such a directory. A file ZynSign is
    /// handed there is the app's own copy of somebody else's file, so taking
    /// it back is the app's job.
    let sharedInboxDirectory: URL?

    init(directory: URL, sharedInboxDirectory: URL? = DropInboxFileReceiver.systemSharedInboxDirectory()) {
        self.directory = directory
        self.sharedInboxDirectory = sharedInboxDirectory
    }

    /// The system's `Documents/Inbox`, which is where a hand-off lands.
    static func systemSharedInboxDirectory() -> URL? {
        FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("Inbox", isDirectory: true)
    }

    func receive(_ providers: [NSItemProvider]) async -> DroppedFileReception {
        var urls: [URL] = []
        var failedCount = 0
        for provider in providers {
            if let url = await receive(provider) {
                urls.append(url)
            } else {
                failedCount += 1
            }
        }
        return DroppedFileReception(urls: urls, failedCount: failedCount)
    }

    func release(_ url: URL) {
        if let folder = inboxFolder(containing: url) {
            try? FileManager.default.removeItem(at: folder)
            return
        }
        // The other pile ZynSign owns is a hand-off's copy in the system's
        // `Inbox`. The hub calls here at the one moment it is safe to: after
        // the import that needed the file has finished with it. `sweep()`
        // deliberately leaves these alone — see why there.
        guard let shared = sharedInboxDirectory, Self.isDirectChild(url, of: shared) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Removes every copy left in the receiver's own inbox.
    ///
    /// Only its own. The system parks a share-sheet or Open In copy in
    /// `Documents/Inbox` *before* launching ZynSign to read it, so a sweep
    /// running at launch can delete the very file the app was started for, or
    /// the one a still-running staging copy is reading. Those copies go
    /// through `release(_:)` instead, when the item that used them settles: a
    /// share the user abandons can leave its package behind, and that is the
    /// smaller harm than refusing a file ZynSign was handed.
    func sweep() {
        removeContents(of: directory)
    }

    /// Whether `url` is a file directly inside `parent`, compared on resolved
    /// paths so a symlinked or unstandardized spelling cannot widen the set of
    /// files this type is allowed to delete.
    static func isDirectChild(_ url: URL, of parent: URL) -> Bool {
        let ownedPath = parent.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        let candidatePath = url.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        return candidatePath.count == ownedPath.count + 1
            && Array(candidatePath.prefix(ownedPath.count)) == ownedPath
    }

    private func removeContents(of url: URL) {
        let leftovers = (try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: nil
        )) ?? []
        for leftover in leftovers {
            try? FileManager.default.removeItem(at: leftover)
        }
    }

    // MARK: - Choosing the route

    /// The route to take for a provider, from what it offers.
    ///
    /// The most specific registered type that names file data wins, because
    /// asking for it gets the file itself in one step — except for
    /// `public.file-url` itself. A file URL does conform to `public.data`, but
    /// a *representation* of it is the reference, not the package: the provider
    /// that offers only that has to be read through the URL and copied, which
    /// is the common case for a drag from Files and the case a representation-
    /// only reader loses. Only when neither route exists is the item reported as
    /// unreceivable, which the hub can state instead of dropping silently.
    static func loadPlan(registeredTypes: [String], hasFileURL: Bool, hasData: Bool) -> LoadPlan? {
        let fileURLIdentifier = UTType.fileURL.identifier
        if let specific = registeredTypes.first(where: { identifier in
            identifier != fileURLIdentifier && UTType(identifier)?.conforms(to: .data) == true
        }) {
            return .representation(typeIdentifier: specific)
        }
        if hasFileURL {
            return .referencedFile
        }
        if hasData {
            return .representation(typeIdentifier: UTType.data.identifier)
        }
        return nil
    }

    // MARK: - Receiving one file

    private func receive(_ provider: NSItemProvider) async -> URL? {
        guard let plan = Self.loadPlan(
            registeredTypes: provider.registeredTypeIdentifiers,
            hasFileURL: provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
            hasData: provider.hasItemConformingToTypeIdentifier(UTType.data.identifier)
        ) else {
            return nil
        }
        let suggestedName = provider.suggestedName
        switch plan {
        case .representation(let typeIdentifier):
            return await loadRepresentation(of: provider, typeIdentifier: typeIdentifier, suggestedName: suggestedName)
        case .referencedFile:
            guard let url = await referencedFileURL(of: provider) else { return nil }
            return copyToInbox(url, suggestedName: suggestedName, typeIdentifier: UTType.fileURL.identifier)
        }
    }

    private func loadRepresentation(
        of provider: NSItemProvider,
        typeIdentifier: String,
        suggestedName: String?
    ) async -> URL? {
        await withCheckedContinuation { (continuation: CheckedContinuation<URL?, Never>) in
            _ = provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { temporaryURL, _ in
                // The temporary file exists only until this handler returns,
                // so the copy happens here, synchronously.
                guard let temporaryURL else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(
                    returning: self.copyToInbox(
                        temporaryURL,
                        suggestedName: suggestedName,
                        typeIdentifier: typeIdentifier
                    )
                )
            }
        }
    }

    /// The file URL a provider carries, if it resolves to one.
    private func referencedFileURL(of provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { (continuation: CheckedContinuation<URL?, Never>) in
            _ = provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                if let url = item as? URL {
                    continuation.resume(returning: url)
                } else if let fileURL = item as? NSURL {
                    continuation.resume(returning: fileURL as URL)
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    // MARK: - The inbox copy

    /// Copies `source` into a fresh inbox folder and returns the copy.
    ///
    /// The source is only ever read, and the name it is stored under comes
    /// from the source's own name when that is usable — reduced to a single
    /// path component, since a dragged file gets to say its own name but not
    /// where it lands.
    private func copyToInbox(_ source: URL, suggestedName: String?, typeIdentifier: String) -> URL? {
        let acquiredScope = source.startAccessingSecurityScopedResource()
        defer {
            if acquiredScope {
                source.stopAccessingSecurityScopedResource()
            }
        }
        let name = Self.fileName(for: source, suggestedName: suggestedName, typeIdentifier: typeIdentifier)
        let folder = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let destination = folder.appendingPathComponent(name, isDirectory: false)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: source, to: destination)
            return destination
        } catch {
            try? FileManager.default.removeItem(at: folder)
            return nil
        }
    }

    /// A safe file name for the inbox copy: the dropped file's own name
    /// when it has one, reduced to a single path component, with the type's
    /// extension added when the name has none.
    static func fileName(for url: URL, suggestedName: String?, typeIdentifier: String) -> String {
        let candidates = [url.lastPathComponent, suggestedName ?? ""]
        var name = candidates
            .map { $0.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_") }
            .first { !$0.isEmpty && $0 != "." && $0 != ".." } ?? "Dropped File"
        if (name as NSString).pathExtension.isEmpty,
           let preferred = UTType(typeIdentifier)?.preferredFilenameExtension {
            name += ".\(preferred)"
        }
        return name
    }

    /// The per-file inbox folder holding `url`, or `nil` when `url` is not
    /// an inbox copy.
    private func inboxFolder(containing url: URL) -> URL? {
        let inbox = directory.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        let candidate = url.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        guard candidate.count == inbox.count + 2,
              Array(candidate.prefix(inbox.count)) == inbox else {
            return nil
        }
        return url.deletingLastPathComponent()
    }
}
