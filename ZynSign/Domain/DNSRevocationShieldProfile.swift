import Foundation

/// Builds a transparent, user-auditable `com.apple.dnsSettings.managed`
/// `.mobileconfig` configuration profile for encrypted DNS (DoH / DoT)
/// resolvers, and lists the Apple revocation/PPQ hostnames probed by iOS.
///
/// Honest boundary: ZynSign cannot alter system DNS itself and cannot un-revoke
/// an already-revoked certificate. A configuration profile only takes effect if
/// the user installs it in iOS Settings and points it at a DNS resolver they trust.
enum DNSRevocationShieldProfile {

    static let appleRevocationHostnames: [String] = [
        "ocsp.apple.com",
        "ocsp2.apple.com",
        "valid.apple.com",
        "crl.apple.com",
        "certs.apple.com",
        "appattest.apple.com",
        "ppq.apple.com"
    ]

    enum ProtocolKind: String, CaseIterable, Sendable {
        case https = "HTTPS"
        case tls = "TLS"

        var title: String {
            switch self {
            case .https: return "DNS over HTTPS (DoH)"
            case .tls: return "DNS over TLS (DoT)"
            }
        }
    }

    enum ProfileError: Error, Equatable, Sendable {
        case invalidEndpoint

        var message: String {
            switch self {
            case .invalidEndpoint:
                return "Enter a valid https:// DoH URL or DoT hostname."
            }
        }
    }

    static func generateMobileconfig(
        displayName: String,
        protocolKind: ProtocolKind,
        endpoint: String,
        onDemandEnabled: Bool = true
    ) throws -> Data {
        let trimmed = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ProfileError.invalidEndpoint }

        var dnsSettings: [String: Any] = [
            "DNSProtocol": protocolKind.rawValue
        ]
        switch protocolKind {
        case .https:
            guard let url = URL(string: trimmed), url.scheme?.lowercased() == "https", url.host != nil else {
                throw ProfileError.invalidEndpoint
            }
            dnsSettings["ServerURL"] = url.absoluteString
        case .tls:
            guard !trimmed.contains("/"), trimmed.contains(".") else {
                throw ProfileError.invalidEndpoint
            }
            dnsSettings["ServerName"] = trimmed
        }

        let cleanTitle = displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "ZynSign Managed DNS"
            : displayName.trimmingCharacters(in: .whitespacesAndNewlines)

        let innerUUID = UUID().uuidString.uppercased()
        let outerUUID = UUID().uuidString.uppercased()

        var payloadEntry: [String: Any] = [
            "PayloadType": "com.apple.dnsSettings.managed",
            "PayloadVersion": 1,
            "PayloadIdentifier": "com.zynsign.dns.settings.\(innerUUID)",
            "PayloadUUID": innerUUID,
            "PayloadDisplayName": cleanTitle,
            "DNSSettings": dnsSettings
        ]
        if onDemandEnabled {
            payloadEntry["OnDemandRules"] = [
                ["Action": "Connect"]
            ]
        }

        let rootProfile: [String: Any] = [
            "PayloadContent": [payloadEntry],
            "PayloadDescription": "Routes DNS queries through the configured encrypted DNS endpoint.",
            "PayloadDisplayName": cleanTitle,
            "PayloadIdentifier": "com.zynsign.dns.profile.\(outerUUID)",
            "PayloadRemovalDisallowed": false,
            "PayloadType": "Configuration",
            "PayloadUUID": outerUUID,
            "PayloadVersion": 1
        ]

        return try PropertyListSerialization.data(
            fromPropertyList: rootProfile,
            format: .xml,
            options: 0
        )
    }
}
