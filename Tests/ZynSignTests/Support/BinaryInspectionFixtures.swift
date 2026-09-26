import Foundation
import CryptoKit
@testable import ZynSign

/// Synthetic, parser-valid signed Mach-O images for the Binary & Signature
/// Inspector tests.
///
/// Every image is assembled here from literal values: a 64-bit little-endian
/// header, `__TEXT` and `__LINKEDIT` segments, library, search-path, UUID,
/// build-version, encryption, and entry-point commands, deterministic code
/// bytes, and — when signed — an embedded signature: a version 0x20400
/// SHA-256 CodeDirectory over 4 KiB pages, an empty requirement set, an XML
/// entitlements blob, and an optional CMS blob. Every page hash and special
/// slot is a real SHA-256 computed here, so a test can verify an image end to
/// end and then change one byte. No real application, certificate, or key
/// appears anywhere. The layout was cross-checked against an independent
/// reader while this file was written.
enum BinaryInspectionFixtures {

    struct Library {
        let command: UInt32
        let installName: String
    }

    struct Options {
        var cpu: Int32 = MachOFixtures.arm64
        var cpuSubtype: Int32 = 0
        var fileType: UInt32 = 2
        var libraries: [Library] = [
            Library(command: 0xC, installName: "/System/Library/Frameworks/UIKit.framework/UIKit"),
            Library(command: 0xC, installName: "/System/Library/Frameworks/Foundation.framework/Foundation"),
            Library(command: 0x8000_0018, installName: "@rpath/Core.framework/Core"),
        ]
        var runPath: String? = "@executable_path/Frameworks"
        var cryptID: UInt32? = 0
        var codeByteCount = 6_000
        var signed = true
        var identifier = "com.example.synthetic"
        var teamIdentifier: String? = "TEAM123456"
        var codeDirectoryFlags: UInt32 = 0
        var specialSlotCount = 5
        var entitlements: [String: Any]? = [
            "application-identifier": "TEAM123456.com.example.synthetic",
            "com.apple.security.application-groups": ["group.secret-value"],
        ]
        var infoPlist: Data?
        var codeResources: Data?
        var cmsPayload: Data?
    }

    /// Where the parts of a built image are.
    struct Layout {
        let contentOffset: Int
        let signatureOffset: Int
        let codeSlotCount: Int
    }

    static let pageSize = 4_096

    static func binary(_ options: Options = Options()) -> Data {
        build(options).bytes
    }

