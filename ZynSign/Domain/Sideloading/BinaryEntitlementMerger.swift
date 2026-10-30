import Foundation

/// Merges a target Mach-O binary's original `CSSLOT_ENTITLEMENTS` with the
/// selected provisioning profile's authorized entitlements, applies Keychain
/// Isolation when requested, and folds in user entitlement overrides.
///
/// Preserves profile-authorized binary claims via wildcard team substitution
/// and rewrites `keychain-access-groups` when Keychain Isolation is enabled,
/// while never admitting an unauthorized entitlement that would cause `installd`
/// to reject the signature unless the user explicitly provided an override.
enum BinaryEntitlementMerger {
    enum MergeError: Error, Equatable {
        case keychainIsolationNotAuthorized
    }

    struct Result: Equatable, Sendable {
        let entitlements: CodeSigningEntitlements
        let mergedBinaryKeys: [String]
        let isolatedKeychainGroup: String?
    }

    /// Computes the effective entitlement set for a signing run.
    static func resolve(
        profileEntitlements: CodeSigningEntitlements,
        binaryEntitlementsXML: Data?,
        resolvedBundleIdentifier: String,
        teamIdentifier: String?,
        mergesBinaryEntitlements: Bool,
        isolatesKeychainGroup: Bool,
        overrides: [String: EntitlementValue] = [:],
        removedKeys: [String] = [],
        rawXMLOverride: String? = nil
    ) throws -> Result {
        if let rawXMLOverride, !rawXMLOverride.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let parsed = try EntitlementsPlistParser.parse(Data(rawXMLOverride.utf8))
            return Result(entitlements: parsed, mergedBinaryKeys: [], isolatedKeychainGroup: nil)
        }

        var working = try decodePlistDictionary(from: profileEntitlements.canonicalXMLData())
        let resolvedTeam = teamIdentifier ?? extractTeamIdentifier(from: working)
        var mergedKeys: [String] = []

        // Substitute wildcard `*` in `application-identifier` when concrete bundle ID is known.
        if let appID = working["application-identifier"] as? String,
           appID.hasSuffix("*"), let resolvedTeam, !resolvedTeam.isEmpty,
           !resolvedBundleIdentifier.isEmpty {
            let candidate = "\(resolvedTeam).\(resolvedBundleIdentifier)"
            if matchesAuthorization(candidate, pattern: appID) {
                working["application-identifier"] = candidate
            }
        }

        // Merge compatible entitlements from the original Mach-O binary when requested.
        if mergesBinaryEntitlements, let binaryXML = binaryEntitlementsXML {
            // Parse through the bounded entitlement parser rather than silently
            // treating malformed embedded claims as an empty set.
            let binaryEntitlements = try EntitlementsPlistParser.parse(binaryXML)
            let binaryDict = try decodePlistDictionary(from: binaryEntitlements.canonicalXMLData())
            let profileSnapshot = working
            mergedKeys = mergeAuthorizedBinaryKeys(
                from: binaryDict,
                into: &working,
                profileDict: profileSnapshot,
                bundleIdentifier: resolvedBundleIdentifier,
                teamIdentifier: resolvedTeam
            )
        }

        // Keychain Isolation: rewrite `keychain-access-groups` to `<TeamID>.<BundleID>`
        // so cloned or PPQ-renamed builds do not collide on shared keychain items.
        var isolatedGroup: String?
        if isolatesKeychainGroup {
            guard let resolvedTeam, !resolvedTeam.isEmpty, !resolvedBundleIdentifier.isEmpty,
                  let profileGroups = profileEntitlements.values["keychain-access-groups"],
                  case .array(let groups) = profileGroups else {
                throw MergeError.keychainIsolationNotAuthorized
            }
            let group = "\(resolvedTeam).\(resolvedBundleIdentifier)"
            guard groups.contains(where: { value in
                guard case .string(let pattern) = value else { return false }
                return matchesAuthorization(group, pattern: pattern)
            }) else { throw MergeError.keychainIsolationNotAuthorized }
            working["keychain-access-groups"] = [group]
            isolatedGroup = group
        }

        // Apply explicit key overrides and removals from the pre-sign Entitlements editor.
        for key in removedKeys {
            working.removeValue(forKey: key)
        }
        for (key, value) in overrides {
            working[key] = foundationObject(for: value)
        }

