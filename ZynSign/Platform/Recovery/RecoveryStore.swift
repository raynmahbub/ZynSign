import Foundation
import CryptoKit

struct BackupHistoryItem: Codable, Identifiable, Sendable {
    let id: UUID
    var name: String
    let createdAt: Date
    let bytes: Int64
    let categories: [BackupCategory]
    var fileName: String { id.uuidString + ".zynbackup" }
}

/// All backup bookkeeping stays separate from the exported encrypted file.
/// No passphrase or derived key is written to disk. The local history is not
/// authoritative: deleting a history entry never deletes a transferred copy.
actor RecoveryStore {
    let root: URL
    let directory: URL
    let archive: BackupArchive
    private var fm: FileManager { .default }
    private var index: URL { directory.appendingPathComponent("History.json") }

    init(root: URL) {
        self.root = root
        directory = root.appendingPathComponent("Recovery", isDirectory: true)
        archive = BackupArchive(root: root, backups: root.appendingPathComponent("Recovery/Backups", isDirectory: true))
    }

    func history() throws -> [BackupHistoryItem] {
        let indexed: [BackupHistoryItem]
        if let data = try? Data(contentsOf: index),
           let decoded = try? JSONDecoder().decode([BackupHistoryItem].self, from: data) {
            indexed = decoded
        } else { indexed = [] }
        let backups = directory.appendingPathComponent("Backups", isDirectory: true)
        guard fm.fileExists(atPath: backups.path) else { return [] }
        let files = try fm.contentsOfDirectory(at: backups, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey])
        var byID = Dictionary(indexed.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for file in files where file.pathExtension == "zynbackup" {
            guard let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent),
                  (try file.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true else { continue }
            if byID[id] == nil {
                let facts = try file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                byID[id] = BackupHistoryItem(id: id, name: "Recovered local backup",
                    createdAt: facts.contentModificationDate ?? .distantPast,
                    bytes: Int64(facts.fileSize ?? 0), categories: [])
            }
        }
        return byID.values.filter { fm.fileExists(atPath: backups.appendingPathComponent($0.fileName).path) }
            .sorted { $0.createdAt > $1.createdAt }
    }

    func url(for item: BackupHistoryItem) -> URL {
        directory.appendingPathComponent("Backups/" + item.fileName)
    }

    private func save(_ items: [BackupHistoryItem]) throws {
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(items).write(to: index, options: .atomic)
    }

    func create(categories: Set<BackupCategory>, password: String) async throws -> BackupHistoryItem {
        let file = try await archive.create(categories: categories, password: password)
        do {
            let manifest = try await archive.inspect(file, password: password)
            let itemID = UUID(uuidString: file.deletingPathExtension().lastPathComponent) ?? UUID()
            let item = BackupHistoryItem(id: itemID,
                name: "Manual Backup", createdAt: manifest.createdAt,
                bytes: Int64((try file.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0),
                categories: BackupCategory.allCases.filter { manifest.categories.contains($0) })
            var items = try history()
            items.insert(item, at: 0)
            try save(items)
            return item
        } catch {
            // A verified archive remains available even if history bookkeeping fails.
            throw error
        }
    }

    func rename(_ item: BackupHistoryItem, to name: String) throws {
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 80 else { throw BackupFailure.invalid("Use a name between 1 and 80 characters.") }
        var items = try history()
        guard let i = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[i].name = value
        try save(items)
    }

    func delete(_ item: BackupHistoryItem) throws {
        // Remove the file first; if it fails, the history still points to it.
        try fm.removeItem(at: url(for: item))
        try save(history().filter { $0.id != item.id })
    }

    func importFile(_ source: URL) throws -> URL {
        let access = source.startAccessingSecurityScopedResource()
        defer { if access { source.stopAccessingSecurityScopedResource() } }
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appendingPathComponent("Incoming-" + UUID().uuidString + ".zynbackup")
        try fm.copyItem(at: source, to: target)
        return target
    }

    func inspect(_ url: URL, password: String) async throws -> BackupManifest {
        try await archive.inspect(url, password: password)
    }

    /// Restore is deliberately deferred until the next cold launch. Live
    /// library/queue/settings actors have cached snapshots; replacing their
    /// files behind their backs would discard fresh changes or run stale jobs.
    func prepare(_ url: URL, password: String, categories: Set<BackupCategory>,
                 expected: BackupManifest? = nil) async throws -> BackupManifest {
        guard !fm.fileExists(atPath: pending.path) else {
            throw BackupFailure.invalid("A restore is already waiting for the next launch.")
        }
        let stage = directory.appendingPathComponent("Stage-" + UUID().uuidString, isDirectory: true)
        var published = false
        defer { if !published { try? fm.removeItem(at: stage) } }
        let manifest = try await archive.extract(url, password: password, to: stage)
        guard expected == nil || expected == manifest else {
            throw BackupFailure.invalid("Backup changed since the preview. Validate it again before restoring.")
        }
        guard !categories.isEmpty, categories.isSubset(of: manifest.categories) else {
            throw BackupFailure.invalid("Select at least one category present in this backup.")
        }
        let plan = PendingRestore(stage: stage.lastPathComponent,
            categories: categories.sorted { $0.rawValue < $1.rawValue },
            entries: manifest.entries.filter { categories.contains($0.category) })
        try JSONEncoder().encode(plan).write(to: pending, options: .atomic)
        published = true
        return manifest
    }

    private var pending: URL { directory.appendingPathComponent("PendingRestore.json") }

    /// Only transient transferred copies are removable here. A staged
    /// restore and the retained pre-restore snapshot are never swept.
    func cleanIncoming() throws -> Int {
        guard !fm.fileExists(atPath: pending.path) else {
            throw BackupFailure.invalid("Finish the pending restore before cleaning recovery data.")
        }
        let children = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey])
        var removed = 0
        for url in children {
            let name = url.lastPathComponent
            guard name.hasPrefix("Incoming-"), name.hasSuffix(".zynbackup"),
                  UUID(uuidString: String(name.dropFirst(9).dropLast(10))) != nil,
                  (try url.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true else { continue }
            try fm.removeItem(at: url)
            removed += 1
        }
        return removed
    }

    func cleanPreviousRestore() throws {
        guard !fm.fileExists(atPath: pending.path),
              fm.fileExists(atPath: directory.appendingPathComponent("RestoreComplete.txt").path) else {
            throw BackupFailure.invalid("A verified restore is required before removing previous data.")
        }
        for url in try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey]) {
            let name = url.lastPathComponent
            guard name.hasPrefix("Rollback-Stage-"),
                  UUID(uuidString: String(name.dropFirst("Rollback-Stage-".count))) != nil,
                  (try url.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true else { continue }
            try fm.removeItem(at: url)
        }
    }

    func status() -> String {
        if let failure = try? String(contentsOf: directory.appendingPathComponent("RestoreError.txt"), encoding: .utf8) {
            return failure
        }
        if fm.fileExists(atPath: pending.path) { return "Restore staged — close and reopen ZynSign" }
        if fm.fileExists(atPath: directory.appendingPathComponent("RestoreComplete.txt").path) {
            return "Restore verified after restart"
        }
        return "No pending restore"
    }

    func usage() throws -> (latest: Int64, older: Int64, recovery: Int64) {
        let items = try history()
        let local = items.map(\.bytes)
        var recovery: Int64 = 0
        if let walker = fm.enumerator(at: directory, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
                                      options: [.skipsHiddenFiles]) {
            for case let url as URL in walker {
                if url.lastPathComponent == "Backups" { walker.skipDescendants(); continue }
                let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                if values.isRegularFile == true { recovery += Int64(values.fileSize ?? 0) }
            }
        }
        return (local.first ?? 0, local.dropFirst().reduce(0, +), recovery)
    }

    private struct PendingRestore: Codable {
        let stage: String
        let categories: [BackupCategory]
        let entries: [BackupManifest.Entry]
    }

    private static func checksum(_ file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hash = SHA256()
        while let bytes = try handle.read(upToCount: 1_048_576), !bytes.isEmpty {
            hash.update(data: bytes)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Called BEFORE composing any cached stores. Every destination is
    /// allowlisted. Existing data is moved into a retained rollback folder;
    /// a failure puts it back. Interrupted installs resume from the same
    /// immutable stage on the next launch, never declaring work completed.
    static func applyPending(at root: URL) {
        let fm = FileManager.default
        let directory = root.appendingPathComponent("Recovery", isDirectory: true)
        guard let plan = pendingPlan(in: directory) else { return }
        let stage = directory.appendingPathComponent(plan.stage, isDirectory: true)
        let paths = restorePaths(for: plan, stage: stage, fileManager: fm)
        guard !paths.isEmpty else { return }
        // Do not touch live data unless every selected staged item is intact.
        // The authenticated archive manifest was captured in the pending plan.
        guard validateStage(plan, at: stage, directory: directory, fileManager: fm) else { return }
        let rollback = directory.appendingPathComponent("Rollback-" + plan.stage, isDirectory: true)
        let pending = directory.appendingPathComponent("PendingRestore.json")
        installPendingRestore(
            plan,
            paths: paths,
            root: root,
            stage: stage,
            rollback: rollback,
            pending: pending,
            directory: directory,
            fileManager: fm
        )
    }

    private static func pendingPlan(in directory: URL) -> PendingRestore? {
        let pending = directory.appendingPathComponent("PendingRestore.json")
        guard let data = try? Data(contentsOf: pending),
              let plan = try? JSONDecoder().decode(PendingRestore.self, from: data),
              plan.stage.hasPrefix("Stage-"),
              UUID(uuidString: String(plan.stage.dropFirst(6))) != nil else {
            return nil
        }
        return plan
    }

    private static func restorePaths(
        for plan: PendingRestore,
        stage: URL,
        fileManager fm: FileManager
    ) -> [String] {
        plan.categories.flatMap { destinationPaths(for: $0) }.filter {
            fm.fileExists(atPath: stage.appendingPathComponent($0).path)
        }
    }

    private static func destinationPaths(for category: BackupCategory) -> [String] {
        switch category {
        case .library: return ["Artifacts", "catalog.json"]
        case .collections: return ["Organization.json"]
        case .settings: return ["Preferences.json"]
        case .history: return ["ImportHistory.json", "SigningHistory.json", "Exports.json"]
        }
    }

    private static func validateStage(
        _ plan: PendingRestore,
        at stage: URL,
        directory: URL,
        fileManager fm: FileManager
    ) -> Bool {
        do {
            try validateRestorePlan(plan)
            try validateStagedArtifacts(plan, at: stage, fileManager: fm)
            try validateStagedEntries(plan, at: stage)
            return true
        } catch {
            try? "Staged backup is damaged. Local data was not changed.".write(
                to: directory.appendingPathComponent("RestoreError.txt"),
                atomically: true,
                encoding: .utf8
            )
            return false
        }
    }

    private static func validateRestorePlan(_ plan: PendingRestore) throws {
        guard !plan.entries.isEmpty,
              Set(plan.entries.map(\.path)).count == plan.entries.count else {
            throw BackupFailure.invalid("Restore plan is empty or invalid.")
        }
    }

    private static func validateStagedArtifacts(
        _ plan: PendingRestore,
        at stage: URL,
        fileManager fm: FileManager
    ) throws {
        let artifacts = stage.appendingPathComponent("Artifacts", isDirectory: true)
        guard fm.fileExists(atPath: artifacts.path) else { return }
        let expected = Set(plan.entries.filter { $0.path.hasPrefix("Artifacts/") }
            .map { URL(fileURLWithPath: $0.path).lastPathComponent })
        guard Set(try fm.contentsOfDirectory(atPath: artifacts.path)) == expected else {
            throw BackupFailure.invalid("Staged library contains unexpected files.")
        }
    }

    private static func validateStagedEntries(_ plan: PendingRestore, at stage: URL) throws {
        for entry in plan.entries {
            guard BackupArchive.category(for: entry.path) == entry.category,
                  plan.categories.contains(entry.category),
                  try checksum(stage.appendingPathComponent(entry.path)) == entry.sha256 else {
                throw BackupFailure.invalid("Staged backup failed integrity verification.")
            }
        }
    }

    private static func installPendingRestore(
        _ plan: PendingRestore,
        paths: [String],
        root: URL,
        stage: URL,
        rollback: URL,
        pending: URL,
        directory: URL,
        fileManager fm: FileManager
    ) {
        let originalsFile = rollback.appendingPathComponent("Originals.json")
        do {
            try fm.createDirectory(at: rollback, withIntermediateDirectories: true)
            guard try prepareRollback(
                originalsFile,
                paths: paths,
                root: root,
                rollback: rollback,
                fileManager: fm
            ) else {
                return
            }
            try installPaths(plan, paths: paths, root: root, stage: stage, rollback: rollback, fileManager: fm)
            // Keep pre-restore files; cleanup remains a separate action.
            try completeRestore(stage: stage, pending: pending, directory: directory, fileManager: fm)
        } catch {
            restoreAfterFailedInstall(
                paths: paths,
                root: root,
                rollback: rollback,
                originalsFile: originalsFile,
                directory: directory,
                fileManager: fm
            )
        }
    }

    private static func prepareRollback(
        _ originalsFile: URL,
        paths: [String],
        root: URL,
        rollback: URL,
        fileManager fm: FileManager
    ) throws -> Bool {
        if fm.fileExists(atPath: originalsFile.path) {
            let originalPaths = try JSONDecoder().decode([String].self, from: Data(contentsOf: originalsFile))
            guard Set(originalPaths).isSubset(of: Set(paths)) else { return false }
            // An interrupted install may have left a new file behind; restore
            // the original state before retrying from the stage.
            try restoreInterruptedInstall(paths, originals: originalPaths, root: root, rollback: rollback, fileManager: fm)
            return true
        }
        let originalPaths = paths.filter { fm.fileExists(atPath: root.appendingPathComponent($0).path) }
        // Durable journal written before the first modification.
        try JSONEncoder().encode(originalPaths).write(to: originalsFile, options: .atomic)
        return true
    }

    private static func restoreInterruptedInstall(
        _ paths: [String],
        originals: [String],
        root: URL,
        rollback: URL,
        fileManager fm: FileManager
    ) throws {
        for path in paths {
            let target = root.appendingPathComponent(path)
            let previous = rollback.appendingPathComponent(path)
            if fm.fileExists(atPath: previous.path) {
                if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
                try fm.moveItem(at: previous, to: target)
            } else if !originals.contains(path), fm.fileExists(atPath: target.path) {
                try fm.removeItem(at: target)
            }
        }
    }

    private static func installPaths(
        _ plan: PendingRestore,
        paths: [String],
        root: URL,
        stage: URL,
        rollback: URL,
        fileManager fm: FileManager
    ) throws {
        for path in paths {
            let target = root.appendingPathComponent(path)
            let previous = rollback.appendingPathComponent(path)
            if fm.fileExists(atPath: target.path) { try fm.moveItem(at: target, to: previous) }
            try fm.copyItem(at: stage.appendingPathComponent(path), to: target)
            try verifyInstalledEntries(plan, for: path, at: root)
        }
    }

    private static func verifyInstalledEntries(_ plan: PendingRestore, for path: String, at root: URL) throws {
        for entry in plan.entries where entry.path == path || (path == "Artifacts" && entry.path.hasPrefix("Artifacts/")) {
            guard try checksum(root.appendingPathComponent(entry.path)) == entry.sha256 else {
                throw BackupFailure.invalid("Installed item failed integrity verification.")
            }
        }
    }

    private static func completeRestore(
        stage: URL,
        pending: URL,
        directory: URL,
        fileManager fm: FileManager
    ) throws {
        try fm.removeItem(at: pending)
        try? fm.removeItem(at: stage)
        try? fm.removeItem(at: directory.appendingPathComponent("RestoreError.txt"))
        try? "Restore verified after restart. Previous files are retained for recovery.".write(
            to: directory.appendingPathComponent("RestoreComplete.txt"),
            atomically: true,
            encoding: .utf8
        )
    }

    private static func restoreAfterFailedInstall(
        paths: [String],
        root: URL,
        rollback: URL,
        originalsFile: URL,
        directory: URL,
        fileManager fm: FileManager
    ) {
        let originalPaths = (try? JSONDecoder().decode([String].self, from: Data(contentsOf: originalsFile))) ?? []
        for path in paths.reversed() {
            let target = root.appendingPathComponent(path)
            let previous = rollback.appendingPathComponent(path)
            if fm.fileExists(atPath: previous.path) {
                try? fm.removeItem(at: target)
                try? fm.moveItem(at: previous, to: target)
            } else if !originalPaths.contains(path) {
                try? fm.removeItem(at: target)
            }
        }
        let message = "Restore could not finish. Previous files are retained in Recovery. Close and reopen ZynSign to retry."
        try? message.write(
            to: directory.appendingPathComponent("RestoreError.txt"),
            atomically: true,
            encoding: .utf8
        )
    }
}
