import Foundation

/// What the sideloading features need before they can work, stated per
/// capability instead of as one "unsupported" badge.
///
/// ZynSign used to answer three questions with one word: pairing, JIT and the
/// multiplexer were "never", because a sandboxed app has no public route to
/// lockdownd. That was true for the App Store build and it is still true
/// there. It is *not* the whole truth for this product: ZynSign is a
/// sideloading tool, its builds are self-signed, and a build whose signing
/// identity carries a Network Extension entitlement can carry a local tunnel
/// to the device's own lockdownd, which is how an on-device install reaches
/// the installer. The difference matters, so the assessment names the
/// requirement instead of denying the capability.
///
/// Nothing here claims a device has accepted anything. Each capability
/// reports the requirements it has, the ones it is missing, and the evidence
/// the app actually holds.
enum SideloadingCapability: String, CaseIterable, Hashable, Sendable {

    /// Read a `.mobiledevicepairing` record and use it as the TLS identity.
    case devicePairing
    /// Start a lockdownd session and reach AFC / installation_proxy.
    case deviceSession
    /// Install a signed `.ipa` through installation_proxy.
    case packageInstallation
    /// Run a guest bundle inside the host (the container).
    case guestContainer
    /// Inject a library into a signed binary's load commands.
    case libraryInjection
    /// Sign with no certificate (`CS_ADHOC`).
    case adHocSigning

    var title: String {
        switch self {
        case .devicePairing: return "Pairing record prerequisites"
        case .deviceSession: return "Device session"
        case .packageInstallation: return "Package installation"
        case .guestContainer: return "Guest container"
        case .libraryInjection: return "Library injection"
        case .adHocSigning: return "Ad-hoc signing"
        }
    }

    var summary: String {
        switch self {
        case .devicePairing:
            return "A pairing record can be imported. Authenticated device sessions are not yet available."
        case .deviceSession:
            return "A lockdownd session requires authenticated TLS and complete, bounded message framing; this transport is not yet available."
        case .packageInstallation:
            return "Direct AFC and installation_proxy delivery is unavailable until the device transport is verified."
        case .guestContainer:
            return "The guest is patched to MH_DYLIB, has the loader linked in, is signed "
                + "ad-hoc, and is mapped by the host with dlopen."
        case .libraryInjection:
            return "An LC_LOAD_DYLIB command is written into the image's header padding "
                + "before the CodeDirectory is built, so the hash covers it."
        case .adHocSigning:
            return "A CodeDirectory with CS_ADHOC and no CMS blob. No certificate chain "
                + "exists, so a stock installer refuses it."
        }
    }

    /// One thing a capability needs. Requirements are facts about the build or
    /// the device, and each has a message a screen can show verbatim.
    enum Requirement: String, CaseIterable, Hashable, Sendable {
        /// A `.mobiledevicepairing` record imported by the user.
        case pairingRecord
        /// A local tunnel to the device's lockdownd (Network Extension).
        case localTunnelEntitlement
        /// The build's provisioning profile carries that entitlement.
        case entitledBuild
        /// A transport that can carry usbmux frames to the tunnel.
        case deviceTransport
        /// `TweakLoader.dylib` shipped inside the app bundle.
        case bundledLoader
        /// An image with enough header padding for the command.
        case headerPadding
        /// The guest image is not FairPlay-encrypted.
        case decryptedGuest
        /// The device accepts a signature without a trusted chain.
        case deviceTrustsAdHoc

        var message: String {
            switch self {
            case .pairingRecord:
                return "A pairing record must be imported (it is a bearer credential; "
                    + "ZynSign keeps it in the Keychain)."
            case .localTunnelEntitlement:
                return "A Network Extension (packet tunnel) entitlement is needed to reach "
                    + "the device's own lockdownd; without it the sandbox has no route."
            case .entitledBuild:
                return "The entitlement must be in the provisioning profile that signed this "
                    + "build. App Store builds cannot carry it."
            case .deviceTransport:
                return "An authenticated device transport with complete framed reads must be implemented and verified."
            case .bundledLoader:
                return "A prebuilt signed TweakLoader.dylib must ship in the app bundle."
            case .headerPadding:
                return "The Mach-O must have free space between its load commands and its "
                    + "first section."
            case .decryptedGuest:
                return "FairPlay-encrypted binaries cannot be loaded by the host."
            case .deviceTrustsAdHoc:
                return "Only a device that permits ad-hoc code (or a container that never "
                    + "asks the installer) can use this signature."
            }
        }
    }

    /// The evidence the assessment reads. `nil` means "not established",
    /// which is never the same as "met".
    struct Evidence: Equatable, Sendable {
        let hasPairingRecord: Bool?
        let buildCarriesLocalTunnelEntitlement: Bool?
        let transportComposed: Bool?
        let loaderBundled: Bool?
        let targetHeaderPadding: Int?
        let guestDecrypted: Bool?
        let deviceAcceptsAdHoc: Bool?