    static func build(_ options: Options = Options()) -> (bytes: Data, layout: Layout) {
        var tail: [[UInt8]] = []
        for library in options.libraries {
            tail.append(dylibCommand(library.command, name: library.installName))
        }
        if let path = options.runPath {
            tail.append(stringCommand(0x8000_001C, value: path))
        }
        tail.append(uuidCommand())
        tail.append(buildVersionCommand())
        if let cryptID = options.cryptID {
            tail.append(encryptionCommand(cryptID: cryptID))
        }

        let hasMain = options.fileType == 2
        let segmentCount = options.signed ? 2 : 1
        var commandsSize = segmentCount * 72
        for command in tail { commandsSize += command.count }
        if hasMain { commandsSize += 24 }
        if options.signed { commandsSize += 16 }
        let contentOffset = 32 + commandsSize
        let codeEnd = contentOffset + options.codeByteCount
        let signatureOffset = align(codeEnd, 16)

        let requirements = blob(0xFADE_0C01, payload: [0, 0, 0, 0])
        let entitlementsBlob: [UInt8]? = options.entitlements.map { blob(0xFADE_7171, payload: xml($0)) }
        let cmsBlob: [UInt8]? = options.cmsPayload.map { blob(0xFADE_0B01, payload: [UInt8]($0)) }
        let specialCount = options.specialSlotCount
        let codeSlotCount = (signatureOffset + pageSize - 1) / pageSize
        let identifier = Array(options.identifier.utf8) + [0]
        let team: [UInt8] = options.teamIdentifier.map { Array($0.utf8) + [0] } ?? []
        let fixed = 88
        let hashOffset = fixed + identifier.count + team.count + specialCount * 32
        let directoryLength = hashOffset + codeSlotCount * 32
        var members: [(slot: UInt32, length: Int)] = [(slot: 0, length: directoryLength), (slot: 2, length: requirements.count)]
        if let entitlementsBlob { members.append((slot: 5, length: entitlementsBlob.count)) }
        if let cmsBlob { members.append((slot: 0x1_0000, length: cmsBlob.count)) }
        var superBlobLength = 12 + members.count * 8
        for member in members { superBlobLength += member.length }

        let commandCount = segmentCount + tail.count + (hasMain ? 1 : 0) + (options.signed ? 1 : 0)
        var writer = ByteWriter()
        writer.le32(0xFEED_FACF)
        writer.le32(UInt32(bitPattern: options.cpu))
        writer.le32(UInt32(bitPattern: options.cpuSubtype))
        writer.le32(options.fileType)
        writer.le32(UInt32(commandCount))
        writer.le32(UInt32(commandsSize))
        writer.le32(0x0020_0085)
        writer.le32(0)
        let textFileSize = options.signed ? signatureOffset : codeEnd
        let textVirtualSize = align(textFileSize, 0x4000)
        writer.append(segmentCommand(
            name: "__TEXT", address: 0x1_0000_0000, virtualSize: UInt64(textVirtualSize),
            fileOffset: 0, fileSize: UInt64(textFileSize), protection: 5
        ))
        if options.signed {
            writer.append(segmentCommand(
                name: "__LINKEDIT", address: 0x1_0000_0000 + UInt64(textVirtualSize),
                virtualSize: UInt64(align(superBlobLength, 0x4000)),
                fileOffset: UInt64(signatureOffset), fileSize: UInt64(superBlobLength), protection: 1
            ))
        }
        for command in tail { writer.append(command) }
        if hasMain { writer.append(mainCommand(entryOffset: UInt64(contentOffset))) }
        if options.signed {
            writer.append(codeSignatureCommand(offset: UInt32(signatureOffset), size: UInt32(superBlobLength)))
        }
        precondition(writer.count == contentOffset, "Fixture load commands do not match the planned layout.")
        writer.append(codeBytes(options.codeByteCount))
        let layout = Layout(contentOffset: contentOffset, signatureOffset: signatureOffset, codeSlotCount: codeSlotCount)
        guard options.signed else {
            return (Data(writer.bytes), layout)
        }
        writer.pad(to: signatureOffset)

        var codeHashes: [[UInt8]] = []
        for page in 0..<codeSlotCount {
            let start = page * pageSize
            let end = min(start + pageSize, signatureOffset)
            codeHashes.append(sha256(Array(writer.bytes[start..<end])))
        }
        let zero = [UInt8](repeating: 0, count: 32)
        var special: [Int: [UInt8]] = [:]
        special[1] = options.infoPlist.map { sha256([UInt8]($0)) } ?? zero
        special[2] = sha256(requirements)
        special[3] = options.codeResources.map { sha256([UInt8]($0)) } ?? zero
        special[4] = zero
        special[5] = entitlementsBlob.map { sha256($0) } ?? zero

        var directory = ByteWriter()
        directory.be32(0xFADE_0C02)
        directory.be32(UInt32(directoryLength))
        directory.be32(0x20400)
        directory.be32(options.codeDirectoryFlags)
        directory.be32(UInt32(hashOffset))
        directory.be32(UInt32(fixed))
        directory.be32(UInt32(specialCount))
        directory.be32(UInt32(codeSlotCount))
        directory.be32(UInt32(signatureOffset))
        directory.append([32, 2, 0, 12])
        directory.be32(0) // spare2
        directory.be32(0) // scatter offset
        directory.be32(team.isEmpty ? 0 : UInt32(fixed + identifier.count))
        directory.be32(0) // spare3
        directory.be64(0) // 64-bit code limit
        directory.be64(0) // executable segment base
        directory.be64(UInt64(textFileSize))
        directory.be64(1) // executable segment flags: main binary
        precondition(directory.count == fixed, "Fixture CodeDirectory header has the wrong length.")
        directory.append(identifier)
        directory.append(team)
        if specialCount > 0 {
            for slot in stride(from: specialCount, through: 1, by: -1) {
                directory.append(special[slot] ?? zero)
            }
        }
        for hash in codeHashes { directory.append(hash) }
        precondition(directory.count == directoryLength, "Fixture CodeDirectory has the wrong length.")

        var blobs: [UInt32: [UInt8]] = [0: directory.bytes, 2: requirements]
        if let entitlementsBlob { blobs[5] = entitlementsBlob }
        if let cmsBlob { blobs[0x1_0000] = cmsBlob }
        var superBlob = ByteWriter()
        superBlob.be32(0xFADE_0CC0)
        superBlob.be32(UInt32(superBlobLength))
        superBlob.be32(UInt32(members.count))
        var offset = 12 + members.count * 8
        for member in members {
            superBlob.be32(member.slot)
            superBlob.be32(UInt32(offset))
            offset += member.length
        }
        for member in members {
            superBlob.append(blobs[member.slot] ?? [])
        }
        precondition(superBlob.count == superBlobLength, "Fixture SuperBlob has the wrong length.")
        writer.append(superBlob.bytes)
        return (Data(writer.bytes), layout)
    }

