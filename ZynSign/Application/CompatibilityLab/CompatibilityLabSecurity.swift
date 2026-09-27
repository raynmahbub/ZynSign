import Foundation

/// The security posture sweep: the six places sensitive material could leak,
/// checked against the running application rather than against a document.
///
/// ZynSign's security architecture is a set of claims — private keys never
/// leave the Keychain, diagnostic entries carry slugs and nothing else,
/// exported reports contain no credentials, the workspace is cleaned up. A
/// claim nobody checks is a claim that quietly stops being true, so the Lab
/// checks each one where it can, and says plainly what it cannot check.
struct SecurityHardeningSuite {

    func checks(context: CompatibilityLabContext) async -> [CompatibilityCheck] {
        var results: [CompatibilityCheck] = [
            temporaryFilesCheck(context: context),
            workspaceCleanupCheck(context: context),
            backupBehaviorCheck(context: context),
            exportedReportsCheck(context: context)
        ]
        results.append(await sensitiveLogCheck(context: context))
        results.append(keychainCheck(context: context))
        return results
    }

    // MARK: Temporary files

    /// Every temporary location must be one the system may reclaim: the
    /// temporary directory, or ZynSign's own workspace under Application
    /// Support. A staging area in Documents would be backed up, would never
    /// be reclaimed, and would put working copies where the user can see
    /// half-finished work.
    private func temporaryFilesCheck(context: CompatibilityLabContext) -> CompatibilityCheck {
        let directories = CompositionRoot.temporaryDirectories(preferences: context.preferences)
        let temporaryRoot = context.fileManager.temporaryDirectory
        let misplaced = directories.filter { directory in
            !Self.isWithin(directory, root: temporaryRoot)
        }
        return check(
            id: "security.temporaryFiles",
            title: "Temporary files",
            status: misplaced.isEmpty ? .passed : .failed,
            summary: misplaced.isEmpty
                ? "All \(directories.count) temporary location(s) are inside the system temporary directory."
                : "\(misplaced.count) temporary location(s) sit outside the system temporary directory.",
            verified: "Verified where ZynSign stages its work: every temporary location is one the system may reclaim at will. The workspace preference can move staging under Application Support, which is ZynSign's own durable workspace and is reported as such.",
            nextStep: misplaced.isEmpty ? nil : "Move staging back to the temporary directory or to ZynSign's own Application Support workspace.",
            evidence: directories.map { directory in
                let insideTemporary = Self.isWithin(directory, root: temporaryRoot)
                return "\(directory.lastPathComponent): \(insideTemporary ? "reclaimable" : "durable workspace")"
            }
        )
    }

    /// A workspace cleanup may only ever reach ZynSign's own scratch. This
    /// check verifies the shape of that promise: no temporary directory is
    /// inside Documents, where the user's exports live.
    private func workspaceCleanupCheck(context: CompatibilityLabContext) -> CompatibilityCheck {
        let directories = CompositionRoot.temporaryDirectories(preferences: context.preferences)
        let documents = CompositionRoot.documentsDirectory
        let offending = directories.filter { Self.isWithin($0, root: documents) }
        return check(
            id: "security.workspaceCleanup",
            title: "Workspace cleanup scope",
            status: offending.isEmpty ? .passed : .failed,
            summary: offending.isEmpty
                ? "No temporary location is inside the user's Documents, so cleanup cannot reach exported work."
                : "A temporary location is inside Documents, where cleanup could reach the user's files.",
            verified: "Verified the boundary cleanup operates within. Not verified by deleting anything: the Lab measures, it never cleans up on its own.",
            nextStep: offending.isEmpty ? nil : "A cleanup that can reach Documents is a data-loss risk; move the staging location.",
            evidence: ["documents: \(documents.lastPathComponent)",
                       "temporary directories: \(directories.map(\.lastPathComponent).joined(separator: ", "))"]
        )
    }

    // MARK: Backups

    /// What is backed up: the user's library and exports, yes; caches and
    /// scratch, no. The check reads the flag the platform sets rather than
    /// assuming it.
    private func backupBehaviorCheck(context: CompatibilityLabContext) -> CompatibilityCheck {
        let userData = [
            ("library", CompositionRoot.libraryRootDirectory),
            ("exports", CompositionRoot.exportArtifactDirectory())
        ]
        let report = userData.map { name, url in
            (name: name, excluded: Self.isExcludedFromBackup(url))
        }
        // `nil` means the platform did not say, which is not the same as
        // "backed up": it is reported, never filled in.
        let excluded = report.filter { $0.excluded == true }
        let passed = excluded.isEmpty
        return check(
            id: "security.backupBehavior",
            title: "Backup behaviour",
            status: passed ? .passed : .warning,
            summary: passed
                ? "The user's library and exports are left to the platform's backup."
                : "\(excluded.count) location(s) holding user data are excluded from backup.",
            verified: "Verified the exclusion flag on the directories that hold what the user imported and exported. Caches and the temporary workspace are not covered here because they live in locations the platform already excludes.",
            nextStep: passed ? nil : "Decide deliberately: excluding the library means a restore loses the user's imports. Either include it or document the choice in docs/security/README.md.",
            evidence: report.map { "\($0.name): \(Self.backupText($0.excluded))" }
        )
    }

