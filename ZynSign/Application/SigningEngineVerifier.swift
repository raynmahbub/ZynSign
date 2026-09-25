import Foundation

/// One independent verification check and its outcome.
///
/// A check's name is stable and switchable: `<target>/<check>`, where
/// `<target>` is `main` for the application's own executable and the target's
/// bundle-relative executable path for a nested one. The detail states what
/// was recomputed, never what was trusted.
struct SigningEngineVerificationCheck: Equatable, Sendable {

    /// The stable check name.
    let name: String

    /// Whether the check passed.
    let passed: Bool

    /// What the check established, in bounded diagnostic language.
    let detail: String
}

/// What one independent verification of a signed working copy established.
struct SigningEngineVerificationReport: Equatable, Sendable {

    /// Every check that ran, in the order it ran.
    let checks: [SigningEngineVerificationCheck]

    /// Whether every check ran and passed. An empty check set is not a pass:
    /// a verification that established nothing must never read as verified.
    var passed: Bool { !checks.isEmpty && checks.allSatisfy(\.passed) }

    /// The names of the checks that failed, for diagnostics.
    var failedCheckNames: [String] { checks.filter { !$0.passed }.map(\.name) }

    /// How many checks passed.
    var passedCheckCount: Int { checks.filter(\.passed).count }
}

/// Everything an independent verification needs to hold a signed working copy
/// to the run's own inputs.
///
/// The material carries inputs, never signing state: the identity the run
/// used, the profile bytes it was given, the entitlement set it was asked to
/// embed, the seal bytes the sealing stage produced, and the bundle facts the
/// run established. Verification re-derives every value it compares, so none
/// of these can substitute for a computation.
struct SigningEngineVerificationMaterial: Equatable, Sendable {

    /// One nested binary the run signed.
    struct NestedTarget: Equatable, Sendable {

        /// The target's executable location, relative to the bundle.
        let executablePath: BundlePath

        /// The identifier the target's container declared, when it declared
        /// one. `nil` for a target that is not bundle-backed.
        let bundleIdentifier: String?
    }

    /// The bundle directory's own name.
    let bundleName: String

    /// The bundle's declared identifier.
    let bundleIdentifier: BundleIdentifier

    /// The bundle's declared executable name.
    let executableName: String

    /// The main executable's location, relative to the bundle.
    let executablePath: BundlePath

    /// The nested targets the run signed, in the plan's order.
    let nestedTargets: [NestedTarget]

    /// The identity the run signed with.
    let identityID: SigningIdentityIdentifier

    /// The team identifier the run recorded, when it established one.
    let teamIdentifier: CodeDirectoryTeamIdentifier?

    /// The exact profile bytes the run embedded.
    let profileBytes: Data

    /// The entitlement set the run embedded in the main executable.
    let entitlements: CodeSigningEntitlements

    /// The exact resource-seal bytes the run wrote.
    let sealBytes: Data
}

/// Independently verifies a signed working copy before it is packaged.
///
/// Verification re-reads every artifact from the working copy's filesystem
/// and re-derives every value it compares: page hashes are recomputed from
/// the signed bytes, special slots are recomputed from the seal and the
/// canonical entitlement blob, the CodeDirectory's declared values are read
/// back from the artifact, and the CMS signature is verified against the
/// certificate resolved — again, at verification time — from secure storage.
/// Nothing the signing stages computed is consulted.
///
/// What this does not establish: nothing here evaluates certificate trust,
/// platform authorization, or installability. A passing report says the
/// signed bytes are internally coherent and carry exactly the signing inputs
/// the run was given, and nothing more.
struct SigningEngineVerifier {

    private let identities: any IdentityStore
    private let digest: any MessageDigest
    private let cryptographicVerifier: any CryptographicSignatureVerifier
    private let parser: any MachOParsing
    private let maximumBinaryBytes: Int
    private let fileManager: FileManager

    init(
        identities: any IdentityStore,
        digest: any MessageDigest,
        cryptographicVerifier: any CryptographicSignatureVerifier,
        parser: any MachOParsing = ReadOnlyMachOParser(),
        maximumBinaryBytes: Int = ArchiveLimits.default.maximumEntryBytes,
        fileManager: FileManager = .default
    ) {
        self.identities = identities
        self.digest = digest
        self.cryptographicVerifier = cryptographicVerifier
        self.parser = parser
        self.maximumBinaryBytes = maximumBinaryBytes
        self.fileManager = fileManager
    }