    /// A universal image of the given slices, aligned to `2^alignmentExponent`.
    static func universal(_ slices: [Options], alignmentExponent: UInt32 = 12) -> Data {
        let members = slices.map { options -> (cpu: Int32, subtype: Int32, bytes: [UInt8]) in
            (cpu: options.cpu, subtype: options.cpuSubtype, bytes: [UInt8](binary(options)))
        }
        return Data(MachOFixtures.fat(members, alignmentExponent: alignmentExponent))
    }

    /// The same bytes with one byte inverted.
    static func flipping(_ data: Data, at offset: Int) -> Data {
        var bytes = [UInt8](data)
        bytes[offset] ^= 0xFF
        return Data(bytes)
    }

    static func propertyList(_ values: [String: Any]) -> Data {
        Data(xml(values))
    }

    static func sha256Data(_ data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }

    // MARK: - Commands

    private static func dylibCommand(_ command: UInt32, name: String) -> [UInt8] {
        let raw = Array(name.utf8) + [0]
        let size = align(24 + raw.count, 8)
        var writer = ByteWriter()
        writer.le32(command)
        writer.le32(UInt32(size))
        writer.le32(24)
        writer.le32(2)
        writer.le32(0x1_0000)
        writer.le32(0x1_0000)
        writer.append(raw)
        writer.pad(to: size)
        return writer.bytes
    }

    private static func stringCommand(_ command: UInt32, value: String) -> [UInt8] {
        let raw = Array(value.utf8) + [0]
        let size = align(12 + raw.count, 8)
        var writer = ByteWriter()
        writer.le32(command)
        writer.le32(UInt32(size))
        writer.le32(12)
        writer.append(raw)
        writer.pad(to: size)
        return writer.bytes
    }

    private static func uuidCommand() -> [UInt8] {
        var writer = ByteWriter()
        writer.le32(0x1B)
        writer.le32(24)
        writer.append((0x10...0x1F).map { UInt8($0) })
        return writer.bytes
    }

    private static func buildVersionCommand() -> [UInt8] {
        var writer = ByteWriter()
        writer.le32(0x32)
        writer.le32(32)
        writer.le32(2)            // iOS
        writer.le32(0x0011_0000)  // 17.0
        writer.le32(0x0012_0000)  // SDK 18.0
        writer.le32(1)            // one tool
        writer.le32(3)            // ld
        writer.le32(0x0400_0000)  // 1024.0
        return writer.bytes
    }

    private static func encryptionCommand(cryptID: UInt32) -> [UInt8] {
        var writer = ByteWriter()
        writer.le32(0x2C)
        writer.le32(24)
        writer.le32(0x4000)
        writer.le32(0x1000)
        writer.le32(cryptID)
        writer.le32(0)
        return writer.bytes
    }

