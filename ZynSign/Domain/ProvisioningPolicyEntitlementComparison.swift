import Foundation

/// The result of comparing one requested entitlement claim against a profile's
/// authorized claims.
///
/// The vocabulary mirrors the distinctions the entitlement rules need to keep
/// apart. Collapsing them into "matches" and "does not match" would report a
/// comparison ZynSign cannot perform as a conflict, and would report a value
/// the profile does not authorize as a comparison problem.
enum ProvisioningEntitlementComparisonOutcome: String, CaseIterable, Equatable, Hashable {

    /// The requested claim appears in the profile's allowlist with a value the
    /// documented comparison rule accepts.
    case claimMatchesAuthorization

    /// The profile's allowlist does not carry the requested key at all.
    case claimNotAuthorized

    /// The profile carries the key, and the requested value is not the
    /// authorized value under the comparison rule.
    case claimValueConflicts

    /// The claim's compatibility is decided by a dedicated rule elsewhere
    /// (`application-identifier`, `com.apple.developer.team-identifier`,
    /// `get-task-allow`), so the generic rules must not speak for it.
    case requiresSpecialHandling

    /// The two values cannot be compared under any established rule: a missing
    /// allowlist, numeric representations ZynSign does not coerce, or a
    /// structure whose significance is not established.
    case cannotBeEvaluated

    /// The value uses a form for which ZynSign has no established comparison
    /// rule at all.
    case unsupportedByPolicy
}

/// One requested claim and the outcome of comparing it.
struct ProvisioningEntitlementEvaluation: Equatable, Hashable {

    /// The exact entitlement key as requested.
    let key: String

    /// The comparison outcome.
    let outcome: ProvisioningEntitlementComparisonOutcome
}

/// ZynSign's entitlement-comparison rules.
///
/// The rules are typed and deterministic. What they are **not** is a policy
/// table: ZynSign implements the comparison behaviour its own research record
/// establishes, and reports an unsupported or indeterminate outcome for
/// everything else rather than approving it by default.
///
/// Established behaviour, and its evidence:
///
/// - **Allowlist inclusion [Verified — TN3125].** Every claim the application
///   makes must appear in the profile's `Entitlements` allowlist. A requested
///   key that the allowlist does not carry is therefore a conflict, and the
///   reverse inclusion is allowed: the allowlist may carry claims the
///   application does not make. That is why a request never fails merely
///   because the profile is more permissive, and why a nested dictionary is
///   compared for the keys the request actually claims.
/// - **No coercion [Observed — this repository].** The profile parser keeps
///   property-list types apart and refuses to treat an integer as a boolean.
///   The comparison rules do the same: an integer request is not compared
///   against a real authorization, and a data or date value has no established
///   compatibility rule at all.
/// - **Ordering and multiplicity are not assumed [Inferred].** Identical
///   sequences match. A request whose elements all appear in the authorized
///   array is reported as cannot-be-evaluated, because whether the array is a
///   set, an ordered list, or something else is not established. A request that
///   carries an element the profile does not is a conflict, because the profile
///   does not authorize it.
/// - **Value forms are not interchangeable [Inferred].** A requested string
///   where the profile authorizes an array is a conflict, not an
///   indeterminate result: the requested value is not the authorized value.
///
/// Nothing here strips, rewrites, or synthesizes an entitlement, and nothing
/// here claims that a claim appearing in the allowlist will be accepted by the
/// platform: entitlement enforcement is performed by the system and is outside
/// this boundary.
enum ProvisioningEntitlementComparator {

    /// The nesting depth a comparison walks before it reports the value as
    /// unsupported. The parser bounds the values it produces, so this only
    /// guards directly constructed inputs.
    static let maximumDepth = 32

    /// Keys whose compatibility a dedicated rule decides. The generic rules
    /// never speak for these.
    static let speciallyHandledKeys: Set<String> = [
        ProvisioningProfileEntitlementKeys.applicationIdentifier,
        ProvisioningProfileEntitlementKeys.teamIdentifier,
        ProvisioningProfileEntitlementKeys.getTaskAllow,
    ]

    /// Whether a claim's compatibility is decided by a dedicated rule.
    static func isSpeciallyHandled(_ key: String) -> Bool {
        speciallyHandledKeys.contains(key)
    }

    /// Compares every requested claim, in deterministic key order.
    ///
    /// - Parameters:
    ///   - requested: The claims the caller intends to make.
    ///   - authorized: The profile's allowlist, or `nil` when the profile
    ///     carried none.
    /// - Returns: One evaluation per requested key, sorted by key.
    static func evaluate(
        requested: ProvisioningProfileEntitlements,
        against authorized: ProvisioningProfileEntitlements?
    ) -> [ProvisioningEntitlementEvaluation] {
        requested.keys.map { key in
            ProvisioningEntitlementEvaluation(
                key: key,
                outcome: compare(
                    requestedKey: key,
                    requestedValue: requested[key],
                    authorized: authorized
                )
            )
        }
    }

