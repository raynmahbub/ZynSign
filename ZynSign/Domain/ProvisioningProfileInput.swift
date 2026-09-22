import Foundation

/// Raw bytes presented for provisioning-profile inspection.
///
/// A profile normally arrives as a CMS-signed container, but this type does
/// not call the bytes a valid profile and does not retain a URL, file handle,
/// or platform object. The bytes are untrusted, are never executed, and are
/// bounded before a decoder is asked to process them.
///
/// This bound is ZynSign policy, not a published Apple limit. It prevents an
/// accidental or hostile caller from handing the profile pipeline an
/// unbounded buffer while leaving room for ordinary profiles and their
/// certificate material.
struct ProvisioningProfileInput: Equatable, Hashable {

    /// The maximum CMS/container input ZynSign will retain for inspection.
    static let maximumByteCount = 4 * 1_024 * 1_024

    /// The exact bytes presented by the caller.
    let bytes: Data

    /// Creates an untrusted input value. Size and structure are classified by
    /// the container decoder rather than by this value type, so tests and
    /// callers can observe the controlled failure for oversized input.
    init(bytes: Data) {
        self.bytes = bytes
    }
}

/// A decoded provisioning-profile payload at the CMS boundary.
///
/// `plistData` is the payload after container handling, not proof that a CMS
/// signature was checked. The decoder that produces this value may later be
/// extended to carry authenticated-container evidence; the metadata parser
/// itself remains independent of that evidence.
struct ProvisioningProfilePayload: Equatable, Hashable {

    /// The maximum property-list payload ZynSign will parse.
    static let maximumByteCount = 4 * 1_024 * 1_024

    /// The decoded property-list bytes.
    let plistData: Data

    /// The separate CMS/authenticity state carried across the parsing seam.
    let authenticity: ProvisioningProfileAuthenticityStatus

    /// Creates a decoded payload. This initializer does not claim that the
    /// containing CMS was authentic; the default state is deliberately
    /// `notEvaluated`.
    init(
        plistData: Data,
        authenticity: ProvisioningProfileAuthenticityStatus = .notEvaluated
    ) {
        self.plistData = plistData
        self.authenticity = authenticity
    }
}

/// Evidence about the profile container, kept separate from payload parsing.
///
/// ZS-017 produces and consumes only `.notEvaluated`. The other states are
/// reserved for a later CMS verification boundary and are present here so a
/// verified result can be attached without changing the profile model.
enum ProvisioningProfileAuthenticityStatus: String, CaseIterable, Equatable, Hashable {

    /// No CMS signature or certificate-chain evaluation has been performed.
    case notEvaluated

    /// A later CMS verifier established authenticity for the payload.
    case authenticated

    /// A later CMS verifier rejected the container.
    case rejected
}

/// The seam where CMS/container handling supplies a profile payload.
///
/// Implementations must treat `ProvisioningProfileInput` as hostile input,
/// enforce their own container/resource bounds, and return only decoded plist
/// bytes. This protocol does not authorize the payload, evaluate a signer
/// chain, or make platform-policy decisions.
protocol ProvisioningProfilePayloadDecoder {

    /// Decodes the payload from one untrusted profile container.
    ///
    /// - Throws: A controlled `ZynSignError` for empty, truncated, malformed,
    ///   unsupported, or unavailable container input. A successful return is
    ///   still only a decoded payload unless a later verifier explicitly
    ///   attaches authenticity evidence.
    func decodePayload(from input: ProvisioningProfileInput) throws -> ProvisioningProfilePayload
}
