import Foundation
import CoreFoundation

/// Structured failures at the signing-entitlements boundary.
///
/// The cases distinguish the stage that refused — decoding a property list,
/// accepting a value's type, accepting a key, staying within bounds — so an
/// entitlement problem is never reported as an undifferentiated signing
/// failure. Diagnostics carry stage names and bounded counts only; they never
/// carry entitlement values or serialized bytes.
enum EntitlementsError: Error, Equatable {
    /// The presented payload was empty.
    case emptyPayload
    /// The payload exceeded the configured byte bound.
    case payloadTooLarge
    /// The bytes were not a decodable property list, or the root was not a
    /// dictionary.
    case malformedPlist
    /// The property list used a format ZynSign does not accept (OpenStep).
    case unsupportedPlistFormat
    /// A value used a type outside the supported property-list types, or a
    /// type the entitlements model deliberately excludes (date).
    case unsupportedValueType
    /// A key was empty, oversized, or contained a control character.
    case invalidKey
    /// A numeric value was not finite.
    case nonFiniteNumber
    /// The tree exceeded the configured depth, node, or collection bounds.
    case resourceLimitExceeded
    /// The embedded entitlements blob framing (magic/length) was invalid.
    case invalidBlobFraming
    /// A requirements of the entitlement set cannot be evaluated here.
    case notRepresentable
}

/// The typed representation of one signing target's entitlement claims.
///
/// This is the canonical in-process form of entitlement data: keys are exact
/// strings, values keep their property-list types through the existing
/// `ProvisioningProfileValue` tree, and unknown entitlement names are
/// preserved rather than filtered. There is deliberately no enum of
/// currently-known Apple entitlement names — an entitlement ZynSign has never
/// seen must remain representable, because a profile allowlist may authorize
/// it and a signing configuration may need to claim it.
///
/// ## What this type is not
///
/// A `CodeSigningEntitlements` value is **decoded, structurally valid data**.
/// It is not, by itself:
///
/// - provisioning-compatible — that is a separate evaluation against an
///   authenticated profile (see `EntitlementsProvisioningValidation`);
/// - embedded — that happens when the signing pipeline serializes these
///   claims, frames them into the entitlements blob, and places their digest
///   in CodeDirectory special slot 5;
/// - platform-authorized — whether iOS/iPadOS accepts a claim is decided by
///   the platform, never inferred from local construction.
///
/// These five states — parsed, structurally valid, provisioning-compatible,
/// embedded, platform-authorized — are kept apart on purpose. No single
/// `isAuthorized`-style flag exists anywhere in this model.
struct CodeSigningEntitlements: Equatable, Hashable {

    /// The bound applied when validating directly constructed values. The
    /// parsing path reaches the same bounds through
    /// `ProvisioningProfileParsingLimits`.
    static let limits = ProvisioningProfileParsingLimits.default

    /// The claims, keyed by their exact property-list key.
    ///
    /// The dictionary is a lookup structure, not an ordering: every ordered
    /// view (serialization, comparison, diagnostics) sorts keys explicitly.
    let values: [String: ProvisioningProfileValue]

    /// Creates an entitlement set from typed claims, validating structure.
    ///
    /// - Throws: `EntitlementsError` when a key is unusable, a value carries
    ///   an excluded type, or a bound is exceeded. The caller's dictionary is
    ///   never mutated.
    init(values: [String: ProvisioningProfileValue]) throws {
        var validated: [String: ProvisioningProfileValue] = [:]
        validated.reserveCapacity(values.count)
        guard values.count <= Self.limits.maximumCollectionCount else {
            throw EntitlementsError.resourceLimitExceeded
        }
        var nodeCount = 0
        for key in values.keys.sorted(by: CanonicalPropertyListXMLSerializer.utf8Ascending) {
            try Self.validateKey(key)
            guard let value = values[key] else { throw EntitlementsError.invalidKey }
            try Self.validateValue(value, depth: 0, nodeCount: &nodeCount)
            validated[key] = value
        }
        self.values = validated
    }

    /// The claim keys in canonical (ascending UTF-8 byte) order.
    var keys: [String] {
        values.keys.sorted(by: CanonicalPropertyListXMLSerializer.utf8Ascending)
    }

    /// Accesses one claim by its exact key.
    subscript(key: String) -> ProvisioningProfileValue? {
        values[key]
    }

