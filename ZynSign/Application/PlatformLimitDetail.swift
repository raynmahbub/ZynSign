import Foundation

/// One capability that this build does not offer, explained in the four parts a
/// person actually needs: what the capability requires, whose decision that
/// requirement is, what ships in its place, and where the evidence lives.
///
/// `UnsupportedFeature` is the inventory — three names in a list. This type is
/// the explanation behind each name, and it is deliberately *not* a roadmap: a
/// requirement an Apple-granted entitlement would have to satisfy is a
/// statement about the platform, not a promise about a future release. Nothing
/// here is composed into a button, and every "ships instead" entry points at
/// code that is already in the catalogue.
///
/// The wording is assembled from typed values the rest of the app already
/// publishes — `InstallationLimitation`, `PairingCapabilityAssessment`, and
/// `AnalyticsPolicy.Guarantee` — so the screen and the diagnostics cannot
/// describe the same limit in two different ways.
struct PlatformLimitDetail: Equatable, Sendable {

    /// What the capability needs before it could exist at all.
    let requirement: String

    /// What would have to change, and on whose side — the honest answer to
    /// "so can it be fixed?".
    let wouldHaveToChange: String

    /// What this build does instead. Never a stand-in that pretends to be the
    /// capability: a hand-off is not an installer, and a local journal is not
    /// telemetry.
    let instead: String

    /// The surfaces that carry the honest alternative, if any exist.
    let alternatives: [PlatformLimitAlternative]

    /// Typed facts from the code behind the limit, already worded. These are
    /// quoted from the capability types rather than re-worded here.
    let evidence: [String]
}

/// A surface that already exists and covers the part of a missing capability
/// that can be covered. Typed so a test can prove the named surface is on.
enum PlatformLimitAlternative: Sendable {

    /// An always-on capability from `CoreFeature`.
    case core(CoreFeature)

    /// A release-gated capability from `ReleaseFeature`.
    case released(ReleaseFeature)

    /// The catalogue name of the surface.
    var displayName: String {
        switch self {
        case .core(let feature): return feature.displayName
        case .released(let feature): return feature.displayName
        }
    }

    /// Whether the surface is on at the given gate. An alternative named by a
    /// limit has to be a surface a person can actually open today.
    func isAvailable(at gate: ReleaseGate) -> Bool {
        switch self {
        case .core: return true
        case .released(let feature): return gate.isAvailable(feature)
        }
    }
}

extension PlatformLimitAlternative: Equatable {

    /// Compared by catalogue identity rather than by synthesized conformance:
    /// `CoreFeature` carries no `Equatable` of its own, and its raw value is the
    /// identity the catalogue already uses.
    static func == (lhs: PlatformLimitAlternative, rhs: PlatformLimitAlternative) -> Bool {
        switch (lhs, rhs) {
        case let (.core(left), .core(right)): return left.rawValue == right.rawValue
        case let (.released(left), .released(right)): return left.rawValue == right.rawValue
        case (.core, .released), (.released, .core): return false
        }
    }
}

// MARK: - The three limits

extension UnsupportedFeature {

    /// The explanation behind this limit.
    var detail: PlatformLimitDetail {
        let currentGate = ReleaseGate(stage: ReleaseTrain.current, exposesEverything: false)
        switch self {
        case .inAppInstallation:
            return PlatformLimitDetail(
                requirement: "A supported way to hand an installation to the system, or the private installation entitlement and the daemon access that a pairing record grants.",
                wouldHaveToChange: "Apple would have to publish an application-facing install API, or grant this app the entitlement that mobile-installation clients rely on. Stock iOS refuses both; that is a platform decision this app cannot make for it.",
                instead: "ZynSign signs the package, writes the over-the-air manifest, encodes the itms-services link, renders the QR code, and records the delivery — the part of installation that needs no platform exception. The person completes the install from their own device.",
                alternatives: [
                    PlatformLimitAlternative.core(.sideloading),
                    PlatformLimitAlternative.released(.smartSign),
                    PlatformLimitAlternative.released(.deliveryHandoff),
                    PlatformLimitAlternative.released(.installationWorkspace),
                ].filter { $0.isAvailable(at: currentGate) },
                evidence: [
                    InstallationLimitation.noDeliveryMechanism.message,
                    "Readiness, attempts, and history are recorded; no row offers an install button.",
                ]
            )

        case .pairingJITAndMux:
            return PlatformLimitDetail(
                requirement: "A pairing record for the specific device, the local-tunnel entitlement that lets a signed build reach its own lockdownd, and — for JIT — a debug relationship the device will honour.",
                wouldHaveToChange: "Apple would have to make the network-extension local-tunnel entitlement available to a self-signed build, and the device would have to accept a JIT request outside a debugger session. Device muxing additionally needs usbmuxd's socket, which the app sandbox cannot reach at all.",
                instead: "The bridge speaks the published wire format — usbmux framing, lockdownd, AFC, and installation_proxy — over its own transport, so what is missing is one entitlement rather than a missing capability. The delivery report names it, with the anchor in the feasibility record. JIT is never requested: no get-task-allow, no debugger relationship, and no executable memory.",
                alternatives: [.core(.sideloading)],
                evidence: PairingCapabilityAssessment.allUnavailable.map(\.summary)
            )

        case .cloudSyncAndTelemetry:
            return PlatformLimitDetail(
                requirement: "An endpoint to send to and a policy that says sending is acceptable.",
                wouldHaveToChange: "Nothing on Apple's side — this is the app's own decision, and it is a permanent one rather than a feature flag. Turning measurement on would be a different product, disclosed as such, not a setting someone can flip.",
                instead: "Encrypted backups the person exports themselves, and an activity journal that stays on the device. Sync between a person's own devices is their file transfer, not a service of ours.",
                alternatives: [
                    PlatformLimitAlternative.released(.activityJournal),
                    PlatformLimitAlternative.core(.encryptedBackups),
                    PlatformLimitAlternative.core(.onDevicePrivacy),
                ].filter { $0.isAvailable(at: currentGate) },
                evidence: AnalyticsPolicy.guarantees.map(\.message)
            )
        }
    }

    /// The prefix every platform-limit catalogue id starts with.
    static let catalogIDPrefix = "limit."
}

// MARK: - Catalogue lookup

extension PlatformLimitDetail {

    /// The detail for a catalogue entry id, or `nil` when the entry is not a
    /// platform limit. `FeatureCatalogEntry` carries only its id, so this is how
    /// the catalogue row finds the explanation that belongs to it.
    static func resolved(forCatalogID id: String) -> PlatformLimitDetail? {
        let prefix = UnsupportedFeature.catalogIDPrefix
        guard id.hasPrefix(prefix),
              let limit = UnsupportedFeature(rawValue: String(id.dropFirst(prefix.count)))
        else { return nil }
        return limit.detail
    }
}