    private static func mainCommand(entryOffset: UInt64) -> [UInt8] {
        var writer = ByteWriter()
        writer.le32(0x8000_0028)
        writer.le32(24)
        writer.le64(entryOffset)
        writer.le64(0)
        return writer.bytes
    }

    private static func codeSignatureCommand(offset: UInt32, size: UInt32) -> [UInt8] {
        var writer = ByteWriter()
        writer.le32(0x1D)
        writer.le32(16)
        writer.le32(offset)
        writer.le32(size)
        return writer.bytes
    }

    private static func segmentCommand(
        name: String,
        address: UInt64,
        virtualSize: UInt64,
        fileOffset: UInt64,
        fileSize: UInt64,
        protection: UInt32
    ) -> [UInt8] {
        var writer = ByteWriter()
        writer.le32(0x19)
        writer.le32(72)
        let nameBytes = Array(name.utf8.prefix(16))
        writer.append(nameBytes)
        writer.pad(to: 24)
        writer.le64(address)
        writer.le64(virtualSize)
        writer.le64(fileOffset)
        writer.le64(fileSize)
        writer.le32(protection)
        writer.le32(protection)
        writer.le32(0)
        writer.le32(0)
        return writer.bytes
    }

    // MARK: - Bytes

    private static func codeBytes(_ count: Int) -> [UInt8] {
        (0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) }
    }

    private static func blob(_ magic: UInt32, payload: [UInt8]) -> [UInt8] {
        var writer = ByteWriter()
        writer.be32(magic)
        writer.be32(UInt32(8 + payload.count))
        writer.append(payload)
        return writer.bytes
    }

    private static func xml(_ values: [String: Any]) -> [UInt8] {
        guard let data = try? PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0) else {
            preconditionFailure("A fixture property list could not be serialized.")
        }
        return [UInt8](data)
    }

    private static func sha256(_ bytes: [UInt8]) -> [UInt8] {
        Array(SHA256.hash(data: Data(bytes)))
    }

    private static func align(_ value: Int, _ alignment: Int) -> Int {
        (value + alignment - 1) / alignment * alignment
    }
}

/// An append-only byte buffer with explicit byte order.
struct ByteWriter {
    private(set) var bytes: [UInt8] = []

    var count: Int { bytes.count }

    mutating func le32(_ value: UInt32) {
        for shift in stride(from: 0, to: 32, by: 8) {
            bytes.append(UInt8(truncatingIfNeeded: value >> UInt32(shift)))
        }
    }

    mutating func le64(_ value: UInt64) {
        for shift in stride(from: 0, to: 64, by: 8) {
            bytes.append(UInt8(truncatingIfNeeded: value >> UInt64(shift)))
        }
    }

    mutating func be32(_ value: UInt32) {
        for shift in stride(from: 24, through: 0, by: -8) {
            bytes.append(UInt8(truncatingIfNeeded: value >> UInt32(shift)))
        }
    }

    mutating func be64(_ value: UInt64) {
        for shift in stride(from: 56, through: 0, by: -8) {
            bytes.append(UInt8(truncatingIfNeeded: value >> UInt64(shift)))
        }
    }

    mutating func append(_ other: [UInt8]) {
        bytes.append(contentsOf: other)
    }

    mutating func pad(to length: Int) {
        if bytes.count < length {
            bytes.append(contentsOf: [UInt8](repeating: 0, count: length - bytes.count))
        }
    }
}

// MARK: - CMS fixtures

/// Synthetic CMS messages in the shape a Mach-O code signature uses, generated
/// for this repository with a small DER builder and checked with
/// `openssl asn1parse`. The signature value is filler (`0x5A` bytes) and no
/// certificate is embedded: these messages exercise structure reading only.
enum CodeSignatureCMSFixtures {

