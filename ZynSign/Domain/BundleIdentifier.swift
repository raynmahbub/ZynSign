/// A syntactically validated bundle identifier, such as the identifier an
/// application bundle declares for itself inside an imported package.
///
/// Validation is deliberately conservative and purely syntactic: identifiers
/// are non-empty, length-bounded, restricted to ASCII letters, digits,
/// hyphens, and periods, and contain no empty dot-separated components. These
/// are ZynSign's own acceptance rules for identity values; they make no claim
/// about what any platform accepts or rejects, and they are not evidence that
/// a bundle is genuine, loadable, or signed.
struct BundleIdentifier: Equatable, Hashable, CustomStringConvertible {

    /// Upper bound for accepted identifiers. A conservative guard against
    /// pathological input, not a platform limit.
    static let maximumLength = 255

    /// The validated identifier, exactly as supplied.
    let rawValue: String

    /// Creates a validated identifier, or returns `nil` when the candidate
    /// fails ZynSign's syntactic rules.
    init?(rawValue: String) {
        guard Self.isValid(rawValue) else { return nil }
        self.rawValue = rawValue
    }

    /// ZynSign's syntactic acceptance rule for bundle identifiers.
    static func isValid(_ candidate: String) -> Bool {
        guard !candidate.isEmpty else { return false }
        guard candidate.count <= maximumLength else { return false }
        let permittedCharacters = { (character: Character) in
            (character.isASCII && (character.isLetter || character.isNumber))
                || character == "-"
                || character == "."
        }
        guard candidate.allSatisfy(permittedCharacters) else { return false }
        let components = candidate.split(separator: ".", omittingEmptySubsequences: false)
        return components.allSatisfy { !$0.isEmpty }
    }

    var description: String { rawValue }
}
