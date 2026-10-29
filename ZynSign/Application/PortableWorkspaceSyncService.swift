import Foundation

/// Files-app portable workspace mirroring & cross-install restoration service
/// (`Documents/ZynSignPortable/`).
///
/// Why this exists: when an Apple signing certificate is revoked, files stored
/// only inside `Library/Application Support` cannot be reached from the stock
/// iOS Files app, whereas `Documents/` remains user-accessible for drag-and-drop
/// into a freshly signed install.
///
/// Security invariant: Keychain private keys are NEVER exported here; only
/// non-secret workspace catalogs (repository URLs, presets, tweak library items,
/// auto-inject rules, profiles, and unsigned/signed IPAs) are mirrored or imported.
struct PortableWorkspaceSyncService: Sendable {

    struct SyncReport: Equatable, Sendable {
        var sourcesCount: Int = 0
        var profilesCount: Int = 0
        var tweaksCount: Int = 0
        var packagesCount: Int = 0
        var destinationPath: String = ""
    }

    private let documentsDirectory: URL

    init(documentsDirectory: URL? = nil) {
        self.documentsDirectory = documentsDirectory
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).appendingPathComponent("Documents", isDirectory: true)
    }

    var portableDirectory: URL {
        documentsDirectory.appendingPathComponent("ZynSignPortable", isDirectory: true)
    }

    /// Exports non-secret workspace catalogs and artifacts into `Documents/ZynSignPortable/`
    /// so they are immediately visible in the iOS Files app.
    @MainActor
    func exportPortableMirror(environment: ApplicationEnvironment) async throws -> SyncReport {
        let fm = FileManager.default
        let root = portableDirectory
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        var report = SyncReport(destinationPath: root.lastPathComponent)

        // 1. Export Store & Repository Directory URLs (JSON + plain newline list).
        var sourceURLs: Set<String> = []
        if let store = environment.storeBrowser {
            for source in store.snapshot.sources {
                sourceURLs.insert(source.url.absoluteString)
            }
        }
        if let repoDir = environment.repositoryDirectory {
            for source in repoDir.sources {
                sourceURLs.insert(source.url.absoluteString)
            }
        }
        let sortedURLs = sourceURLs.sorted()
        let jsonData = try JSONEncoder().encode(sortedURLs)
        try jsonData.write(to: root.appendingPathComponent("Sources.json"), options: .atomic)
        let textData = Data(sortedURLs.joined(separator: "\n").utf8)
        try textData.write(to: root.appendingPathComponent("sources.txt"), options: .atomic)
        report.sourcesCount = sortedURLs.count

        // 2. Export Provisioning Profiles (public CMS files; no private keys).
        if let profilesLib = environment.provisioningProfiles,
           let summaries = try? await profilesLib.allProfiles() {
            let profDir = root.appendingPathComponent("Profiles", isDirectory: true)
            try fm.createDirectory(at: profDir, withIntermediateDirectories: true)
            for item in summaries {
                if let raw = try? await profilesLib.profileBytes(withID: item.id) {
                    let safeName = sanitizeFileName(item.name) + "-\(item.id.rawValue.prefix(8)).mobileprovision"
                    try? raw.write(to: profDir.appendingPathComponent(safeName), options: .atomic)
                    report.profilesCount += 1
                }
            }
        }

        // 3. Export Tweak Library payloads & Auto-Inject rules.
        if let tweakLib = environment.tweakLibrary,
           let tweaks = try? tweakLib.all() {
            let tweaksDir = root.appendingPathComponent("Tweaks", isDirectory: true)
            try fm.createDirectory(at: tweaksDir, withIntermediateDirectories: true)
            for descriptor in tweaks {
                if let payload = try? tweakLib.payload(for: descriptor.id) {
                    try? payload.write(to: tweaksDir.appendingPathComponent(descriptor.fileName), options: .atomic)
                    report.tweaksCount += 1
                }
            }
        }
        if let rulesStore = environment.tweakAutoInjectRules,
           let rules = try? rulesStore.allRules(),
           let encoded = try? JSONEncoder().encode(rules) {
            try? encoded.write(to: root.appendingPathComponent("TweakAutoInjectRules.json"), options: .atomic)
        }

        // 4. Copy available Library IPAs into `Unsigned/` for Files-app workspace recovery.
        let unsignedDir = root.appendingPathComponent("Unsigned", isDirectory: true)
        try fm.createDirectory(at: unsignedDir, withIntermediateDirectories: true)
        if let entries = try? await environment.library.entries() {
            for entry in entries where entry.isArtifactAvailable {
                let src = environment.artifactFileURL(for: entry.record.artifact.artifactID)
                let cleanTitle = sanitizeFileName(entry.record.displayName ?? entry.record.bundleIdentifier.rawValue)
                let versionText = sanitizeFileName(entry.record.identity.shortVersionString ?? "1.0")
                let dst = unsignedDir.appendingPathComponent("\(cleanTitle)-\(versionText).ipa")
                if !fm.fileExists(atPath: dst.path) {
                    try? fm.copyItem(at: src, to: dst)
                }
                report.packagesCount += 1
            }
        }

        return report
    }

    /// Restores sources, profiles, tweaks, and `.ipa` packages from a
    /// `ZynSignPortable` folder or any external `Documents` workspace directory.
    @MainActor
    func importFromFolder(_ folderURL: URL, environment: ApplicationEnvironment) async throws -> SyncReport {
        let accessed = folderURL.startAccessingSecurityScopedResource()
        defer { if accessed { folderURL.stopAccessingSecurityScopedResource() } }

        let fm = FileManager.default
        var report = SyncReport(destinationPath: folderURL.lastPathComponent)

        // 1. Sources (`Sources.json` or `sources.txt`)
        let discoveredURLs = discoverSourceURLs(in: folderURL)
        if let store = environment.storeBrowser {
            for urlString in discoveredURLs {
                if await store.add(urlString) {
                    report.sourcesCount += 1
                }
            }
        }

        // 2. Walk folder (bounded depth) for `.mobileprovision`, `.dylib`/`.deb`, and `.ipa`/`.tipa`.
        guard let enumerator = fm.enumerator(
            at: folderURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return report }

        var ipaQueue: [URL] = []
        var profileURLs: [URL] = []
        while let fileURL = enumerator.nextObject() as? URL {
            guard enumerator.level <= 4,
                  (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                continue
            }
            let ext = fileURL.pathExtension.lowercased()
            if ext == "mobileprovision" || ext == "provisionprofile" {
                profileURLs.append(fileURL)
            } else if ext == "dylib" || ext == "deb" {
                if let tweakLib = environment.tweakLibrary,
                   let data = try? Data(contentsOf: fileURL),
                   case .success = (try? tweakLib.importPayload(data, fileName: fileURL.lastPathComponent, group: "Migrated")) {
                    report.tweaksCount += 1
                }
            } else if ext == "ipa" || ext == "tipa" {
                ipaQueue.append(fileURL)
            }
        }

        if let importer = environment.provisioningProfileImporter,
           let profilesLib = environment.provisioningProfiles {
            for url in profileURLs {
                if let summary = try? await importer.importProfile(at: url) {
                    try? await profilesLib.upsert(summary)
                    report.profilesCount += 1
                }
            }
        }

        if let rulesStore = environment.tweakAutoInjectRules {
            let rulesFile = folderURL.appendingPathComponent("TweakAutoInjectRules.json")
            if let data = try? Data(contentsOf: rulesFile),
               let rules = try? JSONDecoder().decode([TweakAutoInjectRule].self, from: data) {
                for rule in rules { try? rulesStore.saveRule(rule) }
            }
        }

        if !ipaQueue.isEmpty {
            _ = environment.importHub.receive(ipaQueue, origin: .documentPicker)
            report.packagesCount = ipaQueue.count
        }
        return report
    }

    private func discoverSourceURLs(in folderURL: URL) -> [String] {
        var found: Set<String> = []
        let jsonURL = folderURL.appendingPathComponent("Sources.json")
        if let data = try? Data(contentsOf: jsonURL),
           let list = try? JSONDecoder().decode([String].self, from: data) {
            for item in list where item.lowercased().hasPrefix("https://") {
                found.insert(item)
            }
        }
        for name in ["sources.txt", "Sources.txt", "repos.txt"] {
            let txtURL = folderURL.appendingPathComponent(name)
            if let text = try? String(contentsOf: txtURL, encoding: .utf8) {
                for line in text.components(separatedBy: .newlines) {
                    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.lowercased().hasPrefix("https://") {
                        found.insert(trimmed)
                    }
                }
            }
        }
        return found.sorted()
    }

    private func sanitizeFileName(_ raw: String) -> String {
        let filtered = raw.filter { ch in
            ch.isLetter || ch.isNumber || ch == "-" || ch == "_" || ch == "."
        }
        return filtered.isEmpty ? "Item" : String(filtered.prefix(60))
    }
}