        let serialized = try PropertyListSerialization.data(
            fromPropertyList: working,
            format: .xml,
            options: 0
        )
        let finalEntitlements = try EntitlementsPlistParser.parse(serialized)
        return Result(
            entitlements: finalEntitlements,
            mergedBinaryKeys: mergedKeys.sorted(),
            isolatedKeychainGroup: isolatedGroup
        )
    }

    // MARK: - Helpers

    private static func mergeAuthorizedBinaryKeys(
        from binaryDict: [String: Any],
        into working: inout [String: Any],
        profileDict: [String: Any],
        bundleIdentifier: String,
        teamIdentifier: String?
    ) -> [String] {
        var merged: [String] = []
        for (key, binaryValue) in binaryDict {
            if key == "application-identifier" || key == "com.apple.developer.team-identifier" {
                continue
            }
            if key == "keychain-access-groups",
               let binaryGroups = binaryValue as? [String],
               let profileGroups = profileDict[key] as? [String] {
                let rewritten = rewriteKeychainGroups(
                    binaryGroups: binaryGroups,
                    profileGroups: profileGroups,
                    bundleIdentifier: bundleIdentifier,
                    teamIdentifier: teamIdentifier
                )
                if !rewritten.isEmpty {
                    working[key] = rewritten
                    merged.append(key)
                }
                continue
            }
            guard let profileValue = profileDict[key] else { continue }
            if let narrowed = narrowToAuthorizedSubset(binaryValue: binaryValue, profileValue: profileValue) {
                working[key] = narrowed
                merged.append(key)
            }
        }
        return merged
    }

    private static func rewriteKeychainGroups(
        binaryGroups: [String],
        profileGroups: [String],
        bundleIdentifier: String,
        teamIdentifier: String?
    ) -> [String] {
        guard let team = teamIdentifier, !team.isEmpty else { return [] }
        var output: [String] = []
        for group in binaryGroups {
            let suffix: String
            if let dot = group.firstIndex(of: ".") {
                suffix = String(group[group.index(after: dot)...])
            } else {
                suffix = bundleIdentifier
            }
            let candidate = "\(team).\(suffix)"
            if profileGroups.contains(where: { matchesAuthorization(candidate, pattern: $0) }) {
                if !output.contains(candidate) { output.append(candidate) }
            }
        }
        let fallback = "\(team).\(bundleIdentifier)"
        if output.isEmpty, !bundleIdentifier.isEmpty,
           profileGroups.contains(where: { matchesAuthorization(fallback, pattern: $0) }) {
            output.append(fallback)
        }
        return output
    }

    /// Only trailing wildcards are considered, and a candidate must itself be
    /// concrete. A wildcard belonging to a different prefix grants nothing.
    private static func matchesAuthorization(_ candidate: String, pattern: String) -> Bool {
        guard !candidate.isEmpty, !candidate.contains("*") else { return false }
        if !pattern.contains("*") { return candidate == pattern }
        guard pattern.last == "*", pattern.dropLast().contains("*") == false else { return false }
        return candidate.hasPrefix(String(pattern.dropLast()))
    }

    private static func narrowToAuthorizedSubset(binaryValue: Any, profileValue: Any) -> Any? {
        guard let binary = try? ProvisioningProfileValue.decode(binaryValue),
              let profile = try? ProvisioningProfileValue.decode(profileValue) else { return nil }
        switch (binary, profile) {
        case (.array(let requested), .array(let authorized)):
            let patterns = authorized.compactMap { value -> String? in
                guard case .string(let text) = value else { return nil }
                return text
            }
            guard patterns.count == authorized.count else { return binary == profile ? binaryValue : nil }
            let selected = requested.compactMap { value -> String? in
                guard case .string(let text) = value,
                      patterns.contains(where: { matchesAuthorization(text, pattern: $0) }) else { return nil }
                return text
            }
            return selected.isEmpty ? nil : selected
        case (.string(let requested), .string(let pattern)):
            return matchesAuthorization(requested, pattern: pattern) ? requested : nil
        default:
            // Never coerce NSNumber types or treat true as allowed by false.
            return binary == profile ? binaryValue : nil
        }
    }

    private static func extractTeamIdentifier(from dict: [String: Any]) -> String? {
        if let team = dict["com.apple.developer.team-identifier"] as? String, !team.isEmpty {
            return team
        }
        if let teams = dict["com.apple.developer.team-identifier"] as? [String], let first = teams.first {
            return first
        }
        if let appID = dict["application-identifier"] as? String, let dot = appID.firstIndex(of: ".") {
            let prefix = String(appID[..<dot])
            if prefix.count == 10 { return prefix }
        }
        return nil
    }

    private static func decodePlistDictionary(from data: Data) throws -> [String: Any] {
        guard !data.isEmpty else { return [:] }
        let object = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        return (object as? [String: Any]) ?? [:]
    }

    static func foundationObject(for value: EntitlementValue) -> Any {
        switch value {
        case .string(let text): return text
        case .boolean(let flag): return flag
        case .integer(let num): return num
        case .data(let bytes): return bytes
        case .array(let list): return list.map(foundationObject(for:))
        case .dictionary(let map): return map.mapValues(foundationObject(for:))
        }
    }
}
