import Foundation

/// What the running binary's own signature says this build was granted.
///
/// The capability rows on Settings → Sideloading hinge on one fact that used to
/// be *asserted* rather than *read*: whether the identity that signed this copy
/// of ZynSign carried a Network Extension (packet tunnel) entitlement. Every
/// row said "no" because an App Store build cannot carry it — true of the App
/// Store build, and a guess about any other. A self-signed or enterprise build
/// whose profile carries the entitlement is a different fact, and a screen that
/// cannot tell the two apart is telling the user something it did not measure.
///
/// This type is the measurement. It is deliberately small: presence of four
/// keys, two of them readable identifiers, never an entitlement value beyond
/// what the app's own signature already publishes about itself.
///
/// **`nil` is not `false`.** When the probe cannot read the signature at all —
/// a preview, a simulator, a toolchain that does not expose the task — the
/// answers are `nil`, which the assessment treats as "not established". The
/// screen then says it could not read the build rather than claiming the
/// entitlement is missing.
struct ProcessEntitlements: Equatable, Sendable {

    /// The entitlement whose absence is the whole reason device sessions stay
    /// empty. Its value is a list of extension points; only its presence is
    /// recorded here.
    static let localTunnelKey = "com.apple.developer.networking.networkextension"

    /// Keys every signed build publishes, used both as facts and as proof that
    /// the probe could read *anything* (see `isMeasured`).
    static let applicationIdentifierKey = "application-identifier"
    static let teamIdentifierKey = "com.apple.developer.team-identifier"
    static let getTaskAllowKey = "get-task-allow"

    /// Every key the probe asks about. Kept in one place so the reader and the
    /// tests cannot drift apart.
    static let probedKeys = [
        applicationIdentifierKey,
        teamIdentifierKey,
        getTaskAllowKey,
        localTunnelKey,
    ]

    /// Whether the signature was readable at all.
    ///
    /// `false` means the app could not look; it does **not** mean "nothing is
    /// granted". Every accessor below answers `nil` in that case.
    let isMeasured: Bool

    /// The probed keys that were present in this build's signature.
    let grantedKeys: Set<String>

    /// The build's application identifier, when the signature publishes one.
    let applicationIdentifier: String?

    /// The team identifier that signed this build, when it is readable. On a
    /// free personal team this ends in `0`, which is a fact about the signing
    /// material — not an error.
    let teamIdentifier: String?

    /// The declared `get-task-allow` value, when the claim carries a boolean.
    let getTaskAllowValue: Bool?

    /// A build whose signature could not be read here.
    static let unmeasured = ProcessEntitlements(
        isMeasured: false,
        grantedKeys: [],
        applicationIdentifier: nil,
        teamIdentifier: nil,
        getTaskAllowValue: nil
    )

    init(
        isMeasured: Bool,
        grantedKeys: Set<String>,
        applicationIdentifier: String? = nil,
        teamIdentifier: String? = nil,
        getTaskAllowValue: Bool? = nil
    ) {
        self.isMeasured = isMeasured
        self.grantedKeys = grantedKeys
        self.applicationIdentifier = applicationIdentifier
        self.teamIdentifier = teamIdentifier
        self.getTaskAllowValue = getTaskAllowValue
    }

    /// Whether this build may open a local tunnel to a device's own `lockdownd`.
    ///
    /// `nil` = not established; `false` = measured and absent.
    var carriesLocalTunnelEntitlement: Bool? {
        guard isMeasured else { return nil }
        return grantedKeys.contains(Self.localTunnelKey)
    }

    /// Whether this build **declares** `get-task-allow`.
    ///
    /// Presence, not value: a distribution profile commonly declares
    /// `get-task-allow = false`, and that is a declared claim rather than a
    /// missing one — the same rule the Entitlements Studio applies to the key.
    /// Use `allowsDebugging` to ask what the value is.
    var declaresGetTaskAllow: Bool? {
        guard isMeasured else { return nil }
        return grantedKeys.contains(Self.getTaskAllowKey)
    }

    /// The value of `get-task-allow`: `true` when a debugger may attach,
    /// `false` when the claim says so, `nil` when the claim is not declared (or
    /// the build was not measured — `isMeasured` separates those two).
    ///
    /// Kept apart from `declaresGetTaskAllow` so "declared false" and "not
    /// declared" cannot collapse into one answer.
    var allowsDebugging: Bool? {
        guard isMeasured else { return nil }
        return getTaskAllowValue
    }

    /// One sentence a screen shows verbatim, in the same voice as the
    /// capability rows: what was measured, and what a measurement can and
    /// cannot mean.
    var summary: String {
        guard isMeasured else {
            return "This build's signature could not be read here, so its "
                + "entitlements are unknown rather than absent."
        }
        switch carriesLocalTunnelEntitlement {
        case true:
            return "This build's signature carries a Network Extension entitlement, "
                + "so a device session is possible once a pairing record and a "
                + "transport exist. Whether a device accepts the session is still "
                + "the device's answer."
        case false:
            return "This build's signature carries no Network Extension entitlement, "
                + "so the sandbox has no route to a device's lockdownd. A build "
                + "signed with a profile that grants it would read differently here."
        case .none:
            return "This build's entitlement coverage could not be established."
        }
    }

    /// The evidence the sideloading rows are assessed from, with the build's
    /// own signature supplying the entitlement answer instead of a constant.
    ///
    /// The remaining fields stay exactly as the screen already stated them:
    /// no transport is composed, no loader ships in the bundle, and the two
    /// per-target facts need a package in hand. Passing them in keeps this
    /// mapping honest as those change.
    func sideloadingEvidence(
        hasPairingRecord: Bool?,
        transportComposed: Bool? = false,
        loaderBundled: Bool? = false,
        targetHeaderPadding: Int? = nil,
        guestDecrypted: Bool? = nil,
        deviceAcceptsAdHoc: Bool? = nil
    ) -> SideloadingCapability.Evidence {
        SideloadingCapability.Evidence(
            hasPairingRecord: hasPairingRecord,
            buildCarriesLocalTunnelEntitlement: carriesLocalTunnelEntitlement,
            transportComposed: transportComposed,
            loaderBundled: loaderBundled,
            targetHeaderPadding: targetHeaderPadding,
            guestDecrypted: guestDecrypted,
            deviceAcceptsAdHoc: deviceAcceptsAdHoc
        )
    }
}

/// Reads the running process's own entitlements.
///
/// A port, because a preview and a test must be able to say what the build
/// carries without depending on how a device publishes it. The platform
/// implementation is the only one that talks to the Security framework.
protocol ProcessEntitlementReading: Sendable {
    func read() -> ProcessEntitlements
}

/// A reader that reports a fixed measurement. Tests and previews use it; the
/// application never does.
struct FixedProcessEntitlementReader: ProcessEntitlementReading {
    let entitlements: ProcessEntitlements

    init(_ entitlements: ProcessEntitlements) {
        self.entitlements = entitlements
    }

    func read() -> ProcessEntitlements { entitlements }
}