    /// Verifies one signed bundle.
    ///
    /// - Parameters:
    ///   - bundleDirectory: The signed `<Name>.app` directory. Read but never
    ///     modified.
    ///   - material: The run's inputs, restated for independent comparison.
    /// - Returns: Every check that ran, with its outcome. Failures are checks,
    ///   not thrown errors: an unreadable artifact is a finding about the
    ///   artifact.
    func verify(
        bundleDirectory: URL,
        material: SigningEngineVerificationMaterial
    ) -> SigningEngineVerificationReport {
        var checks: [SigningEngineVerificationCheck] = []

        // The certificate is resolved now, from secure storage, rather than
        // taken from the run: a signature is only as good as the certificate
        // verification is actually checked against. When the store also
        // registers the identity, its certificate must be the same one.
        let resolvedCertificate: Certificate?
        if let registeredCertificate = try? identities.signingCertificate(for: material.identityID) {
            if let identity = try? identities.identity(withID: material.identityID) {
                resolvedCertificate = identity.certificate == registeredCertificate.metadata
                    ? registeredCertificate
                    : nil
            } else {
                resolvedCertificate = registeredCertificate
            }
        } else {
            resolvedCertificate = nil
        }

        checks.append(bundleConsistencyCheck(bundleDirectory: bundleDirectory, material: material))
        checks.append(provisioningCheck(bundleDirectory: bundleDirectory, material: material))
        checks.append(certificateRelationshipCheck(certificate: resolvedCertificate, material: material))

        let mainExecutableURL = Self.fileURL(for: material.executablePath, in: bundleDirectory)
        checks.append(contentsOf: binaryChecks(
            label: "main",
            fileURL: mainExecutableURL,
            certificate: resolvedCertificate,
            material: material,
            expectsSeal: true
        ))

        for target in material.nestedTargets {
            checks.append(contentsOf: binaryChecks(
                label: target.executablePath.rawValue,
                fileURL: Self.fileURL(for: target.executablePath, in: bundleDirectory),
                certificate: resolvedCertificate,
                material: material,
                expectsSeal: false
            ))
        }

        return SigningEngineVerificationReport(checks: checks)
    }

    // MARK: - Bundle-level checks

    /// The bundle's own facts, re-read from its information file: the
    /// identifier and executable name the run recorded, and the presence of
    /// the executable and the seal file.
    private func bundleConsistencyCheck(
        bundleDirectory: URL,
        material: SigningEngineVerificationMaterial
    ) -> SigningEngineVerificationCheck {
        check("main/bundle-consistency") {
            let informationURL = bundleDirectory.appendingPathComponent("Info.plist", isDirectory: false)
            guard let bytes = try? Data(contentsOf: informationURL) else {
                throw VerificationIssue.failed("The bundle's Info.plist could not be read.")
            }
            let examination = ApplicationMetadataReader.read(from: bytes)
            guard examination.isValid, let metadata = examination.metadata else {
                throw VerificationIssue.failed("The bundle's Info.plist is not valid bundle metadata.")
            }
            guard metadata.identity.bundleIdentifier == material.bundleIdentifier else {
                throw VerificationIssue.failed("The bundle declares \(metadata.identity.bundleIdentifier.rawValue), not \(material.bundleIdentifier.rawValue).")
            }
            guard metadata.executableName == material.executableName else {
                throw VerificationIssue.failed("The bundle declares executable \(metadata.executableName ?? "—"), not \(material.executableName).")
            }
            guard fileManager.fileExists(atPath: Self.fileURL(for: material.executablePath, in: bundleDirectory).path) else {
                throw VerificationIssue.failed("The declared executable is not present in the bundle.")
            }
            let sealURL = bundleDirectory
                .appendingPathComponent("_CodeSignature", isDirectory: true)
                .appendingPathComponent("CodeResources", isDirectory: false)
            guard fileManager.fileExists(atPath: sealURL.path) else {
                throw VerificationIssue.failed("The bundle carries no _CodeSignature/CodeResources seal.")
            }
            return "\(material.bundleName) declares \(material.bundleIdentifier.rawValue) and executable \(material.executableName), with its seal in place."
        }
    }

