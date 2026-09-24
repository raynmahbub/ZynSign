#if os(iOS)
import Foundation
import Security
import XCTest
@testable import ZynSign

/// Exports ZynSign-signed artifacts for the external validation harness
/// (`Tests/Host/external_validation.py`; see
/// `docs/architecture/external-validation.md`).
///
/// Opt-in: every test skips unless `ZYNSIGN_EXPORT_DIR` names a directory.
/// Under `xcodebuild` the variable is passed as
/// `TEST_RUNNER_ZYNSIGN_EXPORT_DIR`. The signatures are made by the
/// production signing use cases with a throwaway RSA-2048 key generated in
/// process and never serialized, and checked by the production
/// `AppleSignatureVerifier` — not by the replay capability and the
/// always-valid verifier the orchestration suites use. Only public material
/// is written: signed and unsigned artifacts, deliberately damaged copies,
/// the public certificate, and a manifest of ZynSign's own verdicts.
///
/// A signing refusal is recorded in the manifest as evidence rather than
/// failing the test; only a failure to write the export fails it. Nothing
/// here is a trust, platform-acceptance, or installability claim.
final class ExternalValidationExportTests: XCTestCase {

    private typealias PolicyFixtures = ProvisioningPolicyFixtures

    /// An instant inside the synthetic fixture profile's validity period.
    private static let insideValidity = Date(timeIntervalSince1970: 1_800_000_000)

