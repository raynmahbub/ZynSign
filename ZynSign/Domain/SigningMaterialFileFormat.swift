import Foundation

/// The file-type policy for signing-material imports.
///
/// The policy names the two files a signing identity needs — the PKCS#12
/// container that carries the certificate and its private key, and the
/// provisioning profile that authorises it — so every entry point agrees
/// on what certificate material is called. Like `IPAFileFormat`'s package
/// gate, the check is a cheap name policy that runs before any byte is
/// read; it decides where a file is *routed* — Certificates & Profiles
/// rather than the Import Hub — never whether its content is genuine. The
/// PKCS#12 reader and the profile parser decide that, about the bytes, in
/// their own precise words.
enum SigningMaterialFileFormat {

    /// What kind of signing material a file name claims to carry.
    enum Kind: Equatable, Hashable, Sendable {
        /// A PKCS#12 container (`.p12`, `.pfx`): a certificate with the
        /// private key that signs with it.
        case identity
        /// A provisioning profile (`.mobileprovision`, `.provisionprofile`).
        case profile
    }

    /// The extensions that name a PKCS#12 identity, lowercased.
    static let identityPathExtensions = ["p12", "pfx"]

    /// The extensions that name a provisioning profile, lowercased.
    static let profilePathExtensions = ["mobileprovision", "provisionprofile"]

    /// All accepted signing-material extensions, lowercased.
    static var acceptedPathExtensions: [String] {
        identityPathExtensions + profilePathExtensions
    }

    /// The kind of signing material a file-name extension claims, compared
    /// case-insensitively; `nil` for anything that is not signing material,
    /// including an empty extension.
    static func kind(forPathExtension candidate: String) -> Kind? {
        let candidate = candidate.lowercased()
        if identityPathExtensions.contains(candidate) { return .identity }
        if profilePathExtensions.contains(candidate) { return .profile }
        return nil
    }

    /// The kind of signing material a document URL claims, by its name
    /// alone. The name only chooses the destination; what the file holds
    /// is decided later, by the reader that opens it.
    static func kind(for source: URL) -> Kind? {
        kind(forPathExtension: source.pathExtension)
    }
}
