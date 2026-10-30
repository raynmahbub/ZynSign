import Foundation

/// The single canonical entitlement validation policy shared by XML and DER.
///
/// Both serializers derive from `CodeSigningEntitlements`, and that type is the
/// enforcement point: any string that cannot be represented in both encodings
/// is rejected at construction, so two serializers over the same model cannot
/// diverge.
///
/// The policy encodes three facts:
///
/// 1. Every string — key or value, including nested values — must be valid XML
///    1.0 character data (Char production). The XML canonical form is the only
///    form that survives hashing: a NUL, a forbidden control, a lone surrogate,
///    or `FFFE`/`FFFF` has no canonical XML representation and therefore cannot
///    be hashed deterministically. DER can carry those bytes, but the canonical
///    model does not — the two serializations represent identical claims by
///    refusing the same inputs.
/// 2. Node accounting counts every `ProvisioningProfileValue` node (container
///    or scalar) exactly once. Dictionary keys are not nodes; their length is
///    bounded by the same string bound. Depth counts nesting of containers.
///    Collection count bounds every array and dictionary's direct element count.
///    The three limits together bound total work.
/// 3. Diagnostics are typed and redacted: they name the stage and the bound
///    category, never the entitlement value or serialized bytes.
///
/// These limits are ZynSign policy — not Apple limits — chosen to bound work
/// on untrusted input.
enum EntitlementCanonicalValidator {

    /// XML 1.0 Char production — the shared string validity rule.
    ///
    /// Valid scalars are `0x09`, `0x0A`, `0x0D`, `0x20…0xD7FF`, `0xE000…0xFFFD`,
    /// `0x10000…0x10FFFF`. This matches `CanonicalPropertyListXMLSerializer.isValidXMLText`
    /// and is the canonical entitlement string rule.
    static func isValidEntitlementString(_ text: String) -> Bool {
        // Delegate to the canonical serializer's own rule so there is exactly
        // one spelling of the character production.
        CanonicalPropertyListXMLSerializer.isValidXMLText(text)
    }

    /// Validates that a key satisfies the canonical key rules.
    static func validateKey(_ key: String, limits: ProvisioningProfileParsingLimits) throws {
        guard !key.isEmpty,
              key.utf8.count <= limits.maximumStringByteCount,
              !key.contains(where: { $0.isControl }),
              isValidEntitlementString(key) else {
            throw EntitlementsError.invalidKey
        }
    }

    /// Validates a value tree against the canonical policy, counting nodes
    /// and enforcing depth, string, data and collection bounds.
    ///
    /// This is the single node-counting implementation consumed by both the
    /// canonical model (`CodeSigningEntitlements`) and the DER decoder's
    /// budget checks: every value node is counted once, depth is incremented
    /// for children, and collection sizes are checked.
    static func validateValue(
        _ value: ProvisioningProfileValue,
        depth: Int,
        nodeCount: inout Int,
        limits: ProvisioningProfileParsingLimits
    ) throws {
        guard depth <= limits.maximumNestingDepth else {
            throw EntitlementsError.resourceLimitExceeded
        }
        nodeCount += 1
        guard nodeCount <= limits.maximumValueNodeCount else {
            throw EntitlementsError.resourceLimitExceeded
        }
        switch value {
        case .string(let text):
            guard text.utf8.count <= limits.maximumStringByteCount else {
                throw EntitlementsError.resourceLimitExceeded
            }
            guard isValidEntitlementString(text) else {
                throw EntitlementsError.invalidXMLString
            }
        case .boolean:
            break
        case .integer:
            break
        case .real(let number):
            guard number.isFinite else { throw EntitlementsError.nonFiniteNumber }
        case .data(let bytes):
            guard bytes.count <= limits.maximumDataByteCount else {
                throw EntitlementsError.resourceLimitExceeded
            }
        case .date:
            throw EntitlementsError.unsupportedValueType
        case .array(let elements):
            guard elements.count <= limits.maximumCollectionCount else {
                throw EntitlementsError.resourceLimitExceeded
            }
            for element in elements {
                try validateValue(element, depth: depth + 1, nodeCount: &nodeCount)
            }
        case .dictionary(let entries):
            guard entries.count <= limits.maximumCollectionCount else {
                throw EntitlementsError.resourceLimitExceeded
            }
            for key in entries.keys {
                try validateKey(key, limits: limits)
                guard let entry = entries[key] else { throw EntitlementsError.invalidKey }
                try validateValue(entry, depth: depth + 1, nodeCount: &nodeCount)
            }
        }
    }
}
