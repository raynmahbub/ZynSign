import Foundation

/// The kind of code-signing certificate, as declared by its subject common
/// name.
///
/// Apple's code-signing certificates name their purpose as a prefix of the
/// common name — "Apple Development: …", "iPhone Distribution: …", and so
/// on. The classification reads that prefix and nothing else: it makes no
/// trust decision, no chain evaluation, and no statement about whether the
/// certificate can actually perform the work its name suggests. A
/// certificate whose common name carries no recognised prefix is `.other` —
/// a real certificate of unknown purpose, not an error.
enum SigningCertificateKind: String, CaseIterable, Equatable, Hashable {

    /// A development-purpose certificate (debug builds, Xcode-managed
    /// development).
    case development

    /// A distribution-purpose certificate (App Store and ad hoc
    /// distribution builds).
    case distribution

    /// A certificate whose subject declares a purpose ZynSign does not
    /// classify — including non-Apple certificates.
    case other

    /// The user-presentable name of the kind.
    var displayName: String {
        switch self {
        case .development: return "Development"
        case .distribution: return "Distribution"
        case .other: return "Other"
        }
    }

    /// The common-name prefixes that mark a development-purpose certificate,
    /// current Apple names first and legacy names after.
    static let developmentPrefixes: [String] = [
        "Apple Development:",
        "Xcode Provisioning:",
        "iPhone Developer:",
        "Mac Developer:",
    ]

    /// The common-name prefixes that mark a distribution-purpose certificate,
    /// current Apple names first and legacy names after.
    static let distributionPrefixes: [String] = [
        "Apple Distribution:",
        "iPhone Distribution:",
        "Mac Distribution:",
    ]

    /// Classifies a certificate by the prefix its common name declares.
    ///
    /// An absent or unrecognised common name is `.other`, never an error —
    /// classification is a display aid, and an unrecognised name says nothing
    /// wrong about the certificate.
    static func classify(commonName: String?) -> SigningCertificateKind {
        guard let commonName else { return .other }
        let trimmed = commonName.trimmingCharacters(in: .whitespaces)
        if developmentPrefixes.contains(where: { trimmed.hasPrefix($0) }) {
            return .development
        }
        if distributionPrefixes.contains(where: { trimmed.hasPrefix($0) }) {
            return .distribution
        }
        return .other
    }

    /// Classifies a certificate from its subject.
    static func classify(subject: CertificateDistinguishedName) -> SigningCertificateKind {
        classify(commonName: subject.commonName)
    }
}