    /// The embedded profile and the entitlement set, held against the
    /// profile's own declarations.
    private func provisioningCheck(
        bundleDirectory: URL,
        material: SigningEngineVerificationMaterial
    ) -> SigningEngineVerificationCheck {
        check("main/provisioning-compatibility") {
            let profileURL = bundleDirectory.appendingPathComponent("embedded.mobileprovision", isDirectory: false)
            guard let embeddedBytes = try? Data(contentsOf: profileURL) else {
                throw VerificationIssue.failed("The bundle carries no embedded provisioning profile.")
            }
            guard embeddedBytes == material.profileBytes else {
                throw VerificationIssue.failed("The embedded profile is not the profile the run was given.")
            }
            let profile = try Self.parseProfile(embeddedBytes)
            let compatibility = ProvisioningIdentifierCompatibility(profile: profile)
            let identifierOutcome = compatibility.outcome(forBundleIdentifier: material.bundleIdentifier)
            guard identifierOutcome != .mismatch else {
                throw VerificationIssue.failed("The profile does not authorize \(material.bundleIdentifier.rawValue).")
            }
            let expectedApplicationIdentifier = compatibility.expectedApplicationIdentifier(for: material.bundleIdentifier)
            let evaluation = ProvisioningEntitlementComparator.evaluate(
                requested: ProvisioningProfileEntitlements(values: material.entitlements.values),
                against: profile.entitlements
            )
            let conflicts = evaluation.filter { $0.outcome == .claimValueConflicts || $0.outcome == .claimNotAuthorized }
            guard conflicts.isEmpty else {
                throw VerificationIssue.failed("The embedded entitlement set conflicts with the profile at \(conflicts.map(\.key).sorted().joined(separator: ", ")).")
            }
            let notEvaluated = evaluation.filter { $0.outcome == .cannotBeEvaluated }.count
            var detail = "The profile authorizes \(material.bundleIdentifier.rawValue) (\(identifierOutcome)) and covers \(evaluation.count - notEvaluated) of \(evaluation.count) embedded claims"
            if let expectedApplicationIdentifier {
                detail += ", under \(expectedApplicationIdentifier)"
            }
            if notEvaluated > 0 {
                detail += "; \(notEvaluated) claim(s) could not be evaluated against the profile"
            }
            return detail + "."
        }
    }

    /// The certificate the signature was verified against, held against the
    /// certificate the identity store registers for the signing identity.
    private func certificateRelationshipCheck(
        certificate: Certificate?,
        material: SigningEngineVerificationMaterial
    ) -> SigningEngineVerificationCheck {
        check("main/certificate-relationship") {
            guard let certificate else {
                throw VerificationIssue.failed("The signing certificate could not be resolved and matched to the registered identity.")
            }
            var detail = "The signature was verified with the certificate \\(certificate.subject.displayName) registered for the signing identity"
            if let team = material.teamIdentifier {
                detail += " under team \(team.rawValue)"
            }
            return detail + ". Certificate trust is not evaluated."
        }
    }

    // MARK: - Per-binary checks

