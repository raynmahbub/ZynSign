import Foundation

/// The platform implementation of `SigningWorkspaceProviding`: one directory
/// per signing operation, under a root the composition root chose.
///
/// The directory name is the operation's own identifier, which ZynSign mints,
/// so two operations cannot be handed the same directory and no part of a
/// package's content or a user-selected document's name reaches the file
/// system through this type. The root is created on first use; nothing is
/// created at construction time.
///
/// Removal is confined to the root: a location outside it is refused rather
/// than removed, so a caller that was handed the wrong URL cannot use this
/// type to delete something else.
final class FileSigningWorkspace: SigningWorkspaceProviding, Sendable {

    /// The directory every operation directory is created under.
    let root: URL

    init(root: URL) {
        self.root = root
    }

    func makeOperationDirectory(forOperation identifier: String) throws -> URL {
        guard Self.isSafeComponent(identifier) else {
            throw ZynSignError.signingWorkspaceUnavailable(
                diagnosticDetail: "An operation identifier was not a safe directory name, so no workspace was created for it."
            )
        }
        let location = root.appendingPathComponent(identifier, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: location, withIntermediateDirectories: true)
        } catch {
            throw ZynSignError.signingWorkspaceUnavailable(
                diagnosticDetail: "The signing workspace directory could not be created.",
                underlyingError: error
            )
        }
        return location
    }

    func removeOperationDirectory(at location: URL) {
        guard Self.isInsideRoot(location, root: root) else { return }
        guard FileManager.default.fileExists(atPath: location.path) else { return }
        try? FileManager.default.removeItem(at: location)
    }

    /// Whether `location` is the root itself or sits beneath it, compared on
    /// standardized paths so a relative component cannot escape the root.
    static func isInsideRoot(_ location: URL, root: URL) -> Bool {
        let target = location.standardizedFileURL.path
        let base = root.standardizedFileURL.path
        guard target != base else { return false }
        return target.hasPrefix(base.hasSuffix("/") ? base : base + "/")
    }

    /// Whether `component` is a single safe path component.
    static func isSafeComponent(_ component: String) -> Bool {
        guard !component.isEmpty, component.count <= 255 else { return false }
        guard !component.contains("/"), !component.contains("\\") else { return false }
        guard component != ".", component != "..", !component.hasPrefix(".") else { return false }
        return !component.unicodeScalars.contains(where: { $0.value == 0 })
    }
}
