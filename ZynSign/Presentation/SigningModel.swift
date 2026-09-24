import Foundation
import Combine

/// The presentation-side state for the Signing area.
///
/// The model holds one signing run's inputs — a library package, a
/// provisioning profile, and a signing identity — plus the validation and
/// run outcomes the view renders. It talks to exactly one application-layer
/// object, the `ApplicationSigning` facade, and it never touches storage,
/// keys, archives, or pipeline machinery itself.
///
/// Every message the model produces is its own fixed language: diagnostics
/// from below the boundary never reach the screen, and no message claims
/// trust, Apple acceptance, or installability.
@MainActor
final class SigningModel: ObservableObject {

    // MARK: State types

    /// What the screen is doing right now.
    enum Activity: Equatable {
        /// Library and identity lists are being read.
        case loading
        /// Nothing is running.
        case idle
        /// A profile is being validated or an identity is being created.
        case working
        /// The signing pipeline is running.
        case signing
    }

    /// The settled result of one signing run, for display.
    struct Outcome: Equatable {
        /// The outcome's shape.
        enum Kind: Equatable {
            /// Every stage passed and a container was delivered.
            case signed
            /// A pipeline stage refused the run; nothing was delivered.
            case refused(stage: String)
            /// The run could not be attempted.
            case failed
        }

        let kind: Kind
        let headline: String
        let detail: String
        let outputURL: URL?
    }

    // MARK: Published state

    /// Library entries whose package files are present, offerable as
    /// signing sources.
    @Published private(set) var entries: [LibraryEntry] = []

    /// Identities registered in the device's Keychain store.
    @Published private(set) var identities: [SigningIdentity] = []

    /// The chosen source package.
    @Published var selectedEntry: LibraryEntry?

    /// The chosen signing identity.
    @Published var selectedIdentity: SigningIdentity?

    /// The selected profile's bytes, kept only while a profile is loaded.
    @Published private(set) var profileData: Data?

    /// The selected profile file's name, for display.
    @Published private(set) var profileFileName: String?

    /// The standalone validation result for the selected profile.
    @Published private(set) var profileResult: ProvisioningProfilePipelineResult?

    /// What the screen is doing.
    @Published private(set) var activity: Activity = .loading

    /// The settled outcome of the last signing run, if any.
    @Published private(set) var outcome: Outcome?

    /// A fixed-language problem with the selected profile file.
    @Published private(set) var profileProblem: String?

    /// A fixed-language problem with identity creation.
    @Published private(set) var identityProblem: String?

    // MARK: Dependencies

    private let signing: ApplicationSigning
    private let library: ApplicationLibrary

    init(signing: ApplicationSigning, library: ApplicationLibrary) {
        self.signing = signing
        self.library = library
        Task { await refresh() }
    }

    // MARK: Loading

    /// Reloads the offerable packages and the registered identities.
    /// A failure to read either list leaves the screen empty rather than
    /// stale: nothing here is guessed.
    func refresh() async {
        activity = .loading
        let loaded = (try? await library.entries()) ?? []
        entries = loaded.filter(\.isArtifactAvailable)
        if let selected = selectedEntry,
           !entries.contains(where: { $0.record.id == selected.record.id }) {
            selectedEntry = nil
        }
        identities = (try? signing.identities()) ?? []
        if let chosen = selectedIdentity,
           !identities.contains(where: { $0.id == chosen.id }) {
            selectedIdentity = nil
        }
        activity = .idle
    }

    // MARK: Profile