    private var exportDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        let path = ProcessInfo.processInfo.environment["ZYNSIGN_EXPORT_DIR"] ?? ""
        guard !path.isEmpty else {
            throw XCTSkip(
                "Set ZYNSIGN_EXPORT_DIR (TEST_RUNNER_ZYNSIGN_EXPORT_DIR under xcodebuild) to export artifacts for external validation."
            )
        }
        exportDirectory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: exportDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        exportDirectory = nil
        super.tearDown()
    }

    // MARK: - Single images

    func testExportsSingleImageSignatures() throws {
        let identity = try ExternalValidationIdentity()
        let signer = SignMachOUseCase(
            identities: identity,
            digest: CryptoKitMessageDigest(),
            verifier: AppleSignatureVerifier()
        )
        try write(identity.certificate.derData, to: "single/certificate.der")
        try write(MachOSigningFixtures.unsignedMachO, to: "single/unsigned")

        let plain = try signingRequest(identity: identity.identityID)
        let entitlements = try CodeSigningEntitlements(values: [
            "application-identifier": .string("TESTTEAM.com.example.single"),
            "get-task-allow": .boolean(true),
        ])
        let withEntitlements = MachOSigningRequest(
            artifact: plain.artifact,
            identityID: plain.identityID,
            codeDirectory: plain.codeDirectory,
            algorithm: plain.algorithm,
            existingSignaturePolicy: plain.existingSignaturePolicy,
            policy: plain.policy,
            metadata: MachOSigningMetadata(entitlements: entitlements)
        )

        var artifacts: [ExportedArtifact] = []
        var mutations: [ExportedMutation] = []
        let variants: [(id: String, request: MachOSigningRequest, note: String)] = [
            (id: "single-plain", request: plain, note: "No signing metadata: the ZS-026 shape."),
            (id: "single-entitlements", request: withEntitlements,
             note: "XML entitlements metadata (special slot 5)."),
        ]
        for variant in variants {
            let exported = try exportSingleImage(
                id: variant.id,
                request: variant.request,
                signer: signer,
                certificate: identity.certificate,
                note: variant.note
            )
            artifacts.append(exported.artifact)
            mutations += exported.mutations
        }
        try writeManifest(
            ExportManifest(
                producer: "ExternalValidationExportTests.testExportsSingleImageSignatures",
                artifacts: artifacts,
                mutations: mutations
            ),
            to: "manifest-single.json"
        )
    }

    // MARK: - Application container

    func testExportsSignedApplicationContainer() async throws {
        let identity = try ExternalValidationIdentity()
        try write(identity.certificate.derData, to: "pipeline/certificate.der")
        let sourceFile = "pipeline/source-unsigned.ipa"
        try write(Data(ZipFixtureBuilder.archive(sourceEntries())), to: sourceFile)
        let signedFile = "pipeline/signed.ipa"

        let result = try await makePipeline(identity: identity).sign(SignApplicationRequest(
            sourceURL: exportDirectory.appendingPathComponent(sourceFile),
            profile: CMSFixtures.validRSASignedAttributes,
            identityID: identity.identityID,
            entitlements: try CodeSigningEntitlements(values: [:]),
            outputURL: exportDirectory.appendingPathComponent(signedFile),
            options: SignApplicationOptions(deviceContext: .identified(PolicyFixtures.deviceA))
        ))

        var artifact = ExportedArtifact(
            id: "pipeline-ipa",
            kind: "ipa",
            unsignedFile: sourceFile,
            certificateFile: "pipeline/certificate.der",
            identifier: PolicyFixtures.bundleIdentifier
        )
        artifact.bundlePath = "Payload/Synthetic.app"
        artifact.executable = "Synthetic"
        artifact.nestedBundles = ["Frameworks/Test.framework"]
        if result.status == .signed, let stages = result.stages {
            artifact.status = "signed"
            artifact.file = signedFile
            artifact.zynsignVerdict = stages.verification.passed ? "accepted" : "rejected"
            artifact.detail = "SignApplicationPipeline signed the container. Nested and main-executable "
                + "post-sign verification used AppleSignatureVerifier; stage 9 checked the "
                + "container against the run's own expectations."
            artifact.notes = [
                "nested targets signed: \(stages.nested.successfullySignedCount)",
                "sealed files: \(stages.sealing.sealedFileCount); nested seals: \(stages.sealing.nestedSealCount); omitted: \(stages.sealing.omittedCount)",
                "main-executable signature bytes: \(stages.mainExecutable.signatureByteCount)",
                "entitlements: the empty set the fixture profile's policy accepts",
            ]
        } else {
            artifact.status = "refused"
            artifact.zynsignVerdict = "refused"
            let stage = result.failure?.stage.rawValue ?? "unknown"
            artifact.detail = "SignApplicationPipeline refused at \(stage): \(result.failure?.detail ?? "no detail")"
        }
        try writeManifest(
            ExportManifest(
                producer: "ExternalValidationExportTests.testExportsSignedApplicationContainer",
                artifacts: [artifact],
                mutations: []
            ),
            to: "manifest-pipeline.json"
        )
    }

    // MARK: - Single-image helpers

    private func exportSingleImage(
        id: String,
        request: MachOSigningRequest,
        signer: SignMachOUseCase,
        certificate: Certificate,
        note: String
    ) throws -> (artifact: ExportedArtifact, mutations: [ExportedMutation]) {
        var artifact = ExportedArtifact(
            id: id,
            kind: "macho",
            unsignedFile: "single/unsigned",
            certificateFile: "single/certificate.der",
            identifier: request.codeDirectory.identifier.rawValue
        )
        artifact.teamIdentifier = request.codeDirectory.teamIdentifier?.rawValue
        artifact.codeLimit = request.codeDirectory.codeLimit
        artifact.notes = [note]
        let result: MachOSigningResult
        do {
            result = try signer.sign(request)
        } catch {
            artifact.status = "refused"
            artifact.zynsignVerdict = "refused"
            artifact.detail = "SignMachOUseCase refused: \(error)"
            return (artifact: artifact, mutations: [])
        }
        let file = "single/\(id)"
        try write(result.artifact, to: file)
        artifact.status = "signed"
        artifact.file = file
        artifact.signatureOffset = result.layout.offset
        artifact.codeDirectorySHA256 = Self.hex(result.codeDirectoryDigest.bytes)
        artifact.zynsignVerdict = "accepted"
        artifact.detail = "SignMachOUseCase post-sign verification passed with AppleSignatureVerifier."
        let mutations = try exportMutations(
            of: result.artifact,
            id: id,
            request: request,
            signer: signer,
            certificate: certificate
        )
        return (artifact: artifact, mutations: mutations)
    }

    /// Damaged copies of one signed image, each with ZynSign's own verdict.
    /// The harness asks `codesign` the same question about the same bytes.
    private func exportMutations(
        of signed: Data,
        id: String,
        request: MachOSigningRequest,
        signer: SignMachOUseCase,
        certificate: Certificate
    ) throws -> [ExportedMutation] {
        let image = try ReadOnlyMachOParser().parse(signed)
        guard case .thin(let slice) = image.container, let embedded = slice.embeddedSignature else {
            XCTFail("The signed artifact \(id) carries no embedded signature to damage.")
            return []
        }
        let entries = embedded.superBlob.entries
        var damages: [(name: String, description: String, bytes: Data)] = [
            (name: "code-byte", description: "One byte inside the signed code pages flipped.",
             bytes: Self.flipping(signed, at: 512)),
        ]
        if let directory = entries.first(where: { $0.slot == .codeDirectory }) {
            damages.append((name: "codedirectory-byte", description: "The CodeDirectory's last byte flipped.",
                            bytes: Self.flipping(signed, at: directory.fileRange.upperBound - 1)))
        }
        if let entitlementsEntry = entries.first(where: { $0.slot == .entitlements }) {
            damages.append((name: "entitlements-byte",
                            description: "One byte inside the embedded entitlements blob flipped.",
                            bytes: Self.flipping(signed, at: entitlementsEntry.fileRange.lowerBound + 20)))
        }
        if let cms = entries.first(where: { $0.slot == .cms }) {
            damages.append((name: "cms-signature-byte", description: "The CMS signature's last byte flipped.",
                            bytes: Self.flipping(signed, at: cms.fileRange.upperBound - 1)))
        }
        damages.append((name: "truncated", description: "The final 16 bytes removed.",
                        bytes: Data(signed.prefix(signed.count - 16))))

        var exported: [ExportedMutation] = []
        for damage in damages {
            let file = "single/mutations/\(id).\(damage.name)"
            try write(damage.bytes, to: file)
            var mutation = ExportedMutation(
                artifact: id,
                mutation: damage.name,
                file: file,
                description: damage.description
            )
            do {
                _ = try signer.verify(artifact: damage.bytes, request: request, certificate: certificate)
                mutation.zynsignVerdict = "accepted"
                mutation.zynsignDetail = "SignMachOUseCase.verify accepted the damaged artifact."
            } catch {
                mutation.zynsignVerdict = "rejected"
                mutation.zynsignDetail = "SignMachOUseCase.verify: \(error)"
            }
            exported.append(mutation)
        }
        return exported
    }

    // MARK: - Application-container helpers

    private func makePipeline(identity: ExternalValidationIdentity) -> SignApplicationPipeline {
        // The validation stages resolve the request's identity from their own
        // store, carrying the fixture profile's certificate fingerprint, as
        // the orchestration suite arranges it. Signing goes through the
        // throwaway identity and is verified by the production verifier.
        let validationIdentities = TestIdentityStore()
        let metadata = PolicyFixtures.identityMetadata(
            fingerprint: PolicyFixtures.fingerprint(CMSFixtures.signerCertificateFingerprint)
        )
        validationIdentities.identities = [
            SigningIdentity(
                id: identity.identityID,
                certificate: metadata.certificate,
                keyAvailability: metadata.keyAvailability,
                association: metadata.association,
                capabilityState: metadata.capabilityState
            ),
        ]
        return SignApplicationPipeline(
            identities: identity,
            digest: CryptoKitMessageDigest(),
            signatureVerifier: AppleSignatureVerifier(),
            profileValidation: ValidateProvisioningProfileUseCase(
                profileVerification: ProvisioningProfileVerificationUseCase(
                    cmsVerifier: ProvisioningProfileCMSVerifier(
                        certificateParser: AppleCertificateParser(),
                        signatureVerifier: RecordingCMSSignatureVerifier()
                    ),
                    inspection: ProvisioningProfileInspectionUseCase(
                        payloadDecoder: UnusedPayloadDecoder(),
                        parser: PropertyListProvisioningProfileParser(certificateParser: AppleCertificateParser()),
                        clock: FixedEvaluationClock(instant: Self.insideValidity)
                    ),
                    identityStore: validationIdentities
                ),
                configurationValidation: ValidateProvisioningConfigurationUseCase(
                    policyValidator: ProvisioningPolicyValidator(clock: FixedEvaluationClock(instant: Self.insideValidity)),
                    identityStore: validationIdentities
                )
            ),
            writer: ZipArchiveWriter()
        )
    }

    /// The nested-framework container of the orchestration suite, plus one
    /// plain resource so that tampering with a sealed resource can be tried.
    private func sourceEntries() -> [ZipFixtureBuilder.Entry] {
        [
            .directory("Payload"),
            .directory("Payload/Synthetic.app"),
            ZipFixtureBuilder.Entry(
                name: "Payload/Synthetic.app/Info.plist",
                content: Array(informationFile())
            ),
            ZipFixtureBuilder.Entry(
                name: "Payload/Synthetic.app/Synthetic",
                content: Array(MachOSigningFixtures.unsignedMachO),
                unixMode: 0o100_755
            ),
            ZipFixtureBuilder.Entry(
                name: "Payload/Synthetic.app/asset.dat",
                content: Array("ZynSign external validation resource\n".utf8)
            ),
            .directory("Payload/Synthetic.app/Frameworks"),
            .directory("Payload/Synthetic.app/Frameworks/Test.framework"),
            ZipFixtureBuilder.Entry(
                name: "Payload/Synthetic.app/Frameworks/Test.framework/Info.plist",
                content: Array(informationFile(
                    bundleIdentifier: "com.example.synthetic.nested",
                    executable: "Test"
                ))
            ),
            ZipFixtureBuilder.Entry(
                name: "Payload/Synthetic.app/Frameworks/Test.framework/Test",
                content: Array(MachOSigningFixtures.unsignedMachO),
                unixMode: 0o100_755
            ),
        ]
    }

    private func informationFile(
        bundleIdentifier: String = PolicyFixtures.bundleIdentifier,
        executable: String = "Synthetic"
    ) -> Data {
        Data(
            """
            <?xml version="1.0" encoding="UTF-8"?>
            <plist version="1.0"><dict>
              <key>CFBundleIdentifier</key><string>\(bundleIdentifier)</string>
              <key>CFBundleExecutable</key><string>\(executable)</string>
              <key>CFBundleShortVersionString</key><string>1.0</string>
              <key>CFBundleVersion</key><string>1</string>
              <key>MinimumOSVersion</key><string>17.0</string>
              <key>UIDeviceFamily</key><array><integer>1</integer></array>
            </dict></plist>
            """.utf8
        )
    }

    // MARK: - Writing

    private func write(_ data: Data, to relativePath: String) throws {
        let url = exportDirectory.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
    }

    private func writeManifest(_ manifest: ExportManifest, to relativePath: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try write(try encoder.encode(manifest), to: relativePath)
    }

    private static func flipping(_ data: Data, at index: Int) -> Data {
        var copy = Data(data)
        copy[index] ^= 0x01
        return copy
    }

    private static func hex(_ bytes: Data) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Manifest

