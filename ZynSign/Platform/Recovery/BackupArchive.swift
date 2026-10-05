import Foundation
import CryptoKit
import CommonCrypto
#if os(iOS)
import UIKit
#endif

/// Version 1: magic + random salt + AES-GCM sealed manifest frame + sealed 1 MiB
/// frames for each entry in manifest order. Each frame has a big-endian length.
/// No paths in the archive are ever used without checking against the allowlist.
/// The archive is portable; the passphrase is never saved in the container.
enum BackupCategory: String, CaseIterable, Codable, Identifiable, Sendable {
    case library, collections, settings, history
    var id: String { rawValue }
    var title: String {
        switch self {
        case .library: return "Library, favorites & package files"
        case .collections: return "Collections"
        case .settings: return "Settings"
        case .history: return "Import & signing history"
        }
    }
}

struct BackupManifest: Codable, Sendable, Equatable {
    static let version = 1
    struct Entry: Codable, Sendable, Equatable {
        let path: String
        let category: BackupCategory
        let bytes: Int64
        let sha256: String
    }
    let version: Int
    let createdAt: Date
    let entries: [Entry]
    let libraryItems: Int?
    let favoriteItems: Int?
    let collectionCount: Int?
    var categories: Set<BackupCategory> { Set(entries.map(\.category)) }
    var byteCount: Int64 { entries.reduce(0) { $0 + $1.bytes } }
}

enum BackupFailure: LocalizedError {
    case invalid(String)
    var errorDescription: String? {
        if case .invalid(let reason) = self { return reason }
        return nil
    }
}