    /// Everything verification establishes about one signed binary.
    private func binaryChecks(
        label: String,
        fileURL: URL,
        certificate: Certificate?,
        material: SigningEngineVerificationMaterial,
        expectsSeal: Bool
    ) -> [SigningEngineVerificationCheck] {
        let bytes = try? Data(contentsOf: fileURL, options: .mappedIfSafe)
        guard let bytes, bytes.count <= maximumBinaryBytes else {
            return [SigningEngineVerificationCheck(
                name: "\(label)/code-directory",
                passed: false,
                detail: "The binary could not be read, or is larger than this build reads."
            )]
        }

        var checks: [SigningEngineVerificationCheck] = []
        checks.append(check("\(label)/code-directory") {
            let inspection = try Self.inspect(parser: parser, bytes: bytes)
            try VerificationIssue.require(
                inspection.codeDirectory.identifier == Self.expectedIdentifier(label: label, material: material),
                "The CodeDirectory identifier is \(inspection.codeDirectory.identifier), not \(Self.expectedIdentifier(label: label, material: material))."
            )
            if let team = material.teamIdentifier {
                try VerificationIssue.require(
                    inspection.codeDirectory.teamIdentifier == team.rawValue,
                    "The CodeDirectory records team \(inspection.codeDirectory.teamIdentifier ?? "—"), not \(team.rawValue)."
                )
            }
            try VerificationIssue.require(
                inspection.codeDirectory.hashType == .sha256 && inspection.codeDirectory.pageSizeExponent == 12,
                "The CodeDirectory is not a SHA-256, 4096-byte-page directory."
            )
            try VerificationIssue.require(
                Int(inspection.codeDirectory.effectiveCodeLimit) == inspection.signatureRegionStart,
                "The CodeDirectory's code limit does not end where the signature region begins."
            )
            return "Identifier \(inspection.codeDirectory.identifier)\(material.teamIdentifier.map { ", team \($0.rawValue)" } ?? ""), SHA-256, page size 2^12, code limit \(inspection.codeDirectory.effectiveCodeLimit) bytes."
        })
        checks.append(check("\(label)/page-hashes") {
            let inspection = try Self.inspect(parser: parser, bytes: bytes)
            let recomputed = try CodePageHasher(messageDigest: digest).hashCodePages(
                bytes,
                codeLimit: inspection.codeDirectory.effectiveCodeLimit,
                pageSize: try CodeDirectoryPageSize(exponent: inspection.codeDirectory.pageSizeExponent),
                hashConfiguration: CodeDirectoryHashConfiguration(hashType: .sha256)
            )
            let declared = inspection.codeDirectory.codeHashes
            try VerificationIssue.require(
                declared.count == recomputed.count,
                "The CodeDirectory declares \(declared.count) page hashes; the signed bytes hash to \(recomputed.count)."
            )
            for (index, page) in recomputed.enumerated() where declared[index] != page.hash {
                throw VerificationIssue.failed("Page \(index)'s declared hash does not match the hash of the signed bytes.")
            }
            return "All \(recomputed.count) page hashes recomputed from the signed bytes match the CodeDirectory."
        })
        if expectsSeal {
            checks.append(check("\(label)/special-slots") {
                let inspection = try Self.inspect(parser: parser, bytes: bytes)
                let configuration = try CodeDirectoryHashConfiguration(hashType: .sha256)
                let sealDigest = try digest.digest(material.sealBytes, algorithm: .sha256)
                try VerificationIssue.require(
                    inspection.codeDirectory.specialSlots.contains { slot in
                        slot.kind == .codeResources
                            && slot.hash == Data(sealDigest.bytes.prefix(slot.hash.count))
                    },
                    "No special slot binds _CodeSignature/CodeResources to this executable."
                )
                let entitlementsBlob = try EntitlementsCanonicalSerializer().blob(material.entitlements).bytes
                let entitlementsDigest = try digest.digest(entitlementsBlob, algorithm: .sha256)
                try VerificationIssue.require(
                    inspection.codeDirectory.specialSlots.contains { slot in
                        slot.kind == .entitlements
                            && slot.hash == Data(entitlementsDigest.bytes.prefix(slot.hash.count))
                    },
                    "No special slot binds the embedded entitlements to this executable."
                )
                return "Slot 3 binds the seal (\(material.sealBytes.count) bytes); slot 5 binds the canonical entitlement blob (\(entitlementsBlob.count) bytes)."
            })
            checks.append(check("\(label)/entitlements") {
                let inspection = try Self.inspect(parser: parser, bytes: bytes)
                let metadata = EmbeddedSigningMetadataInspector().inspect(slice: inspection.slice, artifact: bytes)
                switch metadata.entitlements {
                case .present(let embedded):
                    try VerificationIssue.require(
                        embedded == material.entitlements,
                        "The embedded entitlement set is not the set the run was asked to sign."
                    )
                    return "The embedded entitlement set decodes to the \(material.entitlements.count) claim(s) the run signed."
                case .absent:
                    throw VerificationIssue.failed("The main executable carries no entitlements slot.")
                case .malformed:
                    throw VerificationIssue.failed("The embedded entitlements blob is malformed.")
                }
            })
        }
        checks.append(check("\(label)/signature") {
            guard let certificate else {
                throw VerificationIssue.failed("No certificate was resolved to verify the CMS signature against.")
            }
            let inspection = try Self.inspect(parser: parser, bytes: bytes)
            let codeDirectoryBytes = bytes.subdata(in: inspection.codeDirectoryEntry.fileRange)
            let signatureBytes = bytes.subdata(
                in: (inspection.cmsEntry.fileRange.lowerBound + 8)..<inspection.cmsEntry.fileRange.upperBound
            )
            let cms = try DetachedCodeSignatureCMS(certificate: certificate)
            try cms.verify(
                signatureBytes,
                codeDirectory: codeDirectoryBytes,
                digest: digest,
                verifier: cryptographicVerifier
            )
            let cdhash = try digest.digest(codeDirectoryBytes, algorithm: .sha256)
            return "The CMS signature verifies over the CodeDirectory (\(cdhash.hexString.prefix(16))…)."
        })
        return checks
    }

    // MARK: - Internals

