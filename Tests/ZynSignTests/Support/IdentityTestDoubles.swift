import Foundation
@testable import ZynSign

/// In-memory implementation of the identity annotation store for tests.
///
/// Mirrors the file-backed store's contract: fingerprints must be valid
/// SHA-256 hex digests, labels obey the length boundary, and marking a
/// default for an unannotated identity records an empty annotation.
final class MemoryIdentityAnnotationsStore: IdentityAnnotationsStore {

    private(set) var annotationsByFingerprint: [String: IdentityAnnotation] = [:]
    private(set) var defaultFingerprintValue: String?
    var failure: Error?

    func annotations() throws -> [String: IdentityAnnotation] {
        if let failure { throw failure }
        return annotationsByFingerprint
    }

    func setAnnotation(
        _ annotation: IdentityAnnotation,
        forFingerprint fingerprint: String
    ) throws {
        if let failure { throw failure }
        try Self.validateFingerprint(fingerprint)
        guard annotation.hasValidLabelLength else {
            throw ZynSignError.identityAnnotationsStorageFailure()
        }
        annotationsByFingerprint[fingerprint] = annotation
    }

    func removeAnnotation(forFingerprint fingerprint: String) throws {
        if let failure { throw failure }
        try Self.validateFingerprint(fingerprint)
        annotationsByFingerprint[fingerprint] = nil
    }

    func defaultIdentityFingerprint() throws -> String? {
        if let failure { throw failure }
        return defaultFingerprintValue
    }

    func setDefaultIdentityFingerprint(_ fingerprint: String?) throws {
        if let failure { throw failure }
        if let fingerprint {
            try Self.validateFingerprint(fingerprint)
            if annotationsByFingerprint[fingerprint] == nil {
                annotationsByFingerprint[fingerprint] = IdentityAnnotation()
            }
        }
        defaultFingerprintValue = fingerprint
    }

    private static func validateFingerprint(_ fingerprint: String) throws {
        guard CertificateFingerprint(hexDigest: fingerprint) != nil else {
            throw ZynSignError.identityAnnotationsStorageFailure()
        }
    }
}

/// A PKCS#12 importer double for model tests.
///
/// Records the password each import was given — the model tests use the
/// record to prove the password reached the importer exactly once and was
/// not retained by the model — then registers a queued certificate through
/// the real secure store, so the imported identity is indistinguishable
/// from one that arrived through Security.
final class RecordingPKCS12Importer: SigningIdentityImporter {

    private let store: SecureIdentityStore
    private var pending: [Data] = []

    private(set) var recordedPasswords: [String] = []
    private(set) var recordedData: [Data] = []

    /// A failure the next import should report.
    var failure: Error?

    init(store: SecureIdentityStore) {
        self.store = store
    }

    /// Queues the certificate the next import will register.
    func enqueue(certificateDER: Data) {
        pending.append(certificateDER)
    }

    @discardableResult
    func importPKCS12(data: Data, password: String) throws -> SigningIdentityIdentifier {
        recordedPasswords.append(password)
        recordedData.append(data)
        if let failure {
            throw failure
        }
        guard !pending.isEmpty else {
            throw ZynSignError.identity(.certificateUnavailable)
        }
        let der = pending.removeFirst()
        do {
            return try store.register(certificateDER: der, keyReference: SigningIdentityFixtures.reference)
        } catch {
            throw ZynSignError.sanitizedIdentityFailure(error)
        }
    }
}

/// Date helpers for tests that evaluate validity at exact instants.
enum TestClocks {
    /// Builds a UTC date from calendar components. Force-unwrapped: the
    /// components are always complete.
    static func utc(
        _ year: Int,
        _ month: Int,
        _ day: Int,
        hour: Int = 0,
        minute: Int = 0,
        second: Int = 0
    ) -> Date {
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = TimeZone(identifier: "UTC")
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second
        return components.date!
    }

    /// The instant the certificate manager model tests evaluate at:
    /// 2026-10-01, inside the valid and multi-attribute fixtures' periods,
    /// after the expired fixture's, and before the future fixture's.
    static let evaluationInstant = FixedEvaluationClock(
        instant: utc(2026, 10, 1)
    )
}