/// What one export test produced. Read by `Tests/Host/external_validation.py`.
private struct ExportManifest: Encodable {
    var schema = 1
    var producer: String
    var artifacts: [ExportedArtifact]
    var mutations: [ExportedMutation]
}

/// One exported artifact and ZynSign's own verdict on it.
private struct ExportedArtifact: Encodable {
    var id: String
    var kind: String
    var unsignedFile: String
    var certificateFile: String
    var identifier: String
    var status: String = "refused"
    var file: String? = nil
    var teamIdentifier: String? = nil
    var codeLimit: UInt64? = nil
    var signatureOffset: Int? = nil
    var codeDirectorySHA256: String? = nil
    var zynsignVerdict: String = "refused"
    var detail: String = ""
    var bundlePath: String? = nil
    var executable: String? = nil
    var nestedBundles: [String]? = nil
    var notes: [String] = []
}

/// One deliberately damaged copy and ZynSign's own verdict on it.
private struct ExportedMutation: Encodable {
    var artifact: String
    var mutation: String
    var file: String
    var description: String
    var zynsignVerdict: String = "not-evaluated"
    var zynsignDetail: String = ""
}

// MARK: - Throwaway identity

/// A throwaway RSA-2048 signing identity. The key is generated in process,
/// never permanent, never exported, and discarded with the test; only the
/// public certificate leaves it. The self-signed certificate is shaped like
/// a code-signing leaf (v3, digital signature, code-signing extended key
/// usage, not a CA) so that external verifiers judge the signature rather
/// than the certificate's shape. It is untrusted by design.
private final class ExternalValidationIdentity: IdentityStore, SigningCapability {
    let identityID = SigningIdentityIdentifier()
    let certificate: Certificate
    let publicKeyAlgorithm: PublicKeyAlgorithm = .rsa
    let isAvailable = true
    let supportedAlgorithms: Set<SigningAlgorithm> = [.rsaPKCS1SHA256Digest]
    private let key: SecKey