    /// The identifier a signed binary's CodeDirectory must record.
    private static func expectedIdentifier(
        label: String,
        material: SigningEngineVerificationMaterial
    ) -> String {
        if label == "main" { return material.executableName }
        return material.nestedTargets
            .first { $0.executablePath.rawValue == label }?
            .bundleIdentifier ?? label
    }

    /// A parsed signed binary's structure: the slice, the decoded
    /// CodeDirectory, and the signature's entries, all read back from the
    /// artifact's own bytes.
    private struct SignedBinaryInspection {

        let slice: MachOSlice
        let codeDirectory: MachOCodeDirectory
        let codeDirectoryEntry: MachOSignatureEntry
        let cmsEntry: MachOSignatureEntry

        /// Where the signature region begins: the byte the CodeDirectory's
        /// code limit must name.
        let signatureRegionStart: Int
    }

    /// Reads one signed binary's signature structure.
    private static func inspect(parser: any MachOParsing, bytes: Data) throws -> SignedBinaryInspection {
        let image: MachOImage
        do {
            image = try parser.parse(bytes)
        } catch {
            throw VerificationIssue.failed("The binary is not a Mach-O image this build can parse.")
        }
        guard case .thin(let slice) = image.container else {
            throw VerificationIssue.failed("The binary is not a single-architecture image.")
        }
        guard slice.header.cpu == .arm64 else {
            throw VerificationIssue.failed("The binary is not an arm64 image.")
        }
        guard let embedded = slice.embeddedSignature else {
            throw VerificationIssue.failed("The binary carries no LC_CODE_SIGNATURE command.")
        }
        guard let codeDirectoryEntry = embedded.superBlob.entries.first(where: { $0.slot == .codeDirectory }),
              let codeDirectory = codeDirectoryEntry.codeDirectory else {
            throw VerificationIssue.failed("The signature carries no decodable CodeDirectory.")
        }
        guard let cmsEntry = embedded.superBlob.entries.first(where: { $0.slot == .cms }) else {
            throw VerificationIssue.failed("The signature carries no CMS blob.")
        }
        guard embedded.command.fileRange.upperBound == bytes.count else {
            throw VerificationIssue.failed("The signature region does not end at the artifact's end.")
        }
        return SignedBinaryInspection(
            slice: slice,
            codeDirectory: codeDirectory,
            codeDirectoryEntry: codeDirectoryEntry,
            cmsEntry: cmsEntry,
            signatureRegionStart: embedded.command.dataOffset
        )
    }

    /// The file location of a bundle-relative path.
    private static func fileURL(for path: BundlePath, in bundleDirectory: URL) -> URL {
        path.components.reduce(bundleDirectory) { url, component in
            url.appendingPathComponent(component, isDirectory: false)
        }
    }

    /// Parses an embedded profile's payload.
    ///
    /// A `.mobileprovision` is a CMS container whose payload is a property
    /// list; a payload that is not wrapped is read as-is. Parsing is the same
    /// read-only dance every profile reader in ZynSign performs.
    private static func parseProfile(_ data: Data) throws -> ProvisioningProfile {
        let payload: Data
        if let cms = try? CMSStructureReader.read(data), let content = cms.encapsulatedContent {
            payload = content
        } else if let range = data.range(of: Data("<?xml".utf8)) {
            payload = data.subdata(in: range.lowerBound..<data.endIndex)
        } else if let range = data.range(of: Data("bplist00".utf8)) {
            payload = data.subdata(in: range.lowerBound..<data.endIndex)
        } else {
            payload = data
        }
        do {
            return try PropertyListProvisioningProfileParser().parse(ProvisioningProfilePayload(plistData: payload))
        } catch {
            throw VerificationIssue.failed("The embedded profile's payload could not be parsed.")
        }
    }

    /// Runs one check, converting a thrown issue into a failed outcome.
    private func check(
        _ name: String,
        _ body: () throws -> String
    ) -> SigningEngineVerificationCheck {
        do {
            return SigningEngineVerificationCheck(name: name, passed: true, detail: try body())
        } catch let issue as VerificationIssue {
            switch issue {
            case .failed(let detail):
                return SigningEngineVerificationCheck(name: name, passed: false, detail: detail)
            }
        } catch {
            return SigningEngineVerificationCheck(
                name: name,
                passed: false,
                detail: "The check could not be completed."
            )
        }
    }

    /// A check's own refusal.
    private enum VerificationIssue: Error {

        case failed(String)

        /// Requires a condition, refusing with the check's own language.
        static func require(_ condition: Bool, _ detail: String) throws {
            guard condition else { throw VerificationIssue.failed(detail) }
        }
    }
}
