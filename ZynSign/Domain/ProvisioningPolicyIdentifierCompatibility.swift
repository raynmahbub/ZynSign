import Foundation

/// The outcome of comparing an identifier against a profile's application
/// identifier scope.
enum ProvisioningIdentifierCompatibilityOutcome: String, CaseIterable, Equatable, Hashable {

    /// The profile declares exactly the identifier being compared.
    case exactMatch

    /// The profile's identifier is a wildcard whose documented scope covers the
    /// identifier being compared.
    case wildcardMatch

    /// The identifier lies outside the scope the profile declares.
    case mismatch

    /// The scope cannot be established, so no comparison is possible. This is
    /// not a mismatch: nothing was found to disagree.
    case indeterminate

    /// Whether the profile's scope covers the identifier.
    var isCovered: Bool {
        self == .exactMatch || self == .wildcardMatch
    }
}

/// The single rule that decides whether a profile's application identifier
/// covers another application identifier.
///
/// The rule exists once so that the bundle-identifier check and the
/// `application-identifier` claim check cannot drift apart: both ask this value
/// object, and neither re-implements identifier matching.
///
/// Matching semantics, stated explicitly because the two cases are not the
/// same operation:
///
/// - **Exact.** When the profile's application identifier has an exact bundle
///   component derived from a declared application-identifier prefix, the
///   comparison is equality of that component. Nothing else is covered.
/// - **Wildcard.** When the profile's application identifier has a trailing
///   wildcard component, the comparison is a prefix test at a component
///   boundary. For a full application-identifier value the scope is
///   `<application-identifier prefix>.<component prefix>`; for a bundle
///   identifier it is the component prefix alone, because the
///   application-identifier prefix, which is a team identifier, is not part of
///   a bundle identifier. A profile whose identifier is a bare `<prefix>.*`
///   therefore covers every bundle identifier. A wildcard never matches across
///   a component boundary that is not part of the scope, so `com.example.*`
///   does not cover `com.exampleOther.app`.
///   **[Inferred — from the App ID form Apple documents; not measured against
///   the platform.]**
/// - **No prefix.** `ProvisioningApplicationIdentifier` derives a bundle
///   component only when an explicit application-identifier prefix makes the
///   split safe. Without one, a full value that equals the compared identifier
///   exactly is an exact match, and every other case is indeterminate, because
///   splitting an identifier at an unstated boundary would invent structure.
///
/// A covered identifier is not an authorization. This rule says ZynSign's
/// matching predicate holds; CMS authenticity, certificate relationships,
/// device provisioning, entitlement authorization, and platform acceptance are
/// separate questions with separate evidence.
struct ProvisioningIdentifierCompatibility: Equatable, Hashable {

    /// The profile's application identifier, when it carried one.
    let applicationIdentifier: ProvisioningApplicationIdentifier?

    init(applicationIdentifier: ProvisioningApplicationIdentifier?) {
        self.applicationIdentifier = applicationIdentifier
    }

    init(profile: ProvisioningProfile) {
        self.init(applicationIdentifier: profile.applicationIdentifier)
    }

    /// The scope a wildcard component declares over a full application
    /// identifier, including the application-identifier prefix. `nil` when the
    /// profile's identifier is not a wildcard or carries no usable prefix.
    var wildcardScopePrefix: String? {
        guard let applicationIdentifier,
              let declaredPrefix = applicationIdentifier.applicationIdentifierPrefix,
              !declaredPrefix.isEmpty,
              case .wildcard(let componentPrefix) = applicationIdentifier.bundleIdentifierComponent else {
            return nil
        }
        return declaredPrefix + "." + componentPrefix
    }

    /// The scope a wildcard component declares over a bundle identifier.
    ///
    /// The application-identifier prefix is not part of a bundle identifier, so
    /// this scope is the component prefix alone: a profile whose identifier is
    /// `TEAM123456.com.example.*` covers the bundle identifier
    /// `com.example.app`, and a profile whose identifier is `TEAM123456.*`
    /// covers every bundle identifier. `nil` when the component is not a
    /// wildcard.
    var wildcardBundleScopePrefix: String? {
        guard let applicationIdentifier,
              case .wildcard(let componentPrefix) = applicationIdentifier.bundleIdentifierComponent else {
            return nil
        }
        return componentPrefix
    }

    /// Compares an application bundle identifier against the profile's scope.
    func outcome(forBundleIdentifier bundleIdentifier: BundleIdentifier) -> ProvisioningIdentifierCompatibilityOutcome {
        guard let applicationIdentifier else { return .indeterminate }

        switch applicationIdentifier.bundleIdentifierComponent {
        case .none:
            // No explicit prefix was declared, so ZynSign refuses to split the
            // value. Text equality is still decisive.
            return applicationIdentifier.fullValue == bundleIdentifier.rawValue ? .exactMatch : .indeterminate
        case .some(.exact(let declared)):
            return declared == bundleIdentifier ? .exactMatch : .mismatch
        case .some(.wildcard):
            guard let scope = wildcardBundleScopePrefix else { return .indeterminate }
            return bundleIdentifier.rawValue.hasPrefix(scope) ? .wildcardMatch : .mismatch
        }
    }

    /// Compares a full application-identifier value, such as a requested
    /// `application-identifier` entitlement claim, against the profile's scope.
    ///
    /// The claim is compared as text plus the documented prefix rule; it is
    /// never re-parsed into a prefix and a component, so a claim cannot widen
    /// the scope by carrying a wildcard of its own.
    func outcome(forApplicationIdentifierValue value: String) -> ProvisioningIdentifierCompatibilityOutcome {
        guard !value.isEmpty else { return .indeterminate }
        guard let applicationIdentifier else { return .indeterminate }

        if value == applicationIdentifier.fullValue { return .exactMatch }

        switch applicationIdentifier.bundleIdentifierComponent {
        case .none:
            // Without a declared prefix the only decisive comparison is exact
            // text equality, which has already failed.
            return .indeterminate
        case .some(.exact):
            return .mismatch
        case .some(.wildcard):
            guard let scope = wildcardScopePrefix else { return .indeterminate }
            return value.hasPrefix(scope) ? .wildcardMatch : .mismatch
        }
    }

    /// The application identifier a bundle identifier would take under the
    /// profile's declared prefix, when that prefix is known. Used to check that
    /// a requested claim describes the application actually being signed.
    func expectedApplicationIdentifier(for bundleIdentifier: BundleIdentifier) -> String? {
        guard let declaredPrefix = applicationIdentifier?.applicationIdentifierPrefix,
              !declaredPrefix.isEmpty else { return nil }
        return declaredPrefix + "." + bundleIdentifier.rawValue
    }
}
