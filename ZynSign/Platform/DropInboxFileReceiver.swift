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
/// needs them and swept at launch; `release(_:)` refuses anything outside
/// the inbox, so it can never touch a user's file.
final class DropInboxFileReceiver: DroppedFileReceiving, @unchecked Sendable {

    /// The inbox directory. Everything inside it belongs to the receiver.
    let directory: URL

    init(directory: URL) {
        self.directory = directory
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
        guard let folder = inboxFolder(containing: url) else { return }
        try? FileManager.default.removeItem(at: folder)
    }

    func sweep() {
        let leftovers = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )) ?? []
        for leftover in leftovers {
            try? FileManager.default.removeItem(at: leftover)
        }
    }

    // MARK: - Receiving one file

    private func receive(_ provider: NSItemProvider) async -> URL? {
        guard let typeIdentifier = Self.fileTypeIdentifier(of: provider) else {
            return nil
        }
        let suggestedName = provider.suggestedName
        let directory = self.directory
        return await withCheckedContinuation { (continuation: CheckedContinuation<URL?, Never>) in
            _ = provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { temporaryURL, _ in
                // The temporary file exists only until this handler returns,
                // so the copy happens here, synchronously.
                guard let temporaryURL else {
                    continuation.resume(returning: nil)
                    return
                }
                let name = Self.fileName(for: temporaryURL, suggestedName: suggestedName, typeIdentifier: typeIdentifier)
                let folder = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
                let destination = folder.appendingPathComponent(name, isDirectory: false)
                do {
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    try FileManager.default.copyItem(at: temporaryURL, to: destination)
                    continuation.resume(returning: destination)
                } catch {
                    try? FileManager.default.removeItem(at: folder)
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    /// The first registered type that is file data, preferring the most
    /// specific the provider offers (such as an `.ipa`'s own type).
    private static func fileTypeIdentifier(of provider: NSItemProvider) -> String? {
        if let specific = provider.registeredTypeIdentifiers.first(where: { identifier in
            UTType(identifier)?.conforms(to: .data) == true
        }) {
            return specific
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.data.identifier) {
            return UTType.data.identifier
        }
        return nil
    }

    /// A safe file name for the inbox copy: the dropped file's own name
    /// when it has one, reduced to a single path component, with the type's
    /// extension added when the name has none.
    private static func fileName(for url: URL, suggestedName: String?, typeIdentifier: String) -> String {
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
