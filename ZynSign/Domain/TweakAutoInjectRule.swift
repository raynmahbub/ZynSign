import Foundation

/// Rule that automatically pre-selects a Tweak Library item when opening the
/// Signing screen for matching applications, with explicit bundle-ID exclusions.
struct TweakAutoInjectRule: Codable, Equatable, Hashable, Sendable, Identifiable {

    enum Scope: String, Codable, Equatable, Hashable, Sendable, CaseIterable {
        case disabled
        case allApps
        case matchingBundleIDs

        var title: String {
            switch self {
            case .disabled: return "Manual Only"
            case .allApps: return "Auto-Inject into All Apps"
            case .matchingBundleIDs: return "Auto-Inject by Bundle ID"
            }
        }
    }

    /// Keyed deterministically to the `TweakRecord.id` it governs.
    let id: UUID
    var scope: Scope
    /// Exact or wildcard-prefix (`com.google.ios.*`) bundle identifiers to match.
    var targetBundleIdentifiers: [String]
    /// Bundle identifiers excluded even when `scope == .allApps`.
    var excludedBundleIdentifiers: [String]

    init(
        tweakID: UUID,
        scope: Scope = .disabled,
        targetBundleIdentifiers: [String] = [],
        excludedBundleIdentifiers: [String] = []
    ) {
        self.id = tweakID
        self.scope = scope
        self.targetBundleIdentifiers = targetBundleIdentifiers
        self.excludedBundleIdentifiers = excludedBundleIdentifiers
    }

    /// Evaluates whether this rule applies to `bundleIdentifier`.
    func matches(bundleIdentifier: String) -> Bool {
        let candidate = bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !candidate.isEmpty else { return false }
        if Self.matchesAnyPattern(candidate, in: excludedBundleIdentifiers) {
            return false
        }
        switch scope {
        case .disabled:
            return false
        case .allApps:
            return true
        case .matchingBundleIDs:
            return Self.matchesAnyPattern(candidate, in: targetBundleIdentifiers)
        }
    }

    private static func matchesAnyPattern(_ candidate: String, in patterns: [String]) -> Bool {
        for raw in patterns {
            let pattern = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !pattern.isEmpty else { continue }
            if pattern == "*" || pattern == candidate {
                return true
            }
            if pattern.hasSuffix(".*") {
                let prefix = String(pattern.dropLast(1))
                if candidate.hasPrefix(prefix) { return true }
            } else if pattern.hasSuffix("*") {
                let prefix = String(pattern.dropLast(1))
                if candidate.hasPrefix(prefix) { return true }
            }
        }
        return false
    }
}
