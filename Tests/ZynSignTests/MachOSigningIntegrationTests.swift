import Foundation
import XCTest
@testable import ZynSign

final class MachOSigningIntegrationTests: XCTestCase {
    private let digest = CryptoKitMessageDigest()

    func testCompletePipelineMatchesIndependentPublicVector() throws {
        let store = try MachOVectorIdentity()
        let request = try signingRequest(identity: store.id)
        let engine = useCase(store)
        let result = try engine.sign(request)
        XCTAssertEqual(store.calls, 1)
        XCTAssertEqual(store.lastInput, MachOSigningFixtures.signingDigest)
        XCTAssertEqual(result.artifact, MachOSigningFixtures.expectedSignedMachO)
        XCTAssertEqual(result.codeDirectory, MachOSigningFixtures.codeDirectory)
        XCTAssertEqual(result.cryptographicSignature, MachOSigningFixtures.signature)
        XCTAssertEqual(result.codeDirectoryDigest, try digest.digest(result.codeDirectory, algorithm: .sha256))
        XCTAssertEqual(result.layout.offset, 4144)
        XCTAssertEqual(result.layout.prefixPaddingLength, 13)
        XCTAssertEqual(result.layout.size, 1376)
        XCTAssertNotEqual(result.layout.offset, request.artifact.count)
        XCTAssertLessThan(result.layout.offset, result.artifact.count)
        let parsed = try ReadOnlyMachOParser().parse(result.artifact)
        let signature = try XCTUnwrap(parsed.slices.first?.embeddedSignature)
        XCTAssertEqual(signature.command.dataOffset, result.layout.offset)
        XCTAssertEqual(signature.command.dataSize, result.layout.size)
        XCTAssertEqual(signature.superBlob.entries.map(\.slot), [.codeDirectory, .cms])
        let cd = try XCTUnwrap(signature.superBlob.entries.first?.codeDirectory)
        XCTAssertEqual(cd.identifier, "com.example.single")
        XCTAssertEqual(cd.teamIdentifier, "TESTTEAM")
        XCTAssertEqual(cd.hashType, .sha256)
        XCTAssertEqual(cd.effectiveCodeLimit, 4144)
        XCTAssertEqual(cd.pageSizeExponent, 12)
        XCTAssertEqual(cd.codeHashes, try CodePageHasher(messageDigest: digest).hashCodePages(
            result.artifact, codeLimit: 4144, pageSize: .exponent(12),
            hashConfiguration: CodeDirectoryHashConfiguration(hashType: .sha256)).map(\.hash))
        XCTAssertNotEqual(cd.codeHashes.first, try digest.digest(Data(request.artifact.prefix(4096)), algorithm: .sha256).bytes)
        XCTAssertEqual(try engine.verify(artifact: result.artifact, request: request,
                                        certificate: store.certificate), result.codeDirectoryDigest)
        XCTAssertEqual(store.calls, 1) // Verification never signs.
    }

    func testCMSExactEncodingLengthAndIndependentDecoder() throws {
        let store = try MachOVectorIdentity()
        let cms = try DetachedCodeSignatureCMS(certificate: store.certificate)
        let content = try digest.digest(MachOSigningFixtures.codeDirectory, algorithm: .sha256)
        let encoded = try cms.encode(contentDigest: content.bytes, signature: MachOSigningFixtures.signature)
        XCTAssertEqual(encoded, MachOSigningFixtures.cms)
        XCTAssertEqual(try cms.plannedLength(), encoded.count)
        let parsed = try CMSStructureReader.read(encoded)
        XCTAssertNil(parsed.encapsulatedContent)
        XCTAssertEqual(parsed.certificateEncodings, [store.certificate.derData])
        let signer = try XCTUnwrap(parsed.signerInfos.first)
        let fields = try CertificateDERParser.signingFields(CertificateInput(bytes: store.certificate.derData))
        XCTAssertEqual(signer.issuerDER, fields.issuerDER)
        XCTAssertEqual(signer.signedAttributes?.messageDigest, content.bytes)
        XCTAssertEqual(try digest.digest(try XCTUnwrap(signer.signedAttributes?.verificationMessage), algorithm: .sha256).bytes,
                       MachOSigningFixtures.signingDigest)
        XCTAssertThrowsError(try cms.encode(contentDigest: Data(count: 31), signature: Data(count: 256)))
        XCTAssertThrowsError(try cms.encode(contentDigest: Data(count: 32), signature: Data(count: 255)))
    }

