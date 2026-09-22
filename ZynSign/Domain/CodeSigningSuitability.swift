import Foundation

/// The result of evaluating whether a certificate appears suitable for code
/// signing.
///
/// Suitability is not a single boolean. It is a layered evaluation that
/// distinguishes:
///
/// - certificate parses,
/// - certificate is within validity period,
/// - certificate has appropriate key characteristics,
/// - certificate appears suitable for the intended signing operation,
/// - Apple/platform policy accepts the identity (not evaluated in this
///   milestone).
///
/// The final policy decision belongs to later signing/verification work. This
/// type records what was checked in this milestone and what remains
/// unevaluated, so that callers cannot mistake absence of a check for a
/// positive result.
struct CodeSigningSuitability: Equatable, Hashable {

    /// Whether the certificate was structurally parseable.
    let isParseable: Bool

    /// The validity-period evaluation, when available.
    let validity: CertificateValidity?

    /// Whether the key characteristics appear adequate for code signing
    /// (e.g. RSA >= 2048, EC >= P-256).
    let hasAdequateKeyCharacteristics: Bool

    /// Whether the certificate appears suitable for code signing based on
    /// the checks performed in this milestone. This is a heuristic, not a
    /// platform policy decision.
    let appearsSuitableForCodeSigning: Bool

    /// The reasons a certificate is considered unsuitable, when it is.
    /// Empty when `appearsSuitableForCodeSigning` is true.
    let unsuitabilityReasons: [UnsuitabilityReason]

    /// Machine-readable reasons for unsuitability.
    enum UnsuitabilityReason: String, CaseIterable, Equatable, Hashable {
        case notParseable
        case expired
        case notYetValid
        case weakKey
        case unknownKeyAlgorithm
        case weakSignatureAlgorithm
        case unknownSignatureAlgorithm
    }

    /// Creates a suitability evaluation.
    init(
        isParseable: Bool,
        validity: CertificateValidity?,
        hasAdequateKeyCharacteristics: Bool,
        appearsSuitableForCodeSigning: Bool,
        unsuitabilityReasons: [UnsuitabilityReason] = []
    ) {
        self.isParseable = isParseable
        self.validity = validity
        self.hasAdequateKeyCharacteristics = hasAdequateKeyCharacteristics
        self.appearsSuitableForCodeSigning = appearsSuitableForCodeSigning
        self.unsuitabilityReasons = unsuitabilityReasons
    }

    /// Evaluates suitability from metadata and an optional validity
    /// evaluation.
    ///
    /// What is checked in this milestone, documented explicitly:
    /// - parsing succeeded (represented by existence of metadata),
    /// - validity period is currently valid,
    /// - public-key algorithm is recognised and key size/curve appears
    ///   adequate (RSA >= 2048, EC >= 256 bits or known P-256+ curve),
    /// - signature algorithm is recognised and not SHA-1 based.
    ///
    /// What is **not** checked in this milestone:
    /// - key usage / extended key usage,
    /// - trust / chain validation,
    /// - Apple/platform code-signing policy acceptance,
    /// - provisioning-profile association,
    /// - private-key availability.
    static func evaluate(
        metadata: CertificateMetadata,
        validity: CertificateValidity? = nil,
        evaluationDate: Date
    ) -> CodeSigningSuitability {
        let resolvedValidity = validity ?? CertificateValidity.evaluate(certificate: metadata, at: evaluationDate)

        var reasons: [UnsuitabilityReason] = []
        var adequateKey = metadata.publicKeyInfo.appearsAdequateForCodeSigning

        if !adequateKey {
            if !metadata.publicKeyInfo.algorithm.isRecognised {
                reasons.append(.unknownKeyAlgorithm)
            } else {
                reasons.append(.weakKey)
            }
        }

        if !metadata.signatureAlgorithm.isRecognised {
            reasons.append(.unknownSignatureAlgorithm)
        } else if metadata.signatureAlgorithm.usesSHA1 {
            reasons.append(.weakSignatureAlgorithm)
        }

        switch resolvedValidity.periodStatus {
        case .expired:
            reasons.append(.expired)
        case .notYetValid:
            reasons.append(.notYetValid)
        case .currentlyValid:
            break
        }

        let appearsSuitable = reasons.isEmpty && adequateKey

        return CodeSigningSuitability(
            isParseable: true,
            validity: resolvedValidity,
            hasAdequateKeyCharacteristics: adequateKey,
            appearsSuitableForCodeSigning: appearsSuitable,
            unsuitabilityReasons: reasons
        )
    }

    /// A suitability for input that could not be parsed at all.
    static func notParseable() -> CodeSigningSuitability {
        CodeSigningSuitability(
            isParseable: false,
            validity: nil,
            hasAdequateKeyCharacteristics: false,
            appearsSuitableForCodeSigning: false,
            unsuitabilityReasons: [.notParseable]
        )
    }
}