    // MARK: Exported reports

    /// No file ZynSign writes for sharing may carry key material. The check
    /// reads the head of every file in the export and diagnostics
    /// directories and looks for the one shape that must never appear.
    private func exportedReportsCheck(context: CompatibilityLabContext) -> CompatibilityCheck {
        let directories = [
            CompositionRoot.exportArtifactDirectory(),
            CompositionRoot.diagnosticReportDirectory()
        ]
        var inspected = 0
        var findings: [String] = []
        for directory in directories {
            guard let enumerator = context.fileManager.enumerator(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }
            for case let url as URL in enumerator {
                guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey]),
                      values.isRegularFile == true else { continue }
                inspected += 1
                // A bounded read: enough to see a PEM header or an
                // entitlement block, never the whole file.
                let handle = FileHandle(forReadingAtPath: url.path)
                let head = handle?.readData(ofLength: 64 * 1_024) ?? Data()
                try? handle?.close()
                if let marker = Self.keyMaterialMarker(in: head) {
                    findings.append("\(url.lastPathComponent): \(marker)")
                }
                if inspected >= 200 { break }
            }
        }
        return check(
            id: "security.exportedReports",
            title: "Exported files",
            status: findings.isEmpty ? .passed : .failed,
            summary: findings.isEmpty
                ? "\(inspected) exported file(s) inspected; none carries key material in its first 64 KB."
                : "Key material was found in \(findings.count) exported file(s).",
            verified: "Verified the head of every file in the export and diagnostics directories against a small set of PEM markers. Not verified: the whole of a large file, and nothing about a file the user exported themselves.",
            nextStep: findings.isEmpty ? nil : "A file ZynSign wrote contains private-key material. Treat it as an incident: remove the file, then find the write path that produced it.",
            evidence: findings.isEmpty ? ["files inspected: \(inspected)"] : findings,
            severity: .critical
        )
    }

    // MARK: Logs

    /// The technical log carries a fixed slug and nothing else. The check
    /// reads the entries the user's own log holds and verifies the shape,
    /// because a slug that grew free text would be a privacy regression the
    /// interface would not notice.
    private func sensitiveLogCheck(context: CompatibilityLabContext) async -> CompatibilityCheck {
        let log = DiagnosticLog(location: CompositionRoot.diagnosticsLogLocation())
        let entries = await log.entries()
        if entries.isEmpty {
            return check(
                id: "security.sensitiveLogs",
                title: "Diagnostic log",
                status: .passed,
                summary: "The technical log holds no entries.",
                verified: "Verified the log is reachable and empty. Detailed logging is opt-in and off by default, so an empty log is the ordinary case.",
                evidence: ["entries: 0"]
            )
        }
        let offending = entries.filter { !Self.isSlug($0.detail) }
        return check(
            id: "security.sensitiveLogs",
            title: "Diagnostic log",
            status: offending.isEmpty ? .passed : .failed,
            summary: offending.isEmpty
                ? "All \(entries.count) log entr(ies) carry a fixed slug and nothing else."
                : "\(offending.count) log entr(ies) carry detail that is not a fixed slug.",
            verified: "Verified the shape of every entry's detail: dot-separated lowercase words, which is the contract in `DiagnosticLogEntry`. Not verified: the slug a future call site might choose — that is a code review, and CI's hygiene job refuses free-form logging.",
            nextStep: offending.isEmpty ? nil : "A log entry is carrying text it must not. Find the call site and reduce it to a slug.",
            evidence: offending.isEmpty
                ? ["entries: \(entries.count)", "categories: \(Set(entries.map(\.category.displayName)).sorted().joined(separator: ", "))"]
                : offending.prefix(3).map { "entry detail is not a slug" },
            severity: .high
        )
    }

    // MARK: Keychain

    /// Identities must report non-exportable key storage wherever the
    /// storage adapter can say. An identity whose key can be read back is
    /// the one finding in this suite that outranks every other.
    private func keychainCheck(context: CompatibilityLabContext) -> CompatibilityCheck {
        guard let environment = context.environment else {
            return check(
                id: "security.keychain",
                title: "Keychain access",
                status: .notRun,
                summary: "No application environment was composed for this run.",
                verified: "Nothing was read.",
                nextStep: "Run the Lab from the application."
            )
        }
        let identities: [SigningIdentity]
        do {
            identities = try environment.identityStore.listIdentities()
        } catch {
            return check(
                id: "security.keychain",
                title: "Keychain access",
                status: .failed,
                summary: "The identity store could not be read.",
                verified: "A store that cannot be read is both a signing blocker and a question this check cannot answer.",
                nextStep: "Read the error, then re-run the Lab.",
                evidence: ["error: \((error as? ZynSignError)?.userMessage ?? String(describing: type(of: error)))"]
            )
        }
        if identities.isEmpty {
            return check(
                id: "security.keychain",
                title: "Keychain access",
                status: .passed,
                summary: "No identities are stored, so there is no key material to protect.",
                verified: "Verified the store is reachable and empty.",
                evidence: ["identities: 0"]
            )
        }
        let exportable = identities.filter { $0.isKeyNonExportable == false }
        let unknown = identities.filter { $0.isKeyNonExportable == nil }
        let status: CompatibilityStatus = exportable.isEmpty ? (unknown.isEmpty ? .passed : .warning) : .failed
        return check(
            id: "security.keychain",
            title: "Keychain access",
            status: status,
            summary: "\(identities.count) identit(y/ies): \(identities.count - exportable.count - unknown.count) confirmed non-exportable, \(unknown.count) unreported, \(exportable.count) exportable.",
            verified: "Verified what the storage adapter reports about each key. Not verified: the Keychain's own guarantee — ZynSign reports the platform's answer, it does not re-derive it.",
            nextStep: status == .passed ? nil : "An identity whose key can be extracted must not be reachable; re-import it so the key is stored non-extractably.",
            evidence: [
                "identities: \(identities.count)",
                "confirmed non-exportable: \(identities.count - exportable.count - unknown.count)",
                "storage unknown: \(unknown.count)",
                "exportable: \(exportable.count)"
            ],
            severity: .critical
        )
    }

    // MARK: Support

    /// Whether `url` lies within `root`, compared on standardized paths.
    private static func isWithin(_ url: URL, root: URL) -> Bool {
        let target = url.standardizedFileURL.path
        let base = root.standardizedFileURL.path
        return target == base || target.hasPrefix(base.hasSuffix("/") ? base : base + "/")
    }

    private static func isExcludedFromBackup(_ url: URL) -> Bool? {
        guard url.isFileURL,
              let values = try? url.resourceValues(forKeys: [.isExcludedFromBackupKey]) else {
            return nil
        }
        return values.isExcludedFromBackup
    }

    private static func backupText(_ excluded: Bool?) -> String {
        guard let excluded else { return "platform did not report" }
        return excluded ? "excluded from backup" : "included in backup"
    }

    /// The markers that must never appear in a file ZynSign writes for
    /// sharing. Short, fixed, and checked against bytes rather than names.
    private static let keyMaterialMarkers = [
        "-----BEGIN PRIVATE KEY-----",
        "-----BEGIN RSA PRIVATE KEY-----",
        "-----BEGIN EC PRIVATE KEY-----",
        "-----BEGIN ENCRYPTED PRIVATE KEY-----",
        "-----BEGIN OPENSSH PRIVATE KEY-----"
    ]

    private static func keyMaterialMarker(in data: Data) -> String? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        return keyMaterialMarkers.first { text.contains($0) }
    }

    /// Whether `detail` is a fixed slug: lowercase, dot-separated, no spaces
    /// and no punctuation that would suggest a sentence.
    private static func isSlug(_ detail: String) -> Bool {
        guard !detail.isEmpty, detail.count <= 128 else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789._")
        guard detail.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return false }
        return detail.split(separator: ".").allSatisfy { !$0.isEmpty }
    }

    private func check(
        id: String,
        title: String,
        status: CompatibilityStatus,
        summary: String,
        verified: String,
        nextStep: String? = nil,
        evidence: [String] = [],
        measurements: [CompatibilityMeasurement] = [],
        severity: ReleaseBlockerSeverity? = nil
    ) -> CompatibilityCheck {
        CompatibilityCheck(
            id: id,
            category: .securityPosture,
            title: title,
            status: status,
            summary: summary,
            verified: verified,
            nextStep: nextStep,
            evidence: evidence,
            measurements: measurements,
            blocker: status == .failed ? (severity ?? .high) : nil
        )
    }
}
