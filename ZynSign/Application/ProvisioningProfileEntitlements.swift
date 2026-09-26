import Foundation

/// Derives the entitlement set a signing run should embed from a
/// provisioning-profile container.
///
/// The same derivation the signing screen uses. A preset, a one-tap
/// confirmation, and the manual wizard must not disagree about which
/// claims a profile authorizes.
enum SigningProfileEntitlementDerivation {
    static func derive(from data: Data) throws -> CodeSigningEntitlements {
        let payload: Data
        if let cms = try? CMSStructureReader.read(data), let content = cms.encapsulatedContent {
            payload = content
        } else if let range = data.range(of: Data("<?xml".utf8)) {
            payload = data.subdata(in: range.lowerBound..<data.endIndex)
        } else if let range = data.range(of: Data("bplist00".utf8)) {
            payload = data.subdata(in: range.lowerBound..<data.endIndex)
        } else {
            payload = data
        }
        let parser = PropertyListProvisioningProfileParser()
        do {
            let profile = try parser.parse(ProvisioningProfilePayload(plistData: payload))
            if let entitlements = profile.entitlements {
                return try CodeSigningEntitlements(profileEntitlements: entitlements)
            }
            return try CodeSigningEntitlements(values: [:])
        } catch {
            if let direct = try? EntitlementsPlistParser.parse(payload) { return direct }
            throw error
        }
    }
}
