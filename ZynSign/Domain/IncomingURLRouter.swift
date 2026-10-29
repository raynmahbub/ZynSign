import Foundation

extension Notification.Name {
    /// Posted by Siri / App Shortcuts intents (`ZynSignShortcuts`) to switch the root tab.
    static let zynSignShortcutNavigate = Notification.Name("com.zynsign.shortcut.navigate")
}

/// Parses ZynSign custom URL scheme deep links (`zynsign://`, `zyn://`)
/// into explicit, typed, user-confirmable actions.
enum IncomingURLRouter {

    static let supportedSchemes: Set<String> = [
        "zynsign", "zyn"
    ]

    enum Route: Equatable, Sendable {
        case addSource(URL)
        case installPackage(URL)
        case importCertificateMaterial(p12Data: Data, profileData: Data, password: String)
        case exportPublicCertificateSummary(callbackTemplate: String?)
        case launchGuestContainer(bundleIdentifier: String, slotID: String)
    }

    static func parse(_ url: URL) -> Route? {
        guard let scheme = url.scheme?.lowercased(), supportedSchemes.contains(scheme) else {
            return nil
        }
        let host = (url.host ?? "").lowercased()
        let rawString = url.absoluteString

        if host == "launch-guest" {
            guard let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else {
                return nil
            }
            let bundleID = items.first(where: { $0.name.lowercased() == "bundleid" })?.value?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard SideloadSigningOptions.isReverseDNS(bundleID) else { return nil }
            let slot = items.first(where: { $0.name.lowercased() == "slot" })?.value?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return .launchGuestContainer(
                bundleIdentifier: bundleID,
                slotID: (slot?.isEmpty == false ? slot : nil) ?? "primary"
            )
        }

        if host == "source" {
            if let extracted = extractTrailingHTTPSURL(from: rawString, afterMarker: "://source/")
                ?? queryURL(in: url, keys: ["url", "source"]) {
                return .addSource(extracted)
            }
        }

        if host == "install" {
            if let extracted = extractTrailingHTTPSURL(from: rawString, afterMarker: "://install/")
                ?? queryURL(in: url, keys: ["url", "ipa"]) {
                return .installPackage(extracted)
            }
        }

        if host == "import-certificate" {
            guard let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else {
                return nil
            }
            let map = Dictionary(uniqueKeysWithValues: items.compactMap { item -> (String, String)? in
                guard let value = item.value else { return nil }
                return (item.name.lowercased(), value)
            })
            guard let p12B64 = map["p12"],
                  let profB64 = map["mobileprovision"] ?? map["mp"],
                  let p12Data = decodeURLBase64(p12B64),
                  let profData = decodeURLBase64(profB64),
                  !p12Data.isEmpty, !profData.isEmpty,
                  p12Data.count <= 8 * 1_024 * 1_024,
                  profData.count <= 8 * 1_024 * 1_024 else {
                return nil
            }
            let password: String
            if let pwB64 = map["password"] ?? map["pass"],
               let pwData = decodeURLBase64(pwB64),
               let decoded = String(data: pwData, encoding: .utf8) {
                password = decoded
            } else {
                password = map["password"] ?? ""
            }
            return .importCertificateMaterial(
                p12Data: p12Data,
                profileData: profData,
                password: password
            )
        }

        if host == "export-certificate" {
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let template = items.first { $0.name == "callback_template" }?.value
            return .exportPublicCertificateSummary(callbackTemplate: template)
        }

        return nil
    }

    private static func extractTrailingHTTPSURL(from full: String, afterMarker marker: String) -> URL? {
        guard let range = full.range(of: marker, options: [.caseInsensitive]) else { return nil }
        var tail = String(full[range.upperBound...])
        if let decoded = tail.removingPercentEncoding, decoded.lowercased().hasPrefix("http") {
            tail = decoded
        }
        guard let parsed = URL(string: tail),
              let scheme = parsed.scheme?.lowercased(),
              scheme == "https" || scheme == "http" else {
            return nil
        }
        return parsed
    }

    private static func queryURL(in url: URL, keys: [String]) -> URL? {
        guard let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else {
            return nil
        }
        for key in keys {
            if let value = items.first(where: { $0.name.lowercased() == key })?.value,
               let parsed = URL(string: value),
               let scheme = parsed.scheme?.lowercased(),
               scheme == "https" || scheme == "http" {
                return parsed
            }
        }
        return nil
    }

    private static func decodeURLBase64(_ input: String) -> Data? {
        var normalized = input
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
            .replacingOccurrences(of: " ", with: "+")
        let remainder = normalized.count % 4
        if remainder > 0 {
            normalized += String(repeating: "=", count: 4 - remainder)
        }
        return Data(base64Encoded: normalized)
    }
}
