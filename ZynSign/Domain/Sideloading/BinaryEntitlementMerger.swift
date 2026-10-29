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
        if let appID = working["application-identifier"] as? String, appID.contains("*"),
           !resolvedBundleIdentifier.isEmpty {
            if let resolvedTeam, !resolvedTeam.isEmpty {
                working["application-identifier"] = "\(resolvedTeam).\(resolvedBundleIdentifier)"
            } else {
                working["application-identifier"] = resolvedBundleIdentifier
            }
        }

        // Merge compatible entitlements from the original Mach-O binary when requested.
        if mergesBinaryEntitlements,
           let binaryXML = binaryEntitlementsXML,
           let binaryDict = try? decodePlistDictionary(from: binaryXML) {
            mergedKeys = mergeAuthorizedBinaryKeys(
                from: binaryDict,
                into: &working,
                profileDict: working,
                bundleIdentifier: resolvedBundleIdentifier,
                teamIdentifier: resolvedTeam
            )
        }

        // Keychain Isolation: rewrite `keychain-access-groups` to `<TeamID>.<BundleID>`
        // so cloned or PPQ-renamed builds do not collide on shared keychain items.
        var isolatedGroup: String?
        if isolatesKeychainGroup, !resolvedBundleIdentifier.isEmpty {
            let group = if let resolvedTeam, !resolvedTeam.isEmpty {
                "\(resolvedTeam).\(resolvedBundleIdentifier)"
            } else {
                resolvedBundleIdentifier
            }
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
        let allowsWildcard = profileGroups.contains { $0.hasSuffix(".*") || $0 == "*" }
        guard let team = teamIdentifier, !team.isEmpty else { return profileGroups }
        var output: [String] = []
        for group in binaryGroups {
            let suffix: String
            if let dot = group.firstIndex(of: ".") {
                suffix = String(group[group.index(after: dot)...])
            } else {
                suffix = bundleIdentifier
            }
            let candidate = "\(team).\(suffix)"
            if allowsWildcard || profileGroups.contains(candidate) {
                if !output.contains(candidate) { output.append(candidate) }
            }
        }
        if output.isEmpty, allowsWildcard, !bundleIdentifier.isEmpty {
            output.append("\(team).\(bundleIdentifier)")
        }
        return output
    }

    private static func narrowToAuthorizedSubset(binaryValue: Any, profileValue: Any) -> Any? {
        if let profileString = profileValue as? String, profileString == "*" {
            return binaryValue
        }
        if let binaryArray = binaryValue as? [String], let profileArray = profileValue as? [String] {
            if profileArray.contains("*") { return binaryArray }
            let intersection = binaryArray.filter { item in
                profileArray.contains { allowed in
                    allowed == item
                        || (allowed.hasSuffix("*") && item.hasPrefix(String(allowed.dropLast())))
                }
            }
            return intersection.isEmpty ? nil : intersection
        }
        if let binaryBool = binaryValue as? Bool, let profileBool = profileValue as? Bool {
            return (binaryBool && profileBool) ? true : binaryBool
        }
        return nil
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
