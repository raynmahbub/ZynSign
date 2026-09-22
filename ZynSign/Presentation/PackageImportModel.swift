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
/// The model owns no storage. An accepted package is taken into the library
/// by the import use case and reached through its record from then on; a
/// rejected, duplicate, failed, or cancelled import leaves nothing behind.
/// There is nothing for the model to retain or release.
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

    /// What the success screen shows: what arrived, what the package's
    /// application declares about itself, and what the library did with
    /// it. Display values only — no locations, signatures, or trust claims.
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

        /// A user-presentable statement of the library's decision.
        let libraryMessage: String
    }

    /// The current phase of the import.
    @Published private(set) var phase: Phase = .idle

    /// An action performed on the main actor whenever the import reaches a
    /// settled phase — `succeeded`, `failed`, or `cancelled` — so a screen
    /// that embeds the import can react to the outcome without watching the
    /// phase machine itself. The hook is invoked after the phase is
    /// published. The default is no action.
    var onSettlement: (@MainActor (Phase) -> Void)?

    private let importing: IPAPackageImport
    private var importTask: Task<Void, Never>?

    init(importing: IPAPackageImport) {
        self.importing = importing
    }

    // MARK: - Transitions

    /// Begins importing the document the user selected.
    func beginImport(from source: URL) {
        guard phase != .importing else { return }
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
            settle(to: .cancelled)
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
            let result = try await importing.importArtifact(from: source)
            if result.isAccepted {
                settle(to: .succeeded(Self.summary(for: result)))
            } else {
                settle(to: .failed(Self.rejectionMessage(for: result.artifact)))
            }
        } catch is CancellationError {
            settle(to: .cancelled)
        } catch let error as ZynSignError where error.category == .cancelled {
            settle(to: .cancelled)
        } catch let error as ZynSignError {
            settle(to: .failed(error.userMessage))
        } catch {
            // A foreign error's text is never rendered.
            settle(to: .failed("The import could not be completed."))
        }
    }

    /// Publishes a settled phase — one of the terminal outcomes — and
    /// reports it to the settlement hook. Transitional phases are assigned
    /// directly and are not reported.
    private func settle(to newPhase: Phase) {
        phase = newPhase
        switch newPhase {
        case .idle, .importing:
            break
        case .succeeded, .failed, .cancelled:
            onSettlement?(newPhase)
        }
    }

    // MARK: - Rendering

    /// Derives the success summary from the import result. The artifact is
    /// the record of what arrived; the summary is only its display half.
    static func summary(for result: PackageImportResult) -> Summary {
        let identity = result.artifact.metadata?.identity
        return Summary(
            sourceFileName: result.artifact.sourceFileName,
            displayName: identity?.displayName,
            bundleIdentifier: identity?.bundleIdentifier.rawValue,
            marketingVersion: identity?.shortVersionString,
            buildVersion: identity?.buildVersion,
            libraryMessage: Self.libraryMessage(for: result.admission)
        )
    }

    /// Composes the user-facing statement of the library's decision. The
    /// wording describes what was stored and what it relates to; it makes no
    /// claim about signatures, trust, or installability.
    static func libraryMessage(for admission: LibraryAdmission?) -> String {
        switch admission {
        case .none:
            return "The package was not added to ZynSign's library."
        case .some(.alreadyRecorded):
            return "This exact package is already in ZynSign's library, so it was not added again."
        case .some(.recorded(_, let relation)):
            switch relation {
            case .unrelated:
                return "The package was added to ZynSign's library."
            case .otherVersions(let others):
                let count = others.count
                return count == 1
                    ? "The package was added to ZynSign's library alongside one other version of this application."
                    : "The package was added to ZynSign's library alongside \(count) other versions of this application."
            case .sameDeclaredVersion:
                return "The package was added to ZynSign's library. An earlier import declares the same version and build but has different content; both are kept."
            }
        }
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