    /// Signed attributes: content type, signing time `250301123000Z`, message
    /// digest `00 01 … 1F`, and Apple's code-directory hash attribute with two
    /// values (SHA-1 and SHA-256); one unsigned timestamp-token attribute.
    static let codeSignatureShape = decode(
        "MIICTQYJKoZIhvcNAQcCoIICPjCCAjoCAQExDTALBglghkgBZQMEAgEwCwYJKoZIhvcNAQcBMYICFzCCAhMCAQEwBTAAAgEFMAsGCWCGSAFlAwQCAaCBxjAYBgkqhkiG9w0BCQMxCwYJKoZIhvcNAQcBMBwGCSqGSIb3DQEJBTEPFw0yNTAzMDExMjMwMDBaMC8GCSqGSIb3DQEJBDEiBCAAAQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHzBbBgkqhkiG92NkCQIxTjAdBgUrDgMCGgQUAAAAAAAAAAAAAAAAAAAAAAAAAAAwLQYJYIZIAWUDBAIBBCAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAADANBgkqhkiG9w0BAQEFAASCAQBaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaoR4wHAYLKoZIhvcNAQkQAg4xDTALBgkqhkiG9w0BBwE="
    )

    /// The same message with a single-valued code-directory hash attribute, so
    /// the unsigned attribute is its only departure from the profile subset.
    static let unsignedAttributeOnly = decode(
        "MIICLgYJKoZIhvcNAQcCoIICHzCCAhsCAQExDTALBglghkgBZQMEAgEwCwYJKoZIhvcNAQcBMYIB+DCCAfQCAQEwBTAAAgEFMAsGCWCGSAFlAwQCAaCBpzAYBgkqhkiG9w0BCQMxCwYJKoZIhvcNAQcBMBwGCSqGSIb3DQEJBTEPFw0yNTAzMDExMjMwMDBaMC8GCSqGSIb3DQEJBDEiBCAAAQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHzA8BgkqhkiG92NkCQIxLzAtBglghkgBZQMEAgEEIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAMA0GCSqGSIb3DQEBAQUABIIBAFpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlqhHjAcBgsqhkiG9w0BCRACDjENMAsGCSqGSIb3DQEHAQ=="
    )

    /// A code-signature-shaped message whose message-digest attribute carries
    /// two values. A modeled attribute stays single-valued in every mode.
    static let multiValuedMessageDigest = decode(
        "MIICbwYJKoZIhvcNAQcCoIICYDCCAlwCAQExDTALBglghkgBZQMEAgEwCwYJKoZIhvcNAQcBMYICOTCCAjUCAQEwBTAAAgEFMAsGCWCGSAFlAwQCAaCB6DAYBgkqhkiG9w0BCQMxCwYJKoZIhvcNAQcBMBwGCSqGSIb3DQEJBTEPFw0yNTAzMDExMjMwMDBaMFEGCSqGSIb3DQEJBDFEBCAAAQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHwQgAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAwWwYJKoZIhvdjZAkCMU4wHQYFKw4DAhoEFAAAAAAAAAAAAAAAAAAAAAAAAAAAMC0GCWCGSAFlAwQCAQQgAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAwDQYJKoZIhvcNAQEBBQAEggEAWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWqEeMBwGCyqGSIb3DQEJEAIOMQ0wCwYJKoZIhvcNAQcB"
    )

    /// The signing time the fixtures declare: 2025-03-01 12:30:00 UTC.
    static let declaredSigningTime = Date(timeIntervalSince1970: 1_740_832_200)

    /// The message digest the fixtures declare.
    static let declaredMessageDigest = Data((0..<32).map { UInt8($0) })

    private static func decode(_ base64: String) -> Data {
        guard let data = Data(base64Encoded: base64) else {
            preconditionFailure("A CMS fixture could not be decoded.")
        }
        return data
    }
}

// MARK: - Doubles and helpers

/// A CMS mechanism double that returns a prepared assessment and records what
/// it was handed.
final class StubCodeSignatureCMSVerifier: CodeSignatureCMSVerifying {

    var assessment: CodeSignatureCMSAssessment = .unreadable("The stub was not configured.")
    private(set) var receivedPayloads: [Data] = []
    private(set) var receivedCodeDirectories: [[CodeSignatureCMSContent]] = []

    init(_ assessment: CodeSignatureCMSAssessment = .unreadable("The stub was not configured.")) {
        self.assessment = assessment
    }

    func assess(cmsPayload: Data, codeDirectories: [CodeSignatureCMSContent]) -> CodeSignatureCMSAssessment {
        receivedPayloads.append(cmsPayload)
        receivedCodeDirectories.append(codeDirectories)
        return assessment
    }
}