    func testDeterministicStructureAndDigestWithFixedRSAVector() throws {
        let store = try MachOVectorIdentity()
        let request = try signingRequest(identity: store.id)
        let first = try useCase(store).sign(request)
        let second = try useCase(store).sign(request)
        XCTAssertEqual(first.artifact, second.artifact)
        XCTAssertEqual(first.codeDirectoryDigest, second.codeDirectoryDigest)
        XCTAssertEqual(store.calls, 2) // One per request, never retries.
    }

    func testMissingIdentityFailsBeforeSigning() throws {
        let store = try MachOVectorIdentity()
        assertFailure(.identityUnavailable, store: store, request: try signingRequest(identity: nil))
    }

    func testUnsupportedAlgorithmFailsBeforeSigning() throws {
        let store = try MachOVectorIdentity()
        assertFailure(.unsupportedSigningAlgorithm, store: store,
                      request: try signingRequest(identity: store.id, algorithm: .ecdsaX962SHA256Digest))
    }

    func testUnsupportedHashFailsBeforeSigning() throws {
        let store = try MachOVectorIdentity()
        assertFailure(.unsupportedHashType, store: store,
                      request: try signingRequest(identity: store.id, hash: .sha384))
    }

    func testUnsupportedPageFlagsAndSpecialSlots() throws {
        let store = try MachOVectorIdentity()
        for request in [try signingRequest(identity: store.id, page: .unpaged),
                        try signingRequest(identity: store.id, flags: CodeDirectoryFlags(rawValue: 2)),
                        try signingRequest(identity: store.id, special: [CodeDirectorySpecialSlot(index: 1)])] {
            assertFailure(.unsupportedConfiguration, store: store, request: request)
        }
    }

    func testWrongCodeLimitFailsBeforeSigning() throws {
        let store = try MachOVectorIdentity()
        for limit: UInt64 in [0, 4131, 4143, 4145, 5520] {
            // Zero is rejected by the CodeDirectory model; all other mismatches
            // are rejected at the image/layout boundary.
            XCTAssertThrowsError(try useCase(store).sign(signingRequest(identity: store.id, limit: limit)))
        }
        XCTAssertEqual(store.calls, 0)
    }

    func testMalformedMachO() throws {
        let store = try MachOVectorIdentity()
        XCTAssertThrowsError(try useCase(store).sign(signingRequest(identity: store.id, artifact: Data([0, 1])))) {
            guard let error = $0 as? MachOSigningError,
                  case .invalidMachO = error else { return XCTFail("Wrong stage") }
        }
        XCTAssertEqual(store.calls, 0)
    }

    func testUniversalImageRejectedWithoutSigningASlice() throws {
        let store = try MachOVectorIdentity()
        let thin = MachOSigningFixtures.unsignedMachO
        var bytes = MachOFixtures.number(0xCAFEBABE, width: 4, order: .bigEndian)
        bytes += MachOFixtures.number(1, width: 4, order: .bigEndian)
        for value: UInt64 in [0x0100000C, 0, 4096, UInt64(thin.count), 12] {
            bytes += MachOFixtures.number(value, width: 4, order: .bigEndian)
        }
        bytes += Array(repeating: 0, count: 4096-bytes.count)
        bytes += thin
        assertFailure(.unsupportedMachOForm, store: store,
                      request: try signingRequest(identity: store.id, artifact: Data(bytes)))
    }

