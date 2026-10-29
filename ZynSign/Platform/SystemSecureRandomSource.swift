import Foundation
import Security

/// Local-transfer constructors for `ZynSignError`.
///
/// The listener is the one part of a transfer session that depends on the
/// machine it runs on, so its failures are typed here rather than reduced to a
/// sentence in the platform adapter. None of them carries the session token,
/// a client address, or a received file name: the user message says what to
/// do, and the detail stays in diagnostics.
extension ZynSignError {

    /// The requested TCP port cannot be named as a port.
    static func localTransferPortUnavailable(port: UInt16) -> ZynSignError {
        ZynSignError(
            category: .invalidInput,
            userMessage: "Port \(port) is not a port this device can listen on.",
            diagnosticDetail: "NWEndpoint.Port(rawValue:) rejected \(port)."
        )
    }

    /// The listener could not be opened, or stopped before it was ready.
    ///
    /// The usual cause is another process holding the port or a network
    /// policy that refuses a listener; both are recoverable by choosing
    /// another port or trying again, so the message says that instead of
    /// naming a socket error.
    static func localTransferListenerFailed(
        diagnosticDetail: String? = nil,
        underlyingError: (any Error)? = nil
    ) -> ZynSignError {
        ZynSignError(
            category: .capabilityUnavailable,
            userMessage: "ZynSign could not start listening for local transfers. Another app may be using the port, or this network may refuse the connection.",
            diagnosticDetail: diagnosticDetail,
            underlyingError: underlyingError
        )
    }

    /// The device's secure random source did not produce session entropy.
    static func localTransferEntropyUnavailable(
        underlyingError: (any Error)? = nil
    ) -> ZynSignError {
        ZynSignError(
            category: .internalFailure,
            userMessage: "ZynSign could not create a session token, so nothing is listening.",
            diagnosticDetail: "SecRandomCopyBytes did not return unpredictable bytes.",
            underlyingError: underlyingError
        )
    }

    /// The transfer workspace could not be created or written.
    static func localTransferStorageFailure(
        diagnosticDetail: String? = nil,
        underlyingError: (any Error)? = nil
    ) -> ZynSignError {
        ZynSignError(
            category: .storageFailure,
            userMessage: "ZynSign could not store the received file.",
            diagnosticDetail: diagnosticDetail,
            underlyingError: underlyingError
        )
    }
}

/// Session entropy from the platform's secure random source.
///
/// `SecRandomCopyBytes` is the documented source of unpredictable bytes on
/// this platform. A failure is thrown, never replaced with a weaker value: a
/// predictable session token would make the listener reachable by anyone on
/// the network.
struct SystemSecureRandomSource: SecureRandomSource {

    init() {}

    func randomBytes(count: Int) throws -> Data {
        guard count > 0 else { return Data() }
        var bytes = [UInt8](repeating: 0, count: count)
        let status = bytes.withUnsafeMutableBytes { buffer -> Int32 in
            guard let base = buffer.baseAddress else { return errSecParam }
            return SecRandomCopyBytes(kSecRandomDefault, count, base)
        }
        guard status == errSecSuccess else {
            throw ZynSignError.localTransferEntropyUnavailable()
        }
        return Data(bytes)
    }
}