    /// Reads the profile document the picker produced and validates it
    /// standalone. The read is security-scoped exactly like package
    /// import, and the scope is released before returning.
    func chooseProfile(at url: URL) {
        guard activity == .idle || activity == .working else { return }
        activity = .working
        profileProblem = nil
        outcome = nil

        let scoped = url.startAccessingSecurityScopedResource()
        let data: Data
        do {
            defer {
                if scoped {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw ProfileReadError.unavailable
            }
            let read = try Data(contentsOf: url)
            guard read.count <= 2_097_152 else {
                throw ProfileReadError.tooLarge
            }
            data = read
        } catch ProfileReadError.unavailable {
            profileProblem = "The selected profile file is no longer available."
            activity = .idle
            return
        } catch ProfileReadError.tooLarge {
            profileProblem = "The selected file is larger than a provisioning profile should be."
            activity = .idle
            return
        } catch {
            profileProblem = "The selected profile file could not be read."
            activity = .idle
            return
        }

        let identityID = selectedIdentity?.id
        let signing = self.signing
        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try signing.validate(profile: data, identityID: identityID)
                }.value
                profileData = data
                profileFileName = url.lastPathComponent
                profileResult = result
                profileProblem = nil
            } catch {
                profileData = nil
                profileFileName = nil
                profileResult = nil
                profileProblem = "The profile could not be validated."
            }
            activity = .idle
        }
    }

    /// Forgets the selected profile.
    func clearProfile() {
        profileData = nil
        profileFileName = nil
        profileResult = nil
        profileProblem = nil
        outcome = nil
    }

    // MARK: Identity

    /// Creates a development identity in this device's Keychain and
    /// selects it.
    func createIdentity() {
        guard activity == .idle || activity == .working else { return }
        activity = .working
        identityProblem = nil
        Task {
            do {
                let created = try await signing.createDevelopmentIdentity()
                identities = (try? signing.identities()) ?? []
                selectedIdentity = identities.first { $0.id == created }
                    ?? selectedIdentity
            } catch {
                identityProblem = "A development identity could not be created on this device."
            }
            activity = .idle
        }
    }

    // MARK: Signing

    /// Runs the nine-stage pipeline over the current inputs.
    func runSigning() {
        guard activity == .idle,
              let entry = selectedEntry,
              let identity = selectedIdentity,
              let profile = profileData else {
            return
        }
        activity = .signing
        outcome = nil
        Task {
            do {
                let result = try await signing.sign(
                    entry: entry,
                    profile: profile,
                    identityID: identity.id
                )
                outcome = Self.outcome(for: result)
            } catch is CancellationError {
                outcome = nil
            } catch {
                outcome = Outcome(
                    kind: .failed,
                    headline: "Signing Did Not Run",
                    detail: "The pipeline could not be started for these inputs. Nothing was delivered.",
                    outputURL: nil
                )
            }
            activity = .idle
        }
    }

    /// Maps the pipeline's typed result into display language. Stage
    /// details are the pipeline's own fixed diagnostics and are safe to
    /// show; nothing here upgrades a result into trust or installability.
    static func outcome(for result: SignApplicationResult) -> Outcome {
        switch result.status {
        case .signed:
            return Outcome(
                kind: .signed,
                headline: "Container Delivered",
                detail: "Every pipeline stage passed and ZynSign's own verifier checked the output. This is not an Apple acceptance, not a trust statement, and not an installation.",
                outputURL: result.outputURL
            )
        case .failed:
            let failure = result.failure
            let stage = failure?.stage.rawValue ?? "unknown"
            return Outcome(
                kind: .refused(stage: stage),
                headline: "Refused at \(stage)",
                detail: failure?.detail
                    ?? "The pipeline refused the run. Nothing was delivered.",
                outputURL: nil
            )
        }
    }

    // MARK: Display helpers

    /// The name shown for a library entry.
    static func displayName(for entry: LibraryEntry) -> String {
        let identity = entry.record.identity
        if let name = identity.displayName {
            return name
        }
        return identity.bundleIdentifier.rawValue
    }

    /// The name shown for an identity.
    static func displayName(for identity: SigningIdentity) -> String {
        identity.certificate.subjectCommonName
            ?? identity.id.rawValue
    }
}

/// The model's own read-failure vocabulary; platform text never crosses.
private enum ProfileReadError: Error {
    case unavailable
    case tooLarge
}
