import Foundation
import XCTest
@testable import ZynSign

// MARK: - Bundle information fixtures

/// Builds bundle information file content for import tests.
///
/// Every fixture is synthetic: the identifiers, names, and versions are
/// invented literals, and no real package, signing material, or certificate
/// appears anywhere in the suite.
enum ImportFixtures {

    /// Builds a property list declaring exactly the supplied values.
    static func infoPlistData(
        identifier: String = "com.example.synthetic",
        displayName: String? = nil,
        bundleName: String? = nil,
        shortVersion: String? = nil,
        buildVersion: String? = nil,
        executableName: String? = nil
    ) -> Data {
        var dictionary: [String: Any] = ["CFBundleIdentifier": identifier]
        if let displayName { dictionary["CFBundleDisplayName"] = displayName }
        if let bundleName { dictionary["CFBundleName"] = bundleName }
        if let shortVersion { dictionary["CFBundleShortVersionString"] = shortVersion }
        if let buildVersion { dictionary["CFBundleVersion"] = buildVersion }
        if let executableName { dictionary["CFBundleExecutable"] = executableName }
        do {
            return try PropertyListSerialization.data(
                fromPropertyList: dictionary,
                format: .xml,
                options: 0
            )
        } catch {
            preconditionFailure("Test fixture plist could not be encoded: \(error)")
        }
    }

    /// A complete bundle information file: identity, display name, versions,
    /// and a declared executable.
    static let completeInfoPlistData = infoPlistData(
        displayName: "Example",
        shortVersion: "1.2",
        buildVersion: "34",
        executableName: "Example"
    )

    /// The entry table of a package whose declared metadata reads cleanly.
    static func validEntryTable(metadata: Data = completeInfoPlistData) -> [ArchiveEntry] {
        [
            makeEntry(IPALayout.payloadDirectoryName, kind: .directory),
            makeEntry("Payload/Example.app", kind: .directory),
            makeEntry(
                "Payload/Example.app/\(IPALayout.bundleInformationFileName)",
                uncompressedSize: metadata.count,
                compressedSize: metadata.count
            ),
            makeEntry("Payload/Example.app/Example", uncompressedSize: 64, compressedSize: 64),
        ]
    }

    /// A container over the valid entry table whose declared metadata reads
    /// cleanly.
    static func validReader(metadata: Data = completeInfoPlistData) -> SyntheticArchiveReader {
        SyntheticArchiveReader(
            entryTable: validEntryTable(metadata: metadata),
            contentByPath: [
                "Payload/Example.app/\(IPALayout.bundleInformationFileName)": metadata,
            ]
        )
    }

    /// The entry table of a package that is a ZIP container in shape but
    /// carries no application.
    static func emptyPayloadReader() -> SyntheticArchiveReader {
        SyntheticArchiveReader(
            entryTable: [makeEntry(IPALayout.payloadDirectoryName, kind: .directory)]
        )
    }

    /// A well-formed package whose container cannot be enumerated.
    static func unreadableReader() -> SyntheticArchiveReader {
        SyntheticArchiveReader(
            entryTable: validEntryTable(),
            failure: .entryTableUnreadable
        )
    }

    /// A source URL carrying the accepted package extension.
    static func sourceURL(name: String = "Example.ipa") -> URL {
        URL(fileURLWithPath: "/synthetic-import-sources/\(name)")
    }

    /// Writes bytes to a fresh file inside `directory` and returns its URL.
    @discardableResult
    static func writeFile(
        named name: String,
        content: Data,
        in directory: URL
    ) -> URL {
        let url = directory.appendingPathComponent(name)
        do {
            try content.write(to: url, options: .atomic)
        } catch {
            preconditionFailure("Test fixture file could not be written: \(error)")
        }
        return url
    }

    /// The names of the files currently in `directory`.
    static func fileNames(in directory: URL) -> Set<String> {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )) ?? []
        return Set(contents.map { $0.lastPathComponent })
    }
}

// MARK: - Intake double

/// An `ArtifactIntake` double that records staging decisions and can be
/// driven into deterministic cancellation states.
///
/// It exists so import orchestration can be exercised without a filesystem,
/// and so the two cancellation windows — during staging, and after staging
/// completes — can be produced on demand instead of by racing a real copy.
///
/// When an `artifactStore` is attached, a completed staging places
/// `nextStagedContent` in that store's staging area under the artifact's
/// identifier and a discard removes it again, mirroring the shared staging
/// directory the composition root binds the real intake and artifact store
/// to. The library can then describe and adopt what the intake staged.
final class SyntheticIntake: ArtifactIntake {

