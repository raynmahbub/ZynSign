import Foundation
import Combine

/// The presentation-side state machine for one package import.
///
/// The import has exactly one phase at a time — idle, importing, succeeded,
/// failed, or cancelled — so no combination of independent flags can
/// describe an impossible state. The phase is the only thing the view reads.
///
/// The model coordinates nothing itself: it hands the selected document to
/// the application-layer import use case and renders the outcome. Work runs
/// off the main actor inside the use case; every phase transition happens
/// here, on the main actor.
///
/// Staged-archive ownership lives here too. An accepted import's archive is
/// retained for as long as its result is shown, released when the result is
/// replaced by another accepted import or when the model is dropped. The
/// model never assumes any other owner will clean up.
@MainActor
final class PackageImportModel: ObservableObject {

    /// The phase of the import, rendered directly by the view.
    enum Phase: Equatable {

        /// Nothing has been selected yet.
        case idle

        /// A package is being staged and examined.
        case importing

        /// The import completed and the package was accepted.
        case succeeded(Summary)

        /// The import ended without an accepted package. Carries a
        /// user-presentable explanation, never diagnostic detail.
        case failed(String)

        /// The user closed the picker without choosing, or cancelled a
        /// running import. An ordinary outcome, not an error.
        case cancelled
    }

    /// What the success screen shows: what arrived, and what the package's
    /// application declares about itself. Display values only — no
    /// locations, signatures, or trust claims.
    struct Summary: Equatable {

        /// The selected file's name, when one was available.
        let sourceFileName: String?

        /// The application's declared display name, after the domain's
        /// deterministic fallback policy, or `nil` when it declared none.
        let displayName: String?

        /// The application's declared bundle identifier.
        let bundleIdentifier: String?

        /// The declared marketing version, or `nil` when undeclared.
        let marketingVersion: String?

        /// The declared build version, or `nil` when undeclared.
        let buildVersion: String?
    }

    /// The current phase of the import.
    @Published private(set) var phase: Phase = .idle

    private let importing: IPAPackageImport
    private var importTask: Task<Void, Never>?

    /// The identifier of the staged archive this model currently owns, if
    /// any. Released explicitly; see `releaseRetainedArchive` and `deinit`.
    private var retainedArtifactID: ArtifactIdentifier?

    init(importing: IPAPackageImport) {
        self.importing = importing
    }

    deinit {
        if let retainedArtifactID {
            importing.discardStagedArtifact(retainedArtifactID)
        }
    }

    // MARK: - Transitions

    /// Begins importing the document the user selected.
    ///
    /// Any staged archive the model currently owns is released first: its
    /// result is being replaced, and a large file must not linger in
    /// temporary storage behind whatever this import turns out to be.
    func beginImport(from source: URL) {
        guard phase != .importing else { return }
        releaseRetainedArchive()
        phase = .importing
        importTask = Task {
            await runImport(from: source)
        }
    }

    /// Records how the system document picker closed. Closing the picker
    /// without a selection is reported by the picker as a failure, but it is
    /// an ordinary user cancellation; genuine access problems surface later,
    /// during staging, as typed errors.
    func handlePickerResult(_ result: Result<URL, any Error>) {
        switch result {
        case .success(let source):
            beginImport(from: source)
        case .failure:
            phase = .cancelled
        }
    }

    /// Cancels a running import. The phase becomes `cancelled` when the
    /// running task observes the cancellation and stops.
    func cancelImport() {
        guard phase == .importing else { return }
        importTask?.cancel()
    }

    // MARK: - Import

    private func runImport(from source: URL) async {
        do {
            let artifact = try await importing.importArtifact(from: source)
            if artifact.permitsLaterStages {
                retainStagedArchive(of: artifact)
                phase = .succeeded(Self.summary(for: artifact))
            } else {
                retainedArtifactID = nil
                phase = .failed(Self.rejectionMessage(for: artifact))
            }
        } catch is CancellationError {
            phase = .cancelled
        } catch let error as ZynSignError where error.category == .cancelled {
            phase = .cancelled
        } catch let error as ZynSignError {
            phase = .failed(error.userMessage)
        } catch {
            // A foreign error's text is never rendered.
            phase = .failed("The import could not be completed.")
        }
    }

    /// Transfers ownership of the newly accepted import's staged archive to
    /// this model, releasing the archive of any result it replaces.
    private func retainStagedArchive(of artifact: IPAArtifact) {
        if let retainedArtifactID, retainedArtifactID != artifact.id {
            importing.discardStagedArtifact(retainedArtifactID)
        }
        retainedArtifactID = artifact.id
    }

    // MARK: - Rendering

    /// Derives the success summary from the examined artifact. The artifact
    /// is the record of what arrived; the summary is only its display half.
    static func summary(for artifact: IPAArtifact) -> Summary {
        let identity = artifact.metadata?.identity
        return Summary(
            sourceFileName: artifact.sourceFileName,
            displayName: identity?.displayName,
            bundleIdentifier: identity?.bundleIdentifier.rawValue,
            marketingVersion: identity?.shortVersionString,
            buildVersion: identity?.buildVersion
        )
    }

    /// Composes the user-facing explanation for a rejected package from its
    /// primary rejecting finding. Findings' technical details are
    /// diagnostics and are never shown; this mapping is the only place the
    /// two vocabularies meet.
    static func rejectionMessage(for artifact: IPAArtifact) -> String {
        guard let code = artifact.validation?.errors.first?.code else {
            return "This file is not a valid application package."
        }
        switch code {
        case .unreadableArchive:
            return "The file could not be read as a package archive."
        case .unsafePath, .conflictingPaths:
            return "The package contains entries ZynSign cannot safely read."
        case .missingPayloadDirectory, .missingApplicationBundle:
            return "No application was found inside the package."
        case .multipleApplicationBundles:
            return "The package contains more than one application, so it cannot be imported."
        case .missingInfoPlist:
            return "The application inside the package is missing required information."
        case .unreadableInfoPlist:
            return "The application's information file could not be read."
        case .malformedMetadata, .missingRequiredMetadata:
            return "The application's declared information is incomplete or malformed."
        case .unsupportedMetadataFormat, .unsupportedArchiveFeature:
            return "The package uses features ZynSign does not support."
        case .resourceLimitExceeded:
            return "The package is larger or more complex than ZynSign can inspect."
        case .inconsistentMetadata, .missingExecutable:
            return "The application's declared information does not match its content."
        }
    }
}
