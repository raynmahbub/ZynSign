import Foundation

/// The data a signing operation acts on, with its semantics stated
/// explicitly.
///
/// A message and a digest are different inputs even when they happen to
/// carry the same byte count. A message is hashed by the platform primitive
/// under the selected operation; a digest is already hashed and is signed
/// as-is. ZynSign does not convert one into the other, and a 32-byte message
/// is never silently re-read as a digest.
enum SigningInput: Equatable, Hashable {

    /// Raw message bytes. The platform primitive hashes them under the
    /// selected operation.
    case message(Data)

    /// An already-computed digest, with its algorithm stated explicitly.
    /// The algorithm must be the one the selected operation works on.
    case digest(Digest)
}

/// Optional context describing why an operation is being performed.
///
/// The context is diagnostic only: it never influences the cryptographic
/// operation, and it is carried on the result so a later diagnostic can say
/// which operation produced a signature without repeating the work.
struct SigningOperationContext: Equatable, Hashable {

    /// The longest label the operation context carries, in characters.
    /// ZynSign policy, not a platform limit.
    static let maximumLabelLength = 128

    /// A short label for the operation, e.g. a stage name. Bounded so the
    /// context cannot carry unbounded text into diagnostics.
    let label: String

    /// Creates an operation context, or returns `nil` when `label` is empty,
    /// longer than the bound, or carries line breaks.
    init?(label: String) {
        guard !label.isEmpty,
              label.count <= SigningOperationContext.maximumLabelLength,
              !label.contains(where: \.isNewline) else { return nil }
        self.label = label
    }
}

/// A focused description of one generic cryptographic signing operation.
///
/// The request names the identity whose capability performs the work, the
/// operation, and the data — explicitly as a message or as a digest. It
/// carries no private-key material, no password, no key reference, no
/// filesystem path, and no knowledge of Mach-O, bundles, profiles, or
/// interfaces: the cryptographic layer stays reusable by the code-signing
/// construction that will consume it later.
struct SigningRequest: Equatable, Hashable {

    /// The identity whose signing capability performs the operation.
    let identityID: SigningIdentityIdentifier

    /// The signature operation to perform: key family, digest algorithm,
    /// and input semantics in one explicit value.
    let algorithm: SigningAlgorithm

    /// The data to sign, with its message-or-digest semantics explicit.
    let input: SigningInput

    /// Optional diagnostic context for the operation, when the caller has
    /// one.
    let context: SigningOperationContext?

    /// Creates a signing request.
    ///
    /// The initializer accepts any combination; `validate()` states the
    /// rules, so an invalid request is a structured failure rather than a
    /// construction crash.
    init(
        identityID: SigningIdentityIdentifier,
        algorithm: SigningAlgorithm,
        input: SigningInput,
        context: SigningOperationContext? = nil
    ) {
        self.identityID = identityID
        self.algorithm = algorithm
        self.input = input
        self.context = context
    }

    /// Checks that the request describes a coherent operation.
    ///
    /// The rules:
    ///
    /// - the input must match the operation's declared input semantics:
    ///   message operations take a message, digest operations take a digest;
    /// - a digest must be one the operation actually works on. A digest of a
    ///   different algorithm is rejected, never re-hashed or substituted.
    ///
    /// - Throws: A typed `ZynSignError` with a crypto reason when the
    ///   request is not coherent.
    func validate() throws {
        switch (input, algorithm) {
        case (.message, let algorithm) where algorithm.digestLength == nil:
            break
        case (.digest, let algorithm) where algorithm.digestLength != nil:
            break
        default:
            throw ZynSignError.crypto(.invalidInput)
        }
        if case .digest(let digest) = input, digest.algorithm != algorithm.digestAlgorithm {
            throw ZynSignError.crypto(.invalidInput)
        }
    }
}