    /// The staging behaviour of the next call.
    enum Behaviour {
        /// Stages normally.
        case stages

        /// Throws the prepared error immediately, staging nothing.
        case fails

        /// Spins until the surrounding task is cancelled, then throws a
        /// cancelled error — the window while the copy runs.
        case waitsUntilCancelledThenFails

        /// Spins until the surrounding task is cancelled, then returns
        /// normally — the window between the copy completing and the use
        /// case's next cancellation check.
        case waitsUntilCancelledThenSucceeds
    }

    private let lock = NSLock()

    var behaviour: Behaviour = .stages
    var preparedError: any Error = ZynSignError.selectedFileUnavailable(
        diagnosticDetail: "synthetic intake failure"
    )

    /// What `describeDocument(at:)` reports. The defaults describe what a
    /// deliberate selection of a package looks like: a regular file whose
    /// leading bytes are an archive signature, as large as the content that
    /// staging will place.
    var describedKind: ImportSourceDescription.Kind = .regularFile
    var describedByteCount: Int?
    var describedBeginsWithArchiveSignature: Bool? = true

    /// Thrown by `describeDocument(at:)` instead of returning a description,
    /// for exercising the pre-import refusal path.
    var describeError: (any Error)?

    /// The progress a completed staging reports, in order, before the copy
    /// finishes. Empty by default: nothing is reported unless a test asks for
    /// it, so existing expectations about staging are unchanged.
    var progressReports: [ImportProgress] = []

    /// The artifact store sharing this intake's staging area, if any.
    var artifactStore: SyntheticLibraryArtifactStore?

    /// The bytes the next completed staging places in the shared staging
    /// area. Distinct content produces distinct fingerprints.
    var nextStagedContent = Data("synthetic package content".utf8)

    private var stagedIDs: [ArtifactIdentifier] = []
    private var attemptedIDs: [ArtifactIdentifier] = []
    private var discardedIDs: [ArtifactIdentifier] = []

    /// Artifacts whose staging completed.
    var staged: [ArtifactIdentifier] {
        lock.withLock { stagedIDs }
    }

    /// Artifacts staging was attempted for, completed or not.
    var attempted: [ArtifactIdentifier] {
        lock.withLock { attemptedIDs }
    }

    /// Artifacts whose staged archive was discarded.
    var discarded: [ArtifactIdentifier] {
        lock.withLock { discardedIDs }
    }

    func describeDocument(at source: URL) throws -> ImportSourceDescription {
        if let describeError {
            throw describeError
        }
        return ImportSourceDescription(
            fileName: source.lastPathComponent,
            byteCount: describedByteCount ?? nextStagedContent.count,
            kind: describedKind,
            beginsWithArchiveSignature: describedBeginsWithArchiveSignature
        )
    }

    func stageDocument(
        at source: URL,
        as artifact: ArtifactIdentifier,
        reporting progress: (any ImportProgressReporting)?
    ) throws {
        lock.withLock { attemptedIDs.append(artifact) }

        switch behaviour {
        case .stages:
            reportProgress(progress)
            completeStaging(of: artifact)

        case .fails:
            throw preparedError

        case .waitsUntilCancelledThenFails:
            waitUntilCancelled()
            throw ZynSignError.importCancelled()

        case .waitsUntilCancelledThenSucceeds:
            waitUntilCancelled()
            reportProgress(progress)
            completeStaging(of: artifact)
        }
    }

    /// Delivers the configured reports in the order they were set, so a test
    /// can present the queue with out-of-order or regressing reports without
    /// needing a real copy whose timing it cannot control.
    private func reportProgress(_ progress: (any ImportProgressReporting)?) {
        guard let progress else { return }
        for report in progressReports {
            progress.report(report)
        }
    }

    func discardStagedDocument(for artifact: ArtifactIdentifier) {
        lock.withLock { discardedIDs.append(artifact) }
        artifactStore?.unstage(artifact)
    }

    private func completeStaging(of artifact: ArtifactIdentifier) {
        lock.withLock { stagedIDs.append(artifact) }
        artifactStore?.stage(nextStagedContent, as: artifact)
    }

    /// Blocks the calling thread until the surrounding task is cancelled.
    /// Used only from tests, where a cooperative worker blocking briefly is
    /// safe, because the test cancels the task from another actor.
    private func waitUntilCancelled() {
        while !Task.isCancelled {
            Thread.sleep(forTimeInterval: 0.005)
        }
    }
}