/// Files are only read through this explicit map. No identity, profile,
/// queue setup, diagnostics, temporary workspace, or Keychain material is
/// exported. IPA packages are user-imported data, NOT signing credentials.
actor BackupArchive {
    let root: URL
    let backups: URL
    private let fm = FileManager.default
    private static let magic = Data("ZYNSBK01".utf8)
    private static let chunk = 1_048_576
    private static let maximumEntries = 100_000
    private static let maximumManifest = 16_000_000
    private static let iterations: UInt32 = 250_000

    init(root: URL, backups: URL) {
        self.root = root
        self.backups = backups
    }

    static func category(for path: String) -> BackupCategory? {
        switch path {
        case "catalog.json": return .library
        case "Organization.json": return .collections
        case "Preferences.json": return .settings
        case "ImportHistory.json", "SigningHistory.json", "Exports.json": return .history
        default:
            guard path.hasPrefix("Artifacts/") else { return nil }
            let name = String(path.dropFirst("Artifacts/".count))
            guard !name.contains("/"), name.hasSuffix(".ipa"),
                  ArtifactIdentifier(rawValue: String(name.dropLast(4))) != nil else { return nil }
            return .library
        }
    }

    private func sourceFiles(_ categories: Set<BackupCategory>) throws -> [(String, URL, BackupCategory)] {
        var paths = ["catalog.json", "Organization.json", "Preferences.json",
                     "ImportHistory.json", "SigningHistory.json", "Exports.json"]
        let artifacts = root.appendingPathComponent("Artifacts", isDirectory: true)
        if categories.contains(.library), fm.fileExists(atPath: artifacts.path) {
            paths += try fm.contentsOfDirectory(atPath: artifacts.path).map { "Artifacts/" + $0 }.sorted()
        }
        return try paths.compactMap { path in
            guard let category = Self.category(for: path), categories.contains(category) else { return nil }
            let url = root.appendingPathComponent(path)
            guard fm.fileExists(atPath: url.path) else { return nil }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw BackupFailure.invalid("Backup refused an unexpected file in the library.")
            }
            return (path, url, category)
        }
    }

    private func key(_ password: String, salt: Data) throws -> SymmetricKey {
        guard password.utf8.count >= 12 else {
            throw BackupFailure.invalid("Use a backup passphrase of at least 12 characters.")
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        let length = bytes.count
        let result = password.withCString { pass in
            salt.withUnsafeBytes { raw in
                guard let baseAddress = raw.bindMemory(to: UInt8.self).baseAddress else {
                    return Int32(kCCParamError)
                }
                return CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), pass, password.utf8.count,
                    baseAddress, salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), Self.iterations, &bytes, length)
            }
        }
        guard result == kCCSuccess else { throw BackupFailure.invalid("Could not derive the backup key.") }
        defer { for i in bytes.indices { bytes[i] = 0 } }
        return SymmetricKey(data: bytes)
    }

    private func read(_ handle: FileHandle, count: Int) throws -> Data {
        guard let data = try handle.read(upToCount: count), data.count == count else {
            throw BackupFailure.invalid("Backup is truncated or damaged.")
        }
        return data
    }

    private func writeFrame(_ data: Data, key: SymmetricKey, to handle: FileHandle) throws {
        let sealed = try AES.GCM.seal(data, using: key)
        guard let combined = sealed.combined else { throw BackupFailure.invalid("Encryption failed.") }
        var size = UInt32(combined.count).bigEndian
        try handle.write(contentsOf: Data(bytes: &size, count: 4))
        try handle.write(contentsOf: combined)
    }

    private func readFrame(_ handle: FileHandle, key: SymmetricKey, limit: Int) throws -> Data {
        let header = try read(handle, count: 4)
        let size = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard size >= 28, size <= limit + 28 else {
            throw BackupFailure.invalid("Invalid encrypted frame size.")
        }
        do {
            return try AES.GCM.open(AES.GCM.SealedBox(combined: read(handle, count: Int(size))), using: key)
        } catch {
            throw BackupFailure.invalid("Wrong passphrase or damaged backup.")
        }
    }

    private func digest(_ url: URL) throws -> (Int64, String) {
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        var hash = SHA256()
        var length: Int64 = 0
        while let data = try input.read(upToCount: Self.chunk), !data.isEmpty {
            try Task.checkCancellation()
            length += Int64(data.count)
            hash.update(data: data)
        }
        return (length, hash.finalize().map { String(format: "%02x", $0) }.joined())
    }

    /// Writes a unique temporary archive, verifies it in full, then publishes
    /// it. Existing backups are never overwritten even when creation fails.
    func create(categories: Set<BackupCategory>, password: String) throws -> URL {
        let sources = try sourceFiles(categories)
        guard !sources.isEmpty, sources.count <= Self.maximumEntries else {
            throw BackupFailure.invalid("No supported data was selected for this backup.")
        }
        let entries = try sources.map { path, url, category -> BackupManifest.Entry in
            let (bytes, sha) = try digest(url)
            return .init(path: path, category: category, bytes: bytes, sha256: sha)
        }
        let catalog = root.appendingPathComponent("catalog.json")
        let library: [ApplicationRecordIdentifier: ApplicationRecord]?
        if entries.contains(where: { $0.path == "catalog.json" }) {
            library = try FileApplicationRecordStore.readCatalog(at: catalog)
        } else { library = nil }
        let organization = root.appendingPathComponent("Organization.json")
        let collections: Int?
        if entries.contains(where: { $0.path == "Organization.json" }) {
            collections = try FileLibraryOrganizationStore(documentLocation: organization).loadOrganization().collections.count
        } else { collections = nil }
        let manifest = BackupManifest(version: BackupManifest.version, createdAt: Date(), entries: entries,
            libraryItems: library?.count, favoriteItems: library?.values.filter(\.isFavorite).count,
            collectionCount: collections)
        try fm.createDirectory(at: backups, withIntermediateDirectories: true)
        let pending = backups.appendingPathComponent(".pending-\(UUID().uuidString)")
        let destination = backups.appendingPathComponent(UUID().uuidString).appendingPathExtension("zynbackup")
        defer { try? fm.removeItem(at: pending) }
        fm.createFile(atPath: pending.path, contents: nil)
        let output = try FileHandle(forWritingTo: pending)
        do {
            try output.write(contentsOf: Self.magic)
            let salt = Data((0..<16).map { _ in UInt8.random(in: .min ... .max) })
            try output.write(contentsOf: salt)
            let encryptionKey = try key(password, salt: salt)
            let document = try JSONEncoder().encode(manifest)
            guard document.count <= Self.maximumManifest else { throw BackupFailure.invalid("Backup catalog too large.") }
            try writeFrame(document, key: encryptionKey, to: output)
            for (index, source) in sources.enumerated() {
                let input = try FileHandle(forReadingFrom: source.1)
                var hash = SHA256()
                var length: Int64 = 0
                do {
                    while let data = try input.read(upToCount: Self.chunk), !data.isEmpty {
                        try Task.checkCancellation()
                        length += Int64(data.count)
                        hash.update(data: data)
                        try writeFrame(data, key: encryptionKey, to: output)
                    }
                    try input.close()
                } catch { try? input.close(); throw error }
                guard length == entries[index].bytes,
                      hash.finalize().map({ String(format: "%02x", $0) }).joined() == entries[index].sha256 else {
                    throw BackupFailure.invalid("Library changed while building the backup. Retry when imports are idle.")
                }
            }
            try output.synchronize()
            try output.close()
            _ = try inspect(pending, password: password)
            try fm.moveItem(at: pending, to: destination)
            return destination
        } catch { try? output.close(); throw error }
    }

    /// Full authentication, checksum and content check; no content is exposed
    /// to the caller before the entire archive has passed validation.
    func inspect(_ url: URL, password: String) throws -> BackupManifest {
        let scratch = backups.appendingPathComponent(".verify-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: scratch) }
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        #if os(iOS)
        try fm.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: scratch.path)
        #endif
        return try unpack(url, password: password, into: scratch)
    }

    func extract(_ url: URL, password: String, to destination: URL) throws -> BackupManifest {
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        #if os(iOS)
        try fm.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: destination.path)
        #endif
        return try unpack(url, password: password, into: destination)
    }

    private struct UnpackContext {
        let key: SymmetricKey
        let manifest: BackupManifest
    }

    private func unpack(_ url: URL, password: String, into destination: URL?) throws -> BackupManifest {
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        let context = try readUnpackContext(from: input, password: password)
        try unpackEntries(context.manifest.entries, from: input, key: context.key, into: destination)
        try validateNoTrailingData(in: input)
        if let destination {
            try validateUnpackedContents(context.manifest, in: destination)
        }
        return context.manifest
    }

    private func readUnpackContext(from input: FileHandle, password: String) throws -> UnpackContext {
        guard try read(input, count: 8) == Self.magic else {
            throw BackupFailure.invalid("Not a ZynSign backup.")
        }
        let encryptionKey = try key(password, salt: read(input, count: 16))
        let manifest = try JSONDecoder().decode(
            BackupManifest.self,
            from: readFrame(input, key: encryptionKey, limit: Self.maximumManifest)
        )
        guard manifest.version == BackupManifest.version else {
            throw BackupFailure.invalid("This backup version is not supported. Update ZynSign before restoring.")
        }
        guard !manifest.entries.isEmpty,
              manifest.entries.count <= Self.maximumEntries,
              Set(manifest.entries.map(\.path)).count == manifest.entries.count else {
            throw BackupFailure.invalid("Invalid backup catalog.")
        }
        return UnpackContext(key: encryptionKey, manifest: manifest)
    }

    private func unpackEntries(
        _ entries: [BackupManifest.Entry],
        from input: FileHandle,
        key encryptionKey: SymmetricKey,
        into destination: URL?
    ) throws {
        for entry in entries {
            try validateManifestEntry(entry)
            try unpackEntry(entry, from: input, key: encryptionKey, into: destination)
        }
    }

    private func validateManifestEntry(_ entry: BackupManifest.Entry) throws {
        guard Self.category(for: entry.path) == entry.category,
              entry.bytes >= 0,
              entry.bytes <= 500_000_000_000,
              entry.sha256.count == 64,
              entry.sha256.allSatisfy({ $0.isHexDigit }) else {
            throw BackupFailure.invalid("Backup contains an unsupported item.")
        }
    }

    private func unpackEntry(
        _ entry: BackupManifest.Entry,
        from input: FileHandle,
        key encryptionKey: SymmetricKey,
        into destination: URL?
    ) throws {
        let output = try makeOutput(for: entry, in: destination)
        var remaining = entry.bytes
        var hash = SHA256()
        do {
            while remaining > 0 {
                try Task.checkCancellation()
                let frame = try readFrame(input, key: encryptionKey, limit: Self.chunk)
                guard Int64(frame.count) == min(Int64(Self.chunk), remaining) else {
                    throw BackupFailure.invalid("Backup item length is invalid.")
                }
                remaining -= Int64(frame.count)
                hash.update(data: frame)
                try output?.write(contentsOf: frame)
            }
            try output?.close()
        } catch {
            try? output?.close()
            throw error
        }
        guard hash.finalize().map({ String(format: "%02x", $0) }).joined() == entry.sha256 else {
            throw BackupFailure.invalid("Backup checksum failed for \(entry.path).")
        }
    }

    private func makeOutput(for entry: BackupManifest.Entry, in destination: URL?) throws -> FileHandle? {
        guard let destination else { return nil }
        let file = destination.appendingPathComponent(entry.path)
        try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        fm.createFile(atPath: file.path, contents: nil)
        return try FileHandle(forWritingTo: file)
    }

    private func validateNoTrailingData(in input: FileHandle) throws {
        let trailing = try input.read(upToCount: 1)
        guard trailing?.isEmpty ?? true else {
            throw BackupFailure.invalid("Backup has unexpected trailing data.")
        }
    }

    private func validateUnpackedContents(_ manifest: BackupManifest, in destination: URL) throws {
        try validateJSONDocuments(manifest, in: destination)
        try validateLibraryContents(manifest, in: destination)
        try validateOrganization(manifest, in: destination)
    }

    private func validateJSONDocuments(_ manifest: BackupManifest, in destination: URL) throws {
        for entry in manifest.entries where entry.category != .library && entry.category != .collections {
            try validateJSONDocument(entry, in: destination)
        }
    }

    private func validateJSONDocument(_ entry: BackupManifest.Entry, in destination: URL) throws {
        let file = destination.appendingPathComponent(entry.path)
        let data = try Data(contentsOf: file, options: .mappedIfSafe)
        let object = try JSONSerialization.jsonObject(with: data)
        guard object is [String: Any] || object is [Any] else {
            throw BackupFailure.invalid("A backup document is not valid JSON.")
        }
        if entry.path == "Preferences.json" {
            try validatePreferences(object)
        }
    }

    private func validatePreferences(_ object: Any) throws {
        guard let envelope = object as? [String: Any],
              let version = envelope["schemaVersion"] as? Int,
              version >= 1,
              version <= ZynSignPreferences.schemaVersion,
              let preferences = envelope["preferences"],
              let encoded = try? JSONSerialization.data(withJSONObject: preferences),
              let decoded = try? JSONDecoder().decode(ZynSignPreferences.self, from: encoded),
              decoded.schemaVersion <= ZynSignPreferences.schemaVersion else {
            throw BackupFailure.invalid("Preferences contents or version are unsupported.")
        }
    }

    private func validateLibraryContents(_ manifest: BackupManifest, in destination: URL) throws {
        let catalog = destination.appendingPathComponent("catalog.json")
        guard fm.fileExists(atPath: catalog.path) else { return }
        let records = try FileApplicationRecordStore.readCatalog(at: catalog)
        guard manifest.libraryItems == records.count,
              manifest.favoriteItems == records.values.filter(\.isFavorite).count else {
            throw BackupFailure.invalid("Library contents do not match the backup preview.")
        }
        for record in records.values {
            try validateLibraryArtifact(record, in: destination)
        }
    }

    private func validateLibraryArtifact(_ record: ApplicationRecord, in destination: URL) throws {
        let file = destination.appendingPathComponent("Artifacts/\(record.artifact.artifactID.rawValue).ipa")
        guard fm.fileExists(atPath: file.path),
              (try file.resourceValues(forKeys: [.fileSizeKey])).fileSize == record.artifact.byteCount,
              try digest(file).1 == record.artifact.fingerprint.hexDigest else {
            throw BackupFailure.invalid("A library package is missing or does not match its recorded fingerprint.")
        }
    }

    private func validateOrganization(_ manifest: BackupManifest, in destination: URL) throws {
        let organization = destination.appendingPathComponent("Organization.json")
        guard fm.fileExists(atPath: organization.path) else { return }
        let count = try FileLibraryOrganizationStore(documentLocation: organization).loadOrganization().collections.count
        guard manifest.collectionCount == count else {
            throw BackupFailure.invalid("Collections do not match the backup preview.")
        }
    }

}
