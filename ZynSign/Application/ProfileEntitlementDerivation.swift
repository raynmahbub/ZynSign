import Foundation

/// Derives the entitlement set a provisioning profile declares, and the
/// display facts the queue's screens show about it.
///
/// This is the one place the "profile bytes → entitlements" mapping lives.
/// The Smart Sign screen, the signing-queue configuration sheet, and the
/// queue's executor all derive through it, so a job queued from anywhere
/// signs with exactly the entitlements the same profile would produce on
/// the inline signing screen.
///
/// The derivation reads the profile's own declarations and preserves them
/// verbatim: unknown keys are kept, and ordering is canonicalized only at
/// serialization. It reaches no conclusion about trust, authorization, or
/// installability — the pipeline's profile stage holds the derived set
/// against the profile's policy before anything is signed.
enum ProfileEntitlementDerivation {

    /// The entitlement set the profile declares.
    ///
    /// The bytes may be a CMS container (the ordinary `.mobileprovision`
    /// form), a bare XML property list, or a bare binary property list;
    /// each form is reduced to its payload and parsed. A profile that
    /// parses but declares no entitlements yields the empty set — an
    /// honest result, not a failure.
    ///
    /// - Throws: the parser's typed error when the payload is not a
    ///   provisioning profile this build can read.
    static func entitlements(
        fromProvisioningProfile data: Data,
        forBundleIdentifier bundleIdentifier: BundleIdentifier? = nil
    ) throws -> CodeSigningEntitlements {
        let payload = profilePayload(from: data)
        let parser = PropertyListProvisioningProfileParser()
        do {
            let profile = try parser.parse(ProvisioningProfilePayload(plistData: payload))
            if let entitlements = profile.entitlements {
                let concrete = concreteProfileEntitlements(
                    entitlements,
                    profile: profile,
                    bundleIdentifier: bundleIdentifier
                )
                return try CodeSigningEntitlements(profileEntitlements: concrete)
            }
            return try CodeSigningEntitlements(values: [:])
        } catch {
            // A payload that is an entitlements property list on its own —
            // the form some exported profiles take — is read directly before
            // the failure is passed on.
            if let direct = try? EntitlementsPlistParser.parse(payload) {
                return direct
            }
            throw error
        }
    }

    /// Materializes concrete bundle-scoped entitlement claims (such as
    /// replacing a wildcard `TEAMID.*` `application-identifier` with
    /// `TEAMID.<bundleIdentifier>`) when signing a specific application under
    /// an authenticated wildcard profile.
    static func concreteProfileEntitlements(
        _ entitlements: ProvisioningProfileEntitlements,
        profile: ProvisioningProfile,
        bundleIdentifier: BundleIdentifier?
    ) -> ProvisioningProfileEntitlements {
        guard let bundleIdentifier else { return entitlements }
        let compatibility = ProvisioningIdentifierCompatibility(profile: profile)
        guard let concreteAppID = compatibility.expectedApplicationIdentifier(for: bundleIdentifier) else {
            return entitlements
        }
        var updated = entitlements.values
        if case .string(let declared)? = updated[ProvisioningProfileEntitlementKeys.applicationIdentifier] {
            switch compatibility.outcome(forApplicationIdentifierValue: declared) {
            case .wildcardMatch where declared.hasSuffix("*"):
                updated[ProvisioningProfileEntitlementKeys.applicationIdentifier] = .string(concreteAppID)
            default:
                break
            }
        }
        if case .array(let groups)? = updated["keychain-access-groups"] {
            let rewrittenGroups = groups.map { element -> ProvisioningProfileValue in
                if case .string(let group) = element, group.hasSuffix(".*") {
                    let prefix = String(group.dropLast(2))
                    if concreteAppID.hasPrefix(prefix + ".") {
                        return .string(concreteAppID)
                    }
                }
                return element
            }
            updated["keychain-access-groups"] = .array(rewrittenGroups)
        }
        return ProvisioningProfileEntitlements(values: updated)
    }

    /// The profile's own display facts: its declared name and its first
    /// declared team identifier. `nil` when the profile cannot be parsed —
    /// display facts are a convenience, and their absence never blocks a
    /// signing run, whose profile stage does its own validation.
    static func displaySummary(fromProvisioningProfile data: Data) -> ProfileDisplaySummary? {
        let payload = profilePayload(from: data)
        guard let profile = try? PropertyListProvisioningProfileParser()
            .parse(ProvisioningProfilePayload(plistData: payload)) else {
            return nil
        }
        return ProfileDisplaySummary(
            name: profile.profileName,
            teamIdentifier: profile.teamIdentifiers?.first ?? profile.entitlementTeamIdentifier
        )
    }

    /// The profile's display facts: a declared name and team identifier,
    /// both optional because a profile declares neither authoritatively.
    struct ProfileDisplaySummary: Equatable, Sendable {
        let name: String?
        let teamIdentifier: String?
    }

    /// Reduces profile bytes to the property-list payload inside them: the
    /// CMS encapsulated content when the bytes are a container, or the
    /// bytes from the first property-list marker otherwise.
    private static func profilePayload(from data: Data) -> Data {
        if let cms = try? CMSStructureReader.read(data), let content = cms.encapsulatedContent {
            return content
        }
        if let range = data.range(of: Data("<?xml".utf8)) {
            return data.subdata(in: range.lowerBound..<data.endIndex)
        }
        if let range = data.range(of: Data("bplist00".utf8)) {
            return data.subdata(in: range.lowerBound..<data.endIndex)
        }
        return data
    }
}