    /// Compares one requested claim against the profile's allowlist.
    ///
    /// - Parameters:
    ///   - requestedKey: The exact entitlement key requested.
    ///   - requestedValue: The requested value.
    ///   - authorized: The profile's allowlist, or `nil` when the profile
    ///     carried none.
    /// - Returns: The comparison outcome. A `nil` allowlist cannot be compared
    ///   against, and a missing authorized value is never invented.
    static func compare(
        requestedKey: String,
        requestedValue: ProvisioningProfileValue?,
        authorized: ProvisioningProfileEntitlements?
    ) -> ProvisioningEntitlementComparisonOutcome {
        if isSpeciallyHandled(requestedKey) { return .requiresSpecialHandling }
        guard let authorized else { return .cannotBeEvaluated }
        guard let requestedValue else { return .cannotBeEvaluated }
        guard let authorizedValue = authorized[requestedKey] else { return .claimNotAuthorized }
        return compare(requested: requestedValue, authorized: authorizedValue, depth: 0)
    }

    /// Compares two values under the documented rules.
    static func compare(
        requested: ProvisioningProfileValue,
        authorized: ProvisioningProfileValue
    ) -> ProvisioningEntitlementComparisonOutcome {
        compare(requested: requested, authorized: authorized, depth: 0)
    }

    private static func compare(
        requested: ProvisioningProfileValue,
        authorized: ProvisioningProfileValue,
        depth: Int
    ) -> ProvisioningEntitlementComparisonOutcome {
        guard depth <= maximumDepth else { return .unsupportedByPolicy }

        switch (requested, authorized) {
        case (.string(let requestedText), .string(let authorizedText)):
            return requestedText == authorizedText ? .claimMatchesAuthorization : .claimValueConflicts

        case (.boolean(let requestedFlag), .boolean(let authorizedFlag)):
            return requestedFlag == authorizedFlag ? .claimMatchesAuthorization : .claimValueConflicts

        case (.integer(let requestedNumber), .integer(let authorizedNumber)):
            return requestedNumber == authorizedNumber ? .claimMatchesAuthorization : .claimValueConflicts

        case (.real(let requestedNumber), .real(let authorizedNumber)):
            return requestedNumber == authorizedNumber ? .claimMatchesAuthorization : .claimValueConflicts

        case (.integer, .real), (.real, .integer):
            // Exact numeric representations are preserved everywhere else in
            // the pipeline; coercing here would invent an equality.
            return .cannotBeEvaluated

        case (.array(let requestedElements), .array(let authorizedElements)):
            return arrayOutcome(requested: requestedElements, authorized: authorizedElements)

        case (.dictionary(let requestedEntries), .dictionary(let authorizedEntries)):
            return dictionaryOutcome(requested: requestedEntries, authorized: authorizedEntries, depth: depth)

        case (.data, _), (_, .data), (.date, _), (_, .date):
            return .unsupportedByPolicy

        default:
            return .claimValueConflicts
        }
    }

    private static func arrayOutcome(
        requested: [ProvisioningProfileValue],
        authorized: [ProvisioningProfileValue]
    ) -> ProvisioningEntitlementComparisonOutcome {
        if requested == authorized { return .claimMatchesAuthorization }
        // Membership must remain linear for large Studio allowlists. This
        // preserves the existing ordering/multiplicity uncertainty below.
        let authorizedElements = Set(authorized)
        for element in requested where !authorizedElements.contains(element) {
            return .claimValueConflicts
        }
        return .cannotBeEvaluated
    }

    private static func dictionaryOutcome(
        requested: [String: ProvisioningProfileValue],
        authorized: [String: ProvisioningProfileValue],
        depth: Int
    ) -> ProvisioningEntitlementComparisonOutcome {
        var outcome = ProvisioningEntitlementComparisonOutcome.claimMatchesAuthorization
        for key in requested.keys.sorted() {
            guard let requestedValue = requested[key] else { continue }
            guard let authorizedValue = authorized[key] else {
                // The profile does not authorize the key the request claims.
                return .claimValueConflicts
            }
            outcome = combined(
                outcome,
                compare(requested: requestedValue, authorized: authorizedValue, depth: depth + 1)
            )
        }
        return outcome
    }

    /// Combines nested outcomes, keeping the most specific finding: a conflict
    /// outranks an unsupported or incomparable value, which outranks a match.
    private static func combined(
        _ left: ProvisioningEntitlementComparisonOutcome,
        _ right: ProvisioningEntitlementComparisonOutcome
    ) -> ProvisioningEntitlementComparisonOutcome {
        rank(left) >= rank(right) ? left : right
    }

    private static func rank(_ outcome: ProvisioningEntitlementComparisonOutcome) -> Int {
        switch outcome {
        case .claimMatchesAuthorization: return 0
        case .cannotBeEvaluated: return 1
        case .unsupportedByPolicy: return 2
        case .claimValueConflicts: return 3
        case .claimNotAuthorized: return 4
        case .requiresSpecialHandling: return 5
        }
    }
}
