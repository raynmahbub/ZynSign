import Foundation

/// Pairing / JIT / Mux / OpenSSL — explicitly never planned for 0.1.0-dev → 0.2.0 Horizon.
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