        init(
            hasPairingRecord: Bool? = nil,
            buildCarriesLocalTunnelEntitlement: Bool? = nil,
            transportComposed: Bool? = nil,
            loaderBundled: Bool? = nil,
            targetHeaderPadding: Int? = nil,
            guestDecrypted: Bool? = nil,
            deviceAcceptsAdHoc: Bool? = nil
        ) {
            self.hasPairingRecord = hasPairingRecord
            self.buildCarriesLocalTunnelEntitlement = buildCarriesLocalTunnelEntitlement
            self.transportComposed = transportComposed
            self.loaderBundled = loaderBundled
            self.targetHeaderPadding = targetHeaderPadding
            self.guestDecrypted = guestDecrypted
            self.deviceAcceptsAdHoc = deviceAcceptsAdHoc
        }
    }

    /// One assessed capability: supported, or blocked by a named requirement.
    struct Assessment: Equatable, Sendable {
        let capability: SideloadingCapability
        let isSupported: Bool
        let unmetRequirements: [Requirement]
        let summary: String

        /// The one-line badge the settings row shows.
        var label: String {
            isSupported ? "Available" : "Needs \(unmetRequirements.count) requirement"
                + (unmetRequirements.count == 1 ? "" : "s")
        }
    }

    static func assess(_ capability: SideloadingCapability,
                       evidence: Evidence) -> Assessment {
        let unmet = unmetRequirements(for: capability, evidence: evidence)
        return Assessment(
            capability: capability,
            isSupported: unmet.isEmpty,
            unmetRequirements: unmet,
            summary: unmet.isEmpty
                ? "\(capability.title) is available in this build."
                : "\(capability.title): \(unmet[0].message)"
        )
    }

    static func all(evidence: Evidence) -> [Assessment] {
        allCases.map { assess($0, evidence: evidence) }
    }

    private static func unmetRequirements(for capability: SideloadingCapability,
                                          evidence: Evidence) -> [Requirement] {
        func unmet(_ condition: Bool?) -> Bool { condition != true }
        var requirements: [Requirement] = []
        switch capability {
        case .devicePairing:
            if unmet(evidence.hasPairingRecord) { requirements.append(.pairingRecord) }
            if unmet(evidence.buildCarriesLocalTunnelEntitlement) {
                requirements.append(.localTunnelEntitlement)
                requirements.append(.entitledBuild)
            }
        case .deviceSession:
            if unmet(evidence.hasPairingRecord) { requirements.append(.pairingRecord) }
            if unmet(evidence.buildCarriesLocalTunnelEntitlement) {
                requirements.append(.localTunnelEntitlement)
            }
            if unmet(evidence.transportComposed) { requirements.append(.deviceTransport) }
        case .packageInstallation:
            if unmet(evidence.hasPairingRecord) { requirements.append(.pairingRecord) }
            if unmet(evidence.buildCarriesLocalTunnelEntitlement) {
                requirements.append(.localTunnelEntitlement)
            }
            if unmet(evidence.transportComposed) { requirements.append(.deviceTransport) }
        case .guestContainer:
            if unmet(evidence.loaderBundled) { requirements.append(.bundledLoader) }
            if unmet(evidence.guestDecrypted) { requirements.append(.decryptedGuest) }
        case .libraryInjection:
            if let padding = evidence.targetHeaderPadding, padding < 40 {
                requirements.append(.headerPadding)
            }
        case .adHocSigning:
            // Signing always works; whether anything accepts the result is a
            // separate fact, reported rather than assumed.
            if evidence.deviceAcceptsAdHoc == false {
                requirements.append(.deviceTrustsAdHoc)
            }
        }
        return requirements
    }
}

/// The statements the app must keep saying even when a build is entitled.
///
/// `SideloadingCapability` answers "can this build try?". This type answers
/// "what is still true regardless?", so the honesty does not depend on which
/// screen is asking.
enum SideloadingTruth {

    static let statements = [
        "Installing through installation_proxy is the device's decision; "
            + "ZynSign observes only what the device reports.",
        "A pairing record is a bearer credential. Anyone who copies it can talk "
            + "to that device; ZynSign keeps it in the Keychain and never logs it.",
        "An ad-hoc signature has no certificate chain. A stock device refuses it; "
            + "the container path never asks the installer.",
        "A container runs the guest inside ZynSign's process. The guest's data stays "
            + "in the container; the host's data is never handed to it.",
        "Library injection rewrites the image before it is signed, so the signature "
            + "covers the injected command. An image without header space is refused.",
    ]

    /// The sentence a screen shows when installation is unavailable, so the
    /// app never claims an install it did not perform.
    static let installationEvidenceRule =
        "An app is listed as installed only after the device reports Complete."

    static let containerEvidenceRule =
        "A guest is listed as runnable only when every block in its assessment is clear."

    /// The statements the refresh ledger adds. A countdown is only useful if the
    /// screen is honest about what it is counting: a date the profile declared,
    /// not a promise that the app will launch on the device.
    static let leaseStatements = [
        "A countdown is the profile's own expiry, read from the signing journal. "
            + "ZynSign does not know whether the build is still installed.",
        "Re-signing produces a new package. Replacing the installed one is the "
            + "device's installer's job, and ZynSign reports only what it answers.",
        "A free personal team issues seven-day profiles and holds three apps at "
            + "once; a paid membership issues year-long ones.",
        "Removing an app from the library leaves the journal's record of it. "
            + "The lease stays and says it cannot be signed again from here.",
    ]
}