    func testDylibOtherCPUAndUnhandledLoadCommandRejected() throws {
        let store = try MachOVectorIdentity()
        var dylib = MachOSigningFixtures.unsignedMachO
        dylib[12] = 6
        assertFailure(.unsupportedMachOForm, store: store, request: try signingRequest(identity: store.id, artifact: dylib))
        var cpu = MachOSigningFixtures.unsignedMachO
        cpu[4] = 7
        assertFailure(.unsupportedMachOForm, store: store, request: try signingRequest(identity: store.id, artifact: cpu))
        var encrypted = Array(MachOSigningFixtures.unsignedMachO)
        MachOFixtures.put(3, at: 16, in: &encrypted, order: .littleEndian)
        MachOFixtures.put(248, at: 20, in: &encrypted, order: .littleEndian)
        encrypted.replaceSubrange(256..<280, with: MachOFixtures.command(0x2C, size: 24))
        assertFailure(.unsupportedMachOForm, store: store,
                      request: try signingRequest(identity: store.id, artifact: Data(encrypted)))
    }

    func testExistingSignatureAndExplicitReplacementRejected() throws {
        let store = try MachOVectorIdentity()
        assertFailure(.layout(.existingSignatureRejected), store: store,
                      request: try signingRequest(identity: store.id, artifact: MachOSigningFixtures.expectedSignedMachO))
        assertFailure(.layout(.replacementUnsupported), store: store,
                      request: try signingRequest(identity: store.id, existing: .replaceExistingSignature))
    }

    func testUnsafeHeaderPaddingRejectedBeforeSigning() throws {
        let store = try MachOVectorIdentity()
        var artifact = MachOSigningFixtures.unsignedMachO
        artifact[256] = 1
        assertFailure(.layout(.nonZeroLoadCommandPadding), store: store,
                      request: try signingRequest(identity: store.id, artifact: artifact))
    }

    func testUnavailableAndIncompatibleCapabilities() throws {
        let store = try MachOVectorIdentity()
        store.isAvailable = false
        assertFailure(.identityUnavailable, store: store, request: try signingRequest(identity: store.id))
        store.isAvailable = true
        store.publicKeyAlgorithm = .ec
        assertFailure(.unsupportedSigningAlgorithm, store: store, request: try signingRequest(identity: store.id))
    }

    func testSigningFailurePropagatesAtItsStage() throws {
        let store = try MachOVectorIdentity()
        store.failSigning = true
        XCTAssertThrowsError(try useCase(store).sign(signingRequest(identity: store.id))) {
            XCTAssertEqual($0 as? MachOSigningError, .signingCapabilityFailure)
        }
        XCTAssertEqual(store.calls, 1)
    }

    func testInvalidSignatureAndUnavailableVerifierReturnNoArtifact() throws {
        let store = try MachOVectorIdentity()
        store.signature[0] ^= 1
        XCTAssertThrowsError(try useCase(store).sign(signingRequest(identity: store.id))) {
            XCTAssertEqual($0 as? MachOSigningError, .postSignVerification)
        }
        store.signature = MachOSigningFixtures.signature
        let engine = SignMachOUseCase(identities: store, digest: digest,
                                     verifier: UnavailableCryptographicSignatureVerifier())
        XCTAssertThrowsError(try engine.sign(signingRequest(identity: store.id))) {
            XCTAssertEqual($0 as? MachOSigningError, .postSignVerification)
        }
    }

    func testWrongSignatureLengthIsNotRetried() throws {
        let store = try MachOVectorIdentity()
        store.signature = Data(count: 255)
        XCTAssertThrowsError(try useCase(store).sign(signingRequest(identity: store.id))) {
            XCTAssertEqual($0 as? MachOSigningError, .signatureBlobConstruction)
        }
        XCTAssertEqual(store.calls, 1)
    }

    func testTamperedHeaderCodeDirectoryCMSAndPaddingFailVerification() throws {
        let store = try MachOVectorIdentity()
        let request = try signingRequest(identity: store.id)
        let engine = useCase(store)
        // Header, code page, identifier, hash slot, CMS digest/signature, padding.
        for offset in [24, 512, 4144+28+52, 4144+28+80, 5450, 5509, 5519] {
            var changed = MachOSigningFixtures.expectedSignedMachO
            changed[offset] ^= 1
            XCTAssertThrowsError(try engine.verify(artifact: changed, request: request, certificate: store.certificate))
        }
        XCTAssertEqual(store.calls, 0)
    }

