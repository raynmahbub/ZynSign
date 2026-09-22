import XCTest
@testable import ZynSign

final class SigningIdentityStorageBoundaryTests: XCTestCase {
    func testRegistrySerializationIsAnExplicitNonSecretSchema() throws {
        let record = try SigningIdentityFixtures.record()
        let encoded = try record.encoded()
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["version", "identifier", "certificateDER", "certificateFingerprint", "keyReference"])
        XCTAssertEqual(object["certificateDER"] as? String, CertificateFixtures.validDER.base64EncodedString())
        XCTAssertEqual(object["keyReference"] as? String, SigningIdentityFixtures.reference.base64EncodedString())
        XCTAssertEqual(try StoredSigningIdentity.decode(encoded).id, try record.id)
    }

    func testMalformedOrFutureRecordsFailClosed() throws {
        let record = try SigningIdentityFixtures.record()
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: record.encoded()) as? [String: Any])
        for (field, value) in [("version", 2 as Any), ("identifier", "not-a-uuid" as Any),
                               ("keyReference", "" as Any), ("certificateFingerprint", "bad" as Any)] {
            var changed = object
            changed[field] = value
            let data = try JSONSerialization.data(withJSONObject: changed)
            XCTAssertThrowsError(try StoredSigningIdentity.decode(data)) { error in
                XCTAssertEqual((error as? ZynSignError)?.identityFailure, .malformedStoredIdentity)
            }
        }
        XCTAssertThrowsError(try StoredSigningIdentity.decode(Data(repeating: 0, count: StoredSigningIdentity.maximumEncodedByteCount + 1)))
    }

    func testWrongCertificateFingerprintFailsBeforeKeyResolution() throws {
        let registry = MemoryIdentityRegistry()
        let resolver = TestIdentityResolver()
        let record = StoredSigningIdentity(id: SigningIdentityIdentifier(), certificateDER: CertificateFixtures.ecDER,
            certificateFingerprint: CertificateFingerprint(hexDigest: CertificateFixtures.validFingerprintHex)!,
            keyReference: SigningIdentityFixtures.reference)
        registry.stored = [try record.encoded()]
        let store = SecureIdentityStore(registry: registry, resolver: resolver)
        XCTAssertThrowsError(try store.listIdentities()) { error in
            XCTAssertEqual((error as? ZynSignError)?.identityFailure, .malformedStoredIdentity)
        }
        XCTAssertEqual(resolver.resolutions, 0)
    }

    func testOversizedAndEmptyLocatorsAreRejectedBeforeResolution() throws {
        let registry = MemoryIdentityRegistry()
        let resolver = TestIdentityResolver()
        let store = SecureIdentityStore(registry: registry, resolver: resolver)
        for reference in [Data(), Data(repeating: 0, count: 4097)] {
            XCTAssertThrowsError(try store.register(certificateDER: CertificateFixtures.validDER, keyReference: reference))
        }
        XCTAssertEqual(resolver.resolutions, 0)
        XCTAssertTrue(registry.stored.isEmpty)
    }

    func testRegistryStoreAndCapabilityRenderingExcludeLocatorsAndCertificates() throws {
        let registry = MemoryIdentityRegistry()
        let resolver = TestIdentityResolver()
        let store = SecureIdentityStore(registry: registry, resolver: resolver)
        let id = try store.register(certificateDER: CertificateFixtures.validDER,
                                    keyReference: SigningIdentityFixtures.reference)
        let record = try XCTUnwrap(registry.records().first)
        let capability = try store.signingCapability(for: id)
        let objects: [Any] = [record, store, capability]
        for object in objects {
            let rendered = String(describing: object) + String(reflecting: object)
            XCTAssertTrue(rendered.contains("redacted"))
            XCTAssertFalse(rendered.contains("synthetic-key-locator"))
            XCTAssertFalse(rendered.contains(SigningIdentityFixtures.reference.base64EncodedString()))
            XCTAssertFalse(rendered.contains(CertificateFixtures.validDER.base64EncodedString()))
            XCTAssertTrue(Mirror(reflecting: object).children.isEmpty)
        }
    }

    func testMetadataContainsNoCapabilityLocatorOrRawBuffers() throws {
        let store = SecureIdentityStore(registry: MemoryIdentityRegistry(), resolver: TestIdentityResolver())
        let id = try store.register(certificateDER: CertificateFixtures.validDER,
                                    keyReference: SigningIdentityFixtures.reference)
        let metadata = try XCTUnwrap(store.metadata(for: id))
        func inspect(_ value: Any) {
            XCTAssertFalse(value is Data)
            XCTAssertFalse(value is any SigningCapability)
            for child in Mirror(reflecting: value).children {
                XCTAssertNotEqual(child.label, "keyReference")
                inspect(child.value)
            }
        }
        inspect(metadata)
        XCTAssertFalse(String(reflecting: metadata).contains("synthetic-key-locator"))
    }
}
