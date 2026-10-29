import Foundation

/// How ZynSign transforms an application's bundle identifier to reduce
/// server-side PPQ signature correlation against App Store identifiers.
enum PPQProtectionMode: String, Codable, Equatable, Hashable, Sendable, CaseIterable, Identifiable {
    case disabled
    case suffixToken
    case stealth

    var id: String { rawValue }

    var title: String {
        switch self {
        case .disabled: return "Disabled"
        case .suffixToken: return "Token Suffix (.<token>)"
        case .stealth: return "Stealth Shield (zyn. + Keyword Scrub + Token)"
        }
    }

    var summary: String {
        switch self {
        case .disabled:
            return "Leaves CFBundleIdentifier as configured."
        case .suffixToken:
            return "Appends a 6-character alphanumeric token to CFBundleIdentifier."
        case .stealth:
            return "Prepends zyn., scrubs known store keywords, and appends a 6-character token."
        }
    }
}

/// Overrides the target app's interface appearance (`UIUserInterfaceStyle`).
enum AppAppearanceOverride: String, Codable, Equatable, Hashable, Sendable, CaseIterable, Identifiable {
    case `default`
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .default: return "System Default"
        case .light: return "Force Light"
        case .dark: return "Force Dark"
        }
    }

    var plistValue: String? {
        switch self {
        case .default: return nil
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }
}

/// Controls iOS 26+ Liquid Glass compatibility patching for a target app.
enum LiquidGlassPatchMode: String, Codable, Equatable, Hashable, Sendable, CaseIterable, Identifiable {
    case `default`
    case enable
    case disable

    var id: String { rawValue }

    var title: String {
        switch self {
        case .default: return "Keep Original"
        case .enable: return "Enable Liquid Glass (SDK 26 Patch)"
        case .disable: return "Disable Liquid Glass (Compatibility Mode)"
        }
    }
}

/// Base dyld prefix written into injected `LC_LOAD_DYLIB` load commands.
enum TweakInjectBase: String, Codable, Equatable, Hashable, Sendable, CaseIterable, Identifiable {
    case executablePath = "@executable_path"
    case rpath = "@rpath"

    var id: String { rawValue }
    var title: String { rawValue }
}

/// Destination folder inside the `.app` bundle where staged `.dylib` tweaks land.
enum TweakInjectFolder: String, Codable, Equatable, Hashable, Sendable, CaseIterable, Identifiable {
    case frameworks = "Frameworks"
    case bundleRoot = "/"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .frameworks: return "/Frameworks/"
        case .bundleRoot: return "/ (App Root)"
        }
    }

    func installName(base: TweakInjectBase, fileName: String) -> String {
        switch self {
        case .frameworks:
            return "\(base.rawValue)/Frameworks/\(fileName)"
        case .bundleRoot:
            return "\(base.rawValue)/\(fileName)"
        }
    }
}

/// Pure bundle-identifier & app-cloning transformation rules.
enum PPQProtectionPolicy {

    private static let tokenAlphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789")

    private static let scrubbedKeywords: [(needle: String, replacement: String)] = [
        ("apple", "apl"),
        ("youtube", "ytb"),
        ("google", "ggl"),
        ("spotify", "spt"),
        ("instagram", "ig"),
        ("tiktok", "ttk"),
        ("musical", "msc"),
        ("twitter", "xapp"),
        ("facebook", "fb"),
        ("meta", "mta"),
        ("snapchat", "snp"),
        ("discord", "dsc"),
        ("twitch", "twc"),
        ("reddit", "rdt"),
        ("whatsapp", "wa"),
        ("telegram", "tlg")
    ]

    /// Generates a random 6-character lowercase alphanumeric PPQ token.
    static func generateToken(length: Int = 6) -> String {
        let count = max(4, min(16, length))
        var result = ""
        result.reserveCapacity(count)
        for _ in 0..<count {
            let index = Int.random(in: 0..<tokenAlphabet.count)
            result.append(tokenAlphabet[index])
        }
        return result
    }