    func testPrepareFinalizePreservesPrefixAndRefusesSizeChanges() throws {
        let writer = MachOCodeSignatureWriter()
        let serialized = try SignatureSuperBlob(entries: []).serialize()
        let region = try MachOCodeSignatureRegion(serializedSuperBlob: serialized)
        let prepared = try writer.prepare(MachOSigningFixtures.unsignedMachO,
            serializedSuperBlobLength: serialized.bytes.count, signedCodeLimit: 4144,
            existingSignaturePolicy: .rejectExistingSignature)
        let output = try writer.finalize(prepared, region: region)
        XCTAssertEqual(Data(output.bytes.prefix(4144)), prepared.prefix)
        XCTAssertEqual(prepared.prefix.count, 4144)
        let wrong = try writer.prepare(MachOSigningFixtures.unsignedMachO,
            serializedSuperBlobLength: serialized.bytes.count + 1, signedCodeLimit: 4144,
            existingSignaturePolicy: .rejectExistingSignature)
        XCTAssertThrowsError(try writer.finalize(wrong, region: region))
    }

    func testMalformedAndIncompatibleCertificatesNeverSign() throws {
        let store = try MachOVectorIdentity()
        store.certificate = Certificate(metadata: store.certificate.metadata, derData: Data([0]))
        assertFailure(.certificateUnavailable, store: store, request: try signingRequest(identity: store.id))
        let ec = CertificateFixtures.ecDER
        store.certificate = Certificate(metadata: try AppleCertificateParser().parseCertificate(derData: ec), derData: ec)
        assertFailure(.unsupportedSigningAlgorithm, store: store, request: try signingRequest(identity: store.id))
    }

    func testNonZeroBasedDataAndOversizedRegionPlanFailClosed() throws {
        let store = try MachOVectorIdentity()
        var framed = Data([0])
        framed.append(MachOSigningFixtures.unsignedMachO)
        let slice = framed.dropFirst()
        XCTAssertEqual(slice.startIndex, 1)
        assertFailure(.unsupportedConfiguration, store: store,
                      request: try signingRequest(identity: store.id, artifact: slice))
        let writer = MachOCodeSignatureWriter()
        XCTAssertThrowsError(try writer.prepare(slice, serializedSuperBlobLength: 12,
            signedCodeLimit: 4144, existingSignaturePolicy: .rejectExistingSignature))
        XCTAssertThrowsError(try writer.prepare(MachOSigningFixtures.unsignedMachO,
            serializedSuperBlobLength: Int.max, signedCodeLimit: 4144,
            existingSignaturePolicy: .rejectExistingSignature)) {
            XCTAssertEqual($0 as? MachOCodeSignatureRegionError, .resourceLimitExceeded)
        }
    }

    func testSecureStoreProvidesOnlyPublicCertificateWithoutResolvingKey() throws {
        let registry = MemoryIdentityRegistry()
        let resolver = TestIdentityResolver()
        let record = try SigningIdentityFixtures.record()
        registry.stored = [try record.encoded()]
        let store = SecureIdentityStore(registry: registry, resolver: resolver)
        let certificate = try store.signingCertificate(for: record.id)
        XCTAssertEqual(certificate.derData, CertificateFixtures.validDER)
        XCTAssertEqual(certificate.fingerprint, certificate.metadata.sha256Fingerprint)
        XCTAssertEqual(resolver.resolutions, 0)
        XCTAssertTrue(resolver.signedInputs.isEmpty)
        XCTAssertThrowsError(try store.signingCertificate(for: SigningIdentityIdentifier()))
    }

    func testAmbiguousSectionMappingRelocationsAndVirtualRangesAreRejected() throws {
        let store = try MachOVectorIdentity()
        // Section VM address, relocation offset, flags, segment protection,
        // and linkedit VM address are checked before the capability is used.
        for offset in [136, 160, 168, 92, 208] {
            var artifact = MachOSigningFixtures.unsignedMachO
            artifact[offset] ^= 1
            assertFailure(.unsupportedMachOForm, store: store,
                          request: try signingRequest(identity: store.id, artifact: artifact))
        }
    }