    init() throws {
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: 2048,
            kSecAttrIsPermanent as String: false,
        ]
        let generatedKey = try XCTUnwrap(SecKeyCreateRandomKey(attributes as CFDictionary, nil))
        key = generatedKey
        let publicKey = try XCTUnwrap(SecKeyCopyPublicKey(generatedKey))
        // This is explicitly the public key, not the private signing handle.
        let publicBytes = try XCTUnwrap(SecKeyCopyExternalRepresentation(publicKey, nil) as Data?)
        let der = try Self.makeCertificateDER(signingKey: generatedKey, publicKey: publicBytes)
        certificate = Certificate(metadata: try AppleCertificateParser().parseCertificate(derData: der), derData: der)
    }

    func listIdentities() throws -> [SigningIdentity] { [] }
    func identity(withID id: SigningIdentityIdentifier) throws -> SigningIdentity? { nil }
    func signingCertificate(for id: SigningIdentityIdentifier) throws -> Certificate { certificate }
    func signingCapability(for id: SigningIdentityIdentifier) throws -> any SigningCapability { self }

    func sign(data: Data, algorithm: SigningAlgorithm) throws -> Data {
        try algorithm.validate(data: data, keyAlgorithm: .rsa)
        guard algorithm == .rsaPKCS1SHA256Digest,
              let signature = SecKeyCreateSignature(key, .rsaSignatureDigestPKCS1v15SHA256,
                                                    data as CFData, nil) as Data? else {
            throw ZynSignError.crypto(.signingFailure)
        }
        return signature
    }

    /// Issues the self-signed certificate. Test setup, before the measured
    /// signing use cases; neither trust nor suitability is asserted.
    private static func makeCertificateDER(signingKey: SecKey, publicKey: Data) throws -> Data {
        let rsaEncryption = Data([0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01])
        let sha256WithRSA = Data([0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x0B])
        let algorithm = der(0x30, sha256WithRSA + Data([0x05, 0x00]))
        let commonName = Data([0x06, 0x03, 0x55, 0x04, 0x03])
            + der(0x0C, Data("ZynSign External Validation".utf8))
        let name = der(0x30, der(0x31, der(0x30, commonName)))
        let now = Date()
        let notBefore = der(0x17, Data(utcTime(now.addingTimeInterval(-86_400)).utf8))
        let notAfter = der(0x17, Data(utcTime(now.addingTimeInterval(365 * 86_400)).utf8))
        let validity = der(0x30, notBefore + notAfter)
        let subjectPublicKeyInfo = der(0x30,
            der(0x30, rsaEncryption + Data([0x05, 0x00])) + der(0x03, Data([0x00]) + publicKey))
        let critical = Data([0x01, 0x01, 0xFF])
        let basicConstraints = der(0x30,
            Data([0x06, 0x03, 0x55, 0x1D, 0x13]) + critical + der(0x04, der(0x30, Data())))
        let keyUsage = der(0x30,
            Data([0x06, 0x03, 0x55, 0x1D, 0x0F]) + critical + der(0x04, Data([0x03, 0x02, 0x07, 0x80])))
        let codeSigning = Data([0x06, 0x08, 0x2B, 0x06, 0x01, 0x05, 0x05, 0x07, 0x03, 0x03])
        let extendedKeyUsage = der(0x30,
            Data([0x06, 0x03, 0x55, 0x1D, 0x25]) + critical + der(0x04, der(0x30, codeSigning)))
        let extensions = der(0xA3, der(0x30, basicConstraints + keyUsage + extendedKeyUsage))
        let version = der(0xA0, Data([0x02, 0x01, 0x02]))
        let serialNumber = Data([0x02, 0x01, 0x31])
        let body = version + serialNumber + algorithm + name + validity
        let tbs = der(0x30, body + name + subjectPublicKeyInfo + extensions)
        let signature = try XCTUnwrap(SecKeyCreateSignature(
            signingKey, .rsaSignatureMessagePKCS1v15SHA256, tbs as CFData, nil) as Data?)
        return der(0x30, tbs + algorithm + der(0x03, Data([0x00]) + signature))
    }

    private static func utcTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyMMddHHmmss'Z'"
        return formatter.string(from: date)
    }

    /// Tiny DER assembler for the test certificate; no production parsing.
    private static func der(_ tag: UInt8, _ content: Data) -> Data {
        precondition(content.count < 65536)
        let count = content.count
        let length: [UInt8]
        if count < 128 { length = [UInt8(count)] }
        else if count < 256 { length = [0x81, UInt8(count)] }
        else { length = [0x82, UInt8(count >> 8), UInt8(count & 255)] }
        return Data([tag] + length) + content
    }
}
#endif
