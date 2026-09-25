import Foundation

/// Pairing / JIT / Mux / OpenSSL — explicitly never planned for any release through 1.0.0.
///
/// This file is the honest boundary for three commonly-requested capabilities
/// that ZynSign deliberately does *not* ship. Each is modelled as an
/// unavailable capability with typed limitations, so the presentation layer
/// can render the same redacted, deterministic language everywhere.
///
/// Why never:
/// - **Pairing (PairingKit / lockdown mux):** requires a privileged lockdown
///   daemon, `com.apple.mobile.lockdown`, and private `MobileDevice` / `usbmuxd`
///   entitlements that are not available to App Store or sideloaded sandboxed
///   apps. ZynSign instead stays inside the sandbox and signs without a host.
/// - **JIT (JITBroker / debugserver):** requires `get-task-allow` + a paired
///   debugger or `PT_TRACE_ME` that the platform only grants to development
///   devices via `debugserver`. No in-app JIT broker is composed.
/// - **Mux / OpenSSL linkage:** OpenSSL is used only in `Tests/Host` external
///   validation (host-side `openssl cms -verify`), never linked into the app
///   binary. Keeps the binary reviewable and avoids private-API risk.
///
/// Extending any of these requires an ADR with feasibility evidence, a new
/// `Application` port, and a `Platform` implementation that does not weaken
/// the sandbox. Until then, every path reports `supported == false`.
enum PairingCapability: String, CaseIterable, Hashable {
    case pairing
    case jit
    case mux
    case openSSLLinkage

    /// The private surface the capability would need. Fixed factual text,
    /// used by the Settings screen and the feasibility record
    /// (`docs/architecture/pairing-jit-mux-feasibility.md`).
    var feasibilityNote: String {
        switch self {
        case .pairing:
            return "Pairing speaks to usbmuxd through Apple's private MobileDevice framework and needs com.apple.mobile.lockdown-class entitlements no App Store or sideloaded sandboxed app can hold."
        case .jit:
            return "JIT needs get-task-allow plus a debugger relationship (debugserver / PT_TRACE_ME) that only Developer Mode with a paired host grants."
        case .mux:
            return "The multiplexer is usbmuxd's UNIX-domain socket; apps are sandboxed away from it, and shim layers would require a host tool outside the product."
        case .openSSLLinkage:
            return "OpenSSL stays in Tests/Host external validation only. Linking it into the app would grow the audit surface for no in-sandbox capability."
        }
    }

    /// Where the honest boundary is written down.
    var documentationAnchor: String {
        switch self {
        case .pairing: return "docs/architecture/pairing-jit-mux-feasibility.md#pairing"
        case .jit: return "docs/architecture/pairing-jit-mux-feasibility.md#jit"
        case .mux: return "docs/architecture/pairing-jit-mux-feasibility.md#mux"
        case .openSSLLinkage: return "docs/architecture/pairing-jit-mux-feasibility.md#openssl-linkage"
        }
    }
}

enum PairingLimitation: String, Hashable, CaseIterable {
    case requiresPrivateEntitlement
    case requiresLockdownDaemon
    case requiresDeveloperMode
    case requiresHostTool
    case notComposed

    var message: String {
        switch self {
        case .requiresPrivateEntitlement: return "Requires a private entitlement not available to sandboxed apps."
        case .requiresLockdownDaemon: return "Requires the privileged lockdown daemon."
        case .requiresDeveloperMode: return "Requires Developer Mode and a paired debugger."
        case .requiresHostTool: return "Requires a host tool outside the sandbox."
        case .notComposed: return "Not composed into this product."
        }
    }
}

struct PairingAssessment: Equatable, Hashable {
    let capability: PairingCapability
    let supported: Bool // always false
    let limitations: [PairingLimitation]
    let summary: String
}

enum PairingCapabilityAssessment {
    static func assess(_ capability: PairingCapability) -> PairingAssessment {
        let limitations: [PairingLimitation]
        switch capability {
        case .pairing:
            limitations = [.requiresLockdownDaemon, .requiresPrivateEntitlement, .notComposed]
        case .jit:
            limitations = [.requiresDeveloperMode, .requiresPrivateEntitlement, .notComposed]
        case .mux:
            limitations = [.requiresLockdownDaemon, .requiresHostTool, .notComposed]
        case .openSSLLinkage:
            limitations = [.notComposed] // OpenSSL only in Tests/Host external validation
        }
        return PairingAssessment(
            capability: capability,
            supported: false,
            limitations: limitations,
            summary: "\(capability.rawValue) is not available: \(limitations.first?.message ?? "Not composed.")"
        )
    }

    static var allUnavailable: [PairingAssessment] {
        PairingCapability.allCases.map { assess($0) }
    }
}