    private func useCase(_ store: MachOVectorIdentity) -> SignMachOUseCase {
        SignMachOUseCase(identities: store, digest: digest, verifier: MachOVectorVerifier())
    }

    private func assertFailure(_ expected: MachOSigningError, store: MachOVectorIdentity,
                               request: MachOSigningRequest, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try useCase(store).sign(request), file: file, line: line) {
            XCTAssertEqual($0 as? MachOSigningError, expected, file: file, line: line)
        }
        XCTAssertEqual(store.calls, 0, file: file, line: line)
    }
}

func signingRequest(identity: SigningIdentityIdentifier?, artifact: Data = MachOSigningFixtures.unsignedMachO,
                    algorithm: SigningAlgorithm = .rsaPKCS1SHA256Digest,
                    hash: CodeDirectoryHashType = .sha256, page: CodeDirectoryPageSize = .exponent(12),
                    flags: CodeDirectoryFlags = [], special: [CodeDirectorySpecialSlot] = [],
                    limit: UInt64 = 4144,
                    existing: MachOExistingCodeSignaturePolicy = .rejectExistingSignature) throws -> MachOSigningRequest {
    MachOSigningRequest(artifact: artifact, identityID: identity,
        codeDirectory: CodeDirectoryConstructionRequest(version: .v20200, flags: flags,
            identifier: try CodeDirectoryIdentifier(rawValue: "com.example.single"),
            teamIdentifier: try CodeDirectoryTeamIdentifier(rawValue: "TESTTEAM"),
            hashConfiguration: try CodeDirectoryHashConfiguration(hashType: hash),
            pageSize: page, codeLimit: limit, specialSlots: special),
        algorithm: algorithm, existingSignaturePolicy: existing, policy: .singleImageCryptographicExperiment)
}

/// Replays only the exact independently signed test digest. No private key.
/// This tests orchestration, not a new implementation of RSA mathematics.
final class MachOVectorIdentity: IdentityStore, SigningCapability {
    let id = SigningIdentityIdentifier()
    var identityID: SigningIdentityIdentifier { id }
    var certificate: Certificate
    var publicKeyAlgorithm: PublicKeyAlgorithm = .rsa
    var isAvailable = true
    let supportedAlgorithms: Set<SigningAlgorithm> = [.rsaPKCS1SHA256Digest]
    var calls = 0
    var lastInput: Data?
    var failSigning = false
    var signature = MachOSigningFixtures.signature

    init() throws {
        let data = MachOSigningFixtures.certificateDER
        certificate = Certificate(metadata: try AppleCertificateParser().parseCertificate(derData: data), derData: data)
    }
    func listIdentities() throws -> [SigningIdentity] { [] }
    func identity(withID id: SigningIdentityIdentifier) throws -> SigningIdentity? { nil }
    func signingCertificate(for id: SigningIdentityIdentifier) throws -> Certificate { certificate }
    func signingCapability(for id: SigningIdentityIdentifier) throws -> any SigningCapability { self }
    func sign(data: Data, algorithm: SigningAlgorithm) throws -> Data {
        calls += 1
        lastInput = data
        guard !failSigning, algorithm == .rsaPKCS1SHA256Digest,
              data == MachOSigningFixtures.signingDigest else { throw ZynSignError.crypto(.signingFailure) }
        return signature
    }
}

struct MachOVectorVerifier: CryptographicSignatureVerifier {
    func verify(signature: Data, message: SigningInput, algorithm: SigningAlgorithm,
                certificate: Certificate) -> SignatureVerificationOutcome {
        guard case .message(let bytes) = message,
              algorithm == .rsaPKCS1SHA256Message,
              signature == MachOSigningFixtures.signature,
              certificate.derData == MachOSigningFixtures.certificateDER,
              let digest = try? CryptoKitMessageDigest().digest(bytes, algorithm: .sha256),
              digest.bytes == MachOSigningFixtures.signingDigest else { return .invalid }
        return .valid
    }
}