    /// The number of claims.
    var count: Int { values.count }

    /// Whether the claim set is empty. An empty set is representable and
    /// serializable; it is not treated as "no entitlements were requested",
    /// which is represented by the absence of the set, not by emptiness.
    var isEmpty: Bool { values.isEmpty }

    /// The same claims as the profile-entitlements view the existing ZS-020
    /// policy layer consumes. This is a representation bridge, not a copy of
    /// policy: every rule still lives in `ProvisioningPolicyValidator`.
    var profileEntitlements: ProvisioningProfileEntitlements {
        ProvisioningProfileEntitlements(values: values)
    }

    /// Adapts a profile's parsed entitlements into the signing-entitlements
    /// model, applying this model's structural rules. A profile value the
    /// signing form excludes (date) fails closed instead of being coerced.
    init(profileEntitlements: ProvisioningProfileEntitlements) throws {
        try self.init(values: profileEntitlements.values)
    }

    // MARK: - Structural validation

    /// Key rules mirror the profile parser's entitlement-key rules: non-empty,
    /// bounded, and free of control characters. This is input validation, not
    /// a statement about which keys the platform honors.
    private static func validateKey(_ key: String) throws {
        guard !key.isEmpty,
              key.utf8.count <= limits.maximumStringByteCount,
              !key.contains(where: { $0.isControl }) else {
            throw EntitlementsError.invalidKey
        }
    }

    /// Walks one value tree enforcing the model's bounds and type set.
    ///
    /// Dates are excluded by ZynSign policy: no deterministic canonical
    /// serialization for dates is established (see
    /// `CanonicalPropertyListXMLSerializer`), and a silent format choice here
    /// would become a hashing boundary by accident.
    private static func validateValue(
        _ value: ProvisioningProfileValue,
        depth: Int,
        nodeCount: inout Int
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
                try validateKey(key)
                guard let entry = entries[key] else { throw EntitlementsError.invalidKey }
                try validateValue(entry, depth: depth + 1, nodeCount: &nodeCount)
            }
        }
    }
}

/// Decodes entitlement bytes into the typed entitlement model.
///
/// Reading reuses the repository's existing property-list boundary:
/// Foundation's `PropertyListSerialization` performs the byte-level decode,
/// and the bounded `ProvisioningProfileValue` conversion enforces resource
/// limits while preserving types. Both XML and binary property lists are
/// accepted on read, because entitlement blobs produced by other toolchains
/// have been observed in both encodings; OpenStep is refused.
///
/// A successful decode says the bytes became a typed tree — nothing about
/// provisioning compatibility or platform acceptance.
enum EntitlementsPlistParser {

    /// The upper bound for one entitlement payload. ZynSign policy, chosen to
    /// bound work on untrusted input; it is not an Apple-documented limit.
    static let maximumPayloadByteCount = 1 * 1_024 * 1_024

    /// Decodes entitlement bytes.
    ///
    /// - Parameters:
    ///   - bytes: Untrusted payload bytes: an XML or binary property list
    ///     whose root is a dictionary.
    ///   - limits: Resource bounds for the value conversion.
    /// - Throws: `EntitlementsError` for every refusal. No partial model is
    ///   returned and no caller data is mutated.
    static func parse(
        _ bytes: Data,
        limits: ProvisioningProfileParsingLimits = .default
    ) throws -> CodeSigningEntitlements {
        guard !bytes.isEmpty else { throw EntitlementsError.emptyPayload }
        guard bytes.count <= maximumPayloadByteCount else {
            throw EntitlementsError.payloadTooLarge
        }

        var format = PropertyListSerialization.PropertyListFormat.openStep
        let root: Any
        do {
            root = try PropertyListSerialization.propertyList(
                from: bytes,
                options: [],
                format: &format
            )
        } catch {
            throw EntitlementsError.malformedPlist
        }
        guard format != .openStep else {
            throw EntitlementsError.unsupportedPlistFormat
        }
        guard let dictionary = root as? [String: Any] else {
            throw EntitlementsError.malformedPlist
        }
        guard dictionary.count <= limits.maximumCollectionCount else {
            throw EntitlementsError.resourceLimitExceeded
        }

        // Reuse the existing bounded conversion. Its ProvisioningProfileFailure
        // reasons are translated so this boundary owns its own vocabulary.
        let decoded: ProvisioningProfileValue
        do {
            decoded = try ProvisioningProfileValue.decode(.dictionary(dictionary), limits: limits)
        } catch let error as ZynSignError {
            throw translate(error)
        }
        guard case .dictionary(let entries) = decoded else {
            throw EntitlementsError.malformedPlist
        }
        return try CodeSigningEntitlements(values: entries)
    }

