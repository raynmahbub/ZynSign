import Foundation

/// How two entitlement claim sets are combined before signing.
///
/// A signing session has up to two claim sources: the claims the application
/// already declares (read from its existing signature, when one is present
/// and readable) and the claims the chosen provisioning profile authorizes.
/// The merge policy states, as a pure function, how they combine — no I/O, no
/// signing, no profile parsing. The pipeline decides whether to apply the
/// result; the policy only answers what the result would be.
enum EntitlementMergeMode: String, CaseIterable, Hashable, Sendable, Codable {

    /// Profile claims only. Existing app claims are ignored. This is the
    /// behavior the pipeline has always used.
    case profileOnly

    /// App claims first, with profile claims overriding any key both
    /// declare. Keys only the app declares survive the merge.
    case appFirstProfileWins

    /// Profile claims first, with app claims overriding any key both
    /// declare. Keys only the profile declares survive the merge. This mode
    /// is provided for inspection and diagnostics; using it can produce
    /// claims the profile does not authorize.
    case profileFirstAppWins

    var displayName: String {
        switch self {
        case .profileOnly: return "Profile claims only"
        case .appFirstProfileWins: return "Keep app claims, profile overrides"
        case .profileFirstAppWins: return "Keep profile claims, app overrides"
        }
    }
}

/// The outcome of one merge, with the facts that produced it.
struct EntitlementMergeResult: Equatable, Hashable, Sendable {

    /// The merged claim set.
    let merged: ProvisioningProfileEntitlements

    /// Keys present in both inputs where the values disagreed and one source
    /// replaced the other. Diagnostic-only; the merge already happened.
    let conflictKeys: Set<String>

    /// Keys contributed only by the application's existing claims.
    let appOnlyKeys: Set<String>

    /// Keys contributed only by the profile.
    let profileOnlyKeys: Set<String>
}

/// The pure merge rules for entitlement claim sets.
enum EntitlementMergePolicy {

    /// Merges two claim sets under a mode.
    ///
    /// - Parameters:
    ///   - appClaims: The claims the application already declares. May be
    ///     empty when nothing was read; may be `nil` when no existing claims
    ///     were established at all, in which case only the profile claims
    ///     exist regardless of mode.
    ///   - profileClaims: The claims the profile authorizes. Always present;
    ///     an empty value set means the profile authorizes nothing.
    ///   - mode: How the two combine.
    static func merge(
        appClaims: ProvisioningProfileEntitlements?,
        profileClaims: ProvisioningProfileEntitlements,
        mode: EntitlementMergeMode
    ) -> EntitlementMergeResult {
        let app = appClaims?.values ?? [:]
        let profile = profileClaims.values
        let hasAppClaims = appClaims != nil

        switch mode {
        case .profileOnly:
            return EntitlementMergeResult(
                merged: profileClaims,
                conflictKeys: [],
                appOnlyKeys: hasAppClaims ? Set(app.keys) : [],
                profileOnlyKeys: Set(profile.keys)
            )
        case .appFirstProfileWins:
            var merged = app
            var conflicts = Set<String>()
            for (key, value) in profile {
                if let existing = merged[key], existing != value {
                    conflicts.insert(key)
                }
                merged[key] = value
            }
            return EntitlementMergeResult(
                merged: ProvisioningProfileEntitlements(values: merged),
                conflictKeys: conflicts,
                appOnlyKeys: Set(app.keys).subtracting(profile.keys),
                profileOnlyKeys: Set(profile.keys).subtracting(app.keys)
            )
        case .profileFirstAppWins:
            var merged = profile
            var conflicts = Set<String>()
            for (key, value) in app {
                if let existing = merged[key], existing != value {
                    conflicts.insert(key)
                }
                merged[key] = value
            }
            return EntitlementMergeResult(
                merged: ProvisioningProfileEntitlements(values: merged),
                conflictKeys: conflicts,
                appOnlyKeys: Set(app.keys).subtracting(profile.keys),
                profileOnlyKeys: Set(profile.keys).subtracting(app.keys)
            )
        }
    }

    /// The claim keys a merge result keeps from the application that a strict
    /// profile-only reviewer should look at before signing. An empty set means
    /// nothing extra travels with the signature.
    static func reviewNeeded(for result: EntitlementMergeResult, mode: EntitlementMergeMode) -> Set<String> {
        switch mode {
        case .profileOnly: return []
        case .appFirstProfileWins, .profileFirstAppWins: return result.appOnlyKeys
        }
    }
}