enum BinaryInspectionTestSupport {

    static let fixedDate = Date(timeIntervalSince1970: 1_800_000_000)

    static func bundlePath(_ raw: String) -> BundlePath {
        guard let path = BundlePath(rawValue: raw) else {
            preconditionFailure("Test fixture used an unsafe bundle path: \(raw)")
        }
        return path
    }

    static let mainTarget = BinaryTarget(
        kind: .mainExecutable,
        name: "Example",
        executablePath: bundlePath("Example"),
        containerPath: .root,
        declaredByteCount: nil
    )

    static func signer(commonName: String = "Apple Development: Example (TEAM123456)") -> CodeSignatureSignerSummary {
        CodeSignatureSignerSummary(
            commonName: commonName,
            organization: "Example",
            organizationalUnit: "TEAM123456",
            issuerCommonName: "Synthetic Intermediate",
            notValidBefore: Date(timeIntervalSince1970: 1_700_000_000),
            notValidAfter: Date(timeIntervalSince1970: 1_900_000_000),
            keyDescription: "RSA, 2048-bit"
        )
    }

    static func evaluated(
        binding: CMSSignatureBinding = .matches(codeDirectorySlot: 0),
        signature: CMSSignatureCheck = .verified,
        signerName: String = "Apple Development: Example (TEAM123456)"
    ) -> CodeSignatureCMSAssessment {
        .evaluated(CodeSignatureCMSEvaluation(
            signerCount: 1,
            certificateCount: 3,
            signer: signer(commonName: signerName),
            signerCertificateNote: nil,
            digestAlgorithmName: "SHA-256",
            signatureAlgorithmName: "RSA",
            binding: binding,
            signature: signature,
            declaredSigningTime: CodeSignatureCMSFixtures.declaredSigningTime,
            hasUnsignedAttributes: false
        ))
    }

    /// Inspects and verifies `bytes` with the production parser, decoder,
    /// summary, and verifier, the way the use case does for one target.
    static func report(
        for bytes: Data,
        target: BinaryTarget = mainTarget,
        resources: BinaryBoundResources = .notApplicable,
        cms: CodeSignatureCMSAssessment = .unreadable("No CMS mechanism in this test.")
    ) throws -> BinaryInspectionReport {
        let image = try ReadOnlyMachOParser().parse(bytes)
        let decoder = ReadOnlyMachOLoadCommandDecoder()
        let architectures = image.slices.enumerated().map { index, slice -> BinaryArchitectureReport in
            BinaryArchitectureReport(
                index: index,
                architecture: MachOArchitectureName(cpu: slice.header.cpu, cpuSubtype: slice.header.cpuSubtype),
                fileOffset: slice.fileRange.lowerBound,
                size: slice.fileRange.count,
                alignmentExponent: nil,
                fileKind: MachOFileKind(rawValue: slice.header.fileType),
                headerFlags: MachOHeaderFlagTable.decode(slice.header.flags),
                loadCommands: decoder.decodeLoadCommands(of: slice, in: bytes),
                signature: CodeSignatureSummary.make(slice: slice, bytes: bytes)
            )
        }
        var names: [Int: String] = [:]
        for architecture in architectures {
            names[architecture.index] = architecture.name
        }
        let verifier = BinarySignatureVerifier(
            digest: CryptoKitMessageDigest(),
            cmsVerifier: StubCodeSignatureCMSVerifier(cms),
            now: { fixedDate }
        )
        let integrity = try verifier.verify(
            image: image,
            bytes: bytes,
            context: BinaryVerificationContext(architectureNames: names, resources: resources, expectsEntitlements: true)
        )
        let container: BinaryContainerKind
        if case .universal(let universal) = image.container {
            container = .universal(architectureCount: universal.slices.count)
        } else {
            container = .thin
        }
        return BinaryInspectionReport(
            target: target,
            fileSize: bytes.count,
            container: container,
            architectures: architectures,
            inspectedAt: fixedDate,
            integrity: integrity
        )
    }
}