    private static func translate(_ error: ZynSignError) -> EntitlementsError {
        guard let reason = error.provisioningProfileFailure else {
            return .malformedPlist
        }
        switch reason {
        case .resourceLimitExceeded:
            return .resourceLimitExceeded
        case .unsupportedValue:
            return .unsupportedValueType
        case .invalidFieldValue:
            return .invalidKey
        case .invalidDate:
            return .unsupportedValueType
        default:
            return .malformedPlist
        }
    }
}

/// The bridge between a signing-entitlement set and the existing ZS-020
/// provisioning policy.
///
/// Entitlement-to-profile compatibility is decided by exactly one
/// implementation: `ProvisioningPolicyValidator`, reached through the same
/// `ProvisioningPolicyValidationContext` the integrated provisioning
/// pipeline uses. This type only adapts the entitlement model into that
/// context's `SigningConfiguration`; it contains no policy rules of its own
/// and invents none. Where the policy layer reports an outcome as
/// indeterminate, that indeterminacy is preserved, never upgraded to a pass.
struct EntitlementsProvisioningValidation {

    /// Evaluates one entitlement set against a provisioning-policy context.
    ///
    /// The supplied context's requested claim set is replaced by the
    /// entitlements under evaluation; every other fact — the authenticated
    /// profile, the identity, the device and platform context — is used as
    /// given. The `get-task-allow` typed preference is carried through when
    /// the caller states one, using the existing `SigningConfiguration`
    /// semantics.
    ///
    /// - Returns: The policy layer's own staged result. Its entitlements
    ///   category carries the per-claim findings; its overall outcome is
    ///   `compatible` only when every category the context supported was
    ///   satisfied. A `compatible` outcome means the claims satisfy ZynSign's
    ///   implemented rules — not that the platform will authorize them.
    static func evaluate(
        entitlements: CodeSigningEntitlements,
        context: ProvisioningPolicyValidationContext,
        getTaskAllow: SigningGetTaskAllowPreference = .unspecified,
        intendedProfileClass: ProvisioningProfileClassification? = nil,
        clock: any EvaluationClock
    ) -> ProvisioningPolicyValidationResult {
        let configuration = SigningConfiguration(
            entitlements: entitlements.profileEntitlements,
            getTaskAllow: getTaskAllow,
            intendedProfileClass: intendedProfileClass
                ?? context.signingConfiguration.intendedProfileClass
        )
        let evaluationContext = ProvisioningPolicyValidationContext(
            profile: context.profile,
            profileAuthenticity: context.profileAuthenticity,
            certificateRelationship: context.certificateRelationship,
            applicationMetadata: context.applicationMetadata,
            bundleIdentifier: context.bundleIdentifier,
            signingIdentity: context.signingIdentity,
            signingConfiguration: configuration,
            deviceContext: context.deviceContext,
            intendedPlatforms: context.intendedPlatforms
        )
        return ProvisioningPolicyValidator(clock: clock).validate(evaluationContext)
    }
}

/// The record of an entitlement set's embedding into a signature structure.
///
/// Produced only by the signing pipeline after the entitlement bytes have been
/// serialized, framed, and digested. The platform-authorization question is
/// represented explicitly as not evaluated, because no local operation can
/// answer it.
struct EmbeddedEntitlementsRecord: Equatable, Hashable {

    /// The exact serialized entitlements blob bytes that were embedded
    /// (header included). These are the bytes whose digest occupies special
    /// slot 5.
    let blobBytes: Data

    /// The digest placed in CodeDirectory special slot 5.
    let specialSlotDigest: Digest

    /// Platform authorization is never inferred from embedding.
    enum PlatformAuthorization: Equatable, Hashable {
        case notEvaluated
        case requiresPlatformVerification
    }

    /// Always `.notEvaluated` on this path: local construction cannot
    /// establish that the platform accepts these entitlements.
    let platformAuthorization: PlatformAuthorization
}