    /// Normalizes a user-entered PPQ token into valid reverse-DNS characters.
    static func sanitizeToken(_ raw: String) -> String {
        let filtered = raw.lowercased().filter { ch in
            ch.isASCII && (ch.isLetter || ch.isNumber || ch == "-")
        }
        let trimmed = filtered.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? "zynppq" : String(trimmed.prefix(16))
    }

    /// Applies prefix/suffix, dictionary replacements, and PPQ protection to a
    /// base bundle identifier, producing a valid reverse-DNS identifier.
    static func resolveBundleIdentifier(
        original: String,
        explicitReplacement: String?,
        prefix: String? = nil,
        suffix: String? = nil,
        replacements: [String: String] = [:],
        ppqMode: PPQProtectionMode = .disabled,
        ppqToken: String = "",
        dynamicProtection: Bool = false,
        matchesStoreCatalog: Bool = true
    ) -> String {
        var resolved = explicitReplacement ?? original
        for (source, target) in replacements.sorted(by: { $0.key < $1.key }) where !source.isEmpty {
            resolved = resolved.replacingOccurrences(of: source, with: target)
        }
        if let prefix, !prefix.isEmpty {
            let cleanPrefix = prefix.trimmingCharacters(in: CharacterSet(charactersIn: "."))
            if !cleanPrefix.isEmpty {
                resolved = "\(cleanPrefix).\(resolved)"
            }
        }
        if let suffix, !suffix.isEmpty {
            let cleanSuffix = suffix.trimmingCharacters(in: CharacterSet(charactersIn: "."))
            if !cleanSuffix.isEmpty {
                resolved = "\(resolved).\(cleanSuffix)"
            }
        }
        let shouldApplyPPQ = ppqMode != .disabled && (!dynamicProtection || matchesStoreCatalog)
        guard shouldApplyPPQ else { return resolved }

        let token = sanitizeToken(ppqToken)
        switch ppqMode {
        case .disabled:
            return resolved
        case .suffixToken:
            if resolved.lowercased().hasSuffix(".\(token)") { return resolved }
            return "\(resolved).\(token)"
        case .stealth:
            var lowered = resolved.lowercased()
            for pair in scrubbedKeywords {
                lowered = lowered.replacingOccurrences(of: pair.needle, with: pair.replacement)
            }
            if !lowered.hasPrefix("zyn.") {
                lowered = "zyn.\(lowered)"
            }
            if !lowered.hasSuffix(".\(token)") {
                lowered = "\(lowered).\(token)"
            }
            return lowered
        }
    }

    /// Resolves a display name with dictionary replacements and optional prefix/suffix.
    static func resolveDisplayName(
        original: String,
        explicitReplacement: String?,
        prefix: String? = nil,
        suffix: String? = nil,
        replacements: [String: String] = [:]
    ) -> String? {
        let hasChanges = explicitReplacement != nil
            || !(prefix ?? "").isEmpty
            || !(suffix ?? "").isEmpty
            || !replacements.isEmpty
        guard hasChanges else { return nil }
        var resolved = explicitReplacement ?? original
        for (source, target) in replacements.sorted(by: { $0.key < $1.key }) where !source.isEmpty {
            resolved = resolved.replacingOccurrences(of: source, with: target)
        }
        if let prefix, !prefix.isEmpty {
            resolved = prefix + resolved
        }
        if let suffix, !suffix.isEmpty {
            resolved = resolved + suffix
        }
        return resolved
    }

    /// Extracts a concrete bundle identifier from a provisioning profile's
    /// `application-identifier` entitlement (e.g. `TEAM123456.com.example.app` → `com.example.app`).
    static func extractProfileBundleIdentifier(applicationIdentifier: String, teamID: String?) -> String? {
        var value = applicationIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        if let teamID, !teamID.isEmpty, value.hasPrefix(teamID + ".") {
            value = String(value.dropFirst(teamID.count + 1))
        } else if let dot = value.firstIndex(of: ".") {
            let head = value[..<dot]
            if head.count == 10, head.allSatisfy({ $0.isLetter || $0.isNumber }) {
                value = String(value[value.index(after: dot)...])
            }
        }
        if value == "*" { return nil }
        if value.hasSuffix(".*") {
            value = String(value.dropLast(2)) + ".app"
        }
        return SideloadSigningOptions.isReverseDNS(value) ? value : nil
    }
}
