import Foundation

/// The boundary for importing a PKCS#12 identity into ZynSign's secure storage.
///
/// Import is an explicit user intent: the caller presents the raw PKCS#12 bytes
/// and the password the user entered. The importer validates the container,
/// extracts the identity's certificate and private-key reference, and records
/// the identity through the secure store without ever exposing key bytes.
///
/// The importer owns no long-lived state. It is constructed by the composition
/// root and surfaced through the application environment so the certificate
/// settings screen can import without constructing platform objects itself.
protocol SigningIdentityImporter {

    /// Imports the PKCS#12 container and registers the contained identity.
    ///
    /// - Parameters:
    ///   - data: The raw PKCS#12 bytes, as read from the selected file.
    ///   - password: The password the user entered. An empty string is a
    ///     valid password for an unencrypted container.
    /// - Returns: The identifier of the newly registered identity.
    /// - Throws: A typed `ZynSignError` when the container is empty,
    ///   malformed, the password is wrong, the key type is unsupported, or
    ///   the identity is already registered.
    @discardableResult
    func importPKCS12(data: Data, password: String) throws -> SigningIdentityIdentifier
}
