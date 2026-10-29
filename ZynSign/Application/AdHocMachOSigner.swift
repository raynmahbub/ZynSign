import Foundation

/// Pure-Swift `CS_ADHOC` (`0x0000_0002`) Mach-O and `.app` bundle signer.
///
/// Produces structurally valid `LC_CODE_SIGNATURE` SuperBlobs containing a
/// SHA-256 `CodeDirectory` (with `CS_ADHOC` set and optional special slots for
/// `Info.plist`, `_CodeSignature/CodeResources`, and XML `Entitlements`) and no
/// detached CMS signature — used both by ZynSign's Host Container runtime and
/// by standalone ad-hoc `.ipa` exports.
struct AdHocMachOSigner: Sendable {

    struct SingleBinaryResult: Equatable, Sendable {
        let signedBytes: Data
        let codeDirectoryDigest: Digest
        let superBlobLength: Int
    }

    struct BundleSignReport: Equatable, Sendable {
        let mainCodeDirectoryDigest: Digest
        let signedNestedBinaryCount: Int
        let codeResourcesBytes: Int
    }

    private let digest: any MessageDigest
    private let writer = MachOCodeSignatureWriter()

    init(digest: any MessageDigest = CryptoKitMessageDigest()) {
        self.digest = digest
    }

    /// Signs one thin 64-bit `arm64` Mach-O (`MH_EXECUTE` or `MH_DYLIB`) with
    /// `CS_ADHOC`, stripping any prior signature first.
    func signMachO(
        _ rawInput: Data,
        identifier: String,
        hardenedRuntime: Bool = false,
        infoPlistData: Data? = nil,
        codeResourcesData: Data? = nil,
        entitlements: CodeSigningEntitlements? = nil
    ) throws -> SingleBinaryResult {
        let thinned = (try? GuestMachOPatcher.extractArm64Slice(rawInput)) ?? rawInput
        let stripped = MachOBinaryPatcher.stripCodeSignature(from: thinned) ?? thinned

        let cdIdentifier = try CodeDirectoryIdentifier(rawValue: identifier)
        let hashConfig = try CodeDirectoryHashConfiguration(hashType: .sha256)
        let policy = AdHocSignaturePolicy(hardenedRuntime: hardenedRuntime)

        var entitlementsBlob: EntitlementsBlob?
        if let entitlements, !entitlements.isEmpty {
            entitlementsBlob = try EntitlementsCanonicalSerializer().blob(entitlements)
        }

        let specialSlots = try buildSpecialSlots(
            infoPlistData: infoPlistData,
            codeResourcesData: codeResourcesData,
            entitlementsBlob: entitlementsBlob,
            hashSize: hashConfig.hashSize
        )

        let offsetPlan = try MachOCodeSignatureRegionLayout(
            appendingSerializedSuperBlobLength: 1,
            toFileLength: stripped.count
        )
        let codeLimit = UInt64(offsetPlan.offset)

        let cdRequest = CodeDirectoryConstructionRequest(
            version: .v20200,
            flags: policy.codeDirectoryFlags,
            identifier: cdIdentifier,
            teamIdentifier: nil,
            platform: 0,
            hashConfiguration: hashConfig,
            pageSize: .exponent(12),
            codeLimit: codeLimit,
            specialSlots: specialSlots
        )

        let plannedDirectoryLength = try computeDirectoryLength(cdRequest)
        var blobLengths = [plannedDirectoryLength]
        if let entitlementsBlob {
            blobLengths.append(entitlementsBlob.serializedLength)
        }
        let superLayout = try SuperBlobLayout(blobLengths: blobLengths)

        let prepared = try writer.prepare(
            stripped,
            serializedSuperBlobLength: superLayout.length,
            signedCodeLimit: codeLimit,
            existingSignaturePolicy: .rejectExistingSignature
        )

        let directory = try CodeDirectoryConstructor(messageDigest: digest)
            .construct(cdRequest, code: prepared.prefix)
        return try finalizeSuperBlob(directory: directory, entitlementsBlob: entitlementsBlob, prepared: prepared)
    }

    private func finalizeSuperBlob(
        directory: CodeDirectory,
        entitlementsBlob: EntitlementsBlob?,
        prepared: MachOCodeSignaturePreparation
    ) throws -> SingleBinaryResult {
        let directoryBlob = try CodeSignatureBlob.codeDirectory(directory)
        var entries: [CodeSignatureBlobEntry] = [
            try CodeSignatureBlobEntry(type: .codeDirectory, blob: directoryBlob)
        ]
        if let entitlementsBlob {
            entries.append(
                try CodeSignatureBlobEntry(type: .entitlements, blob: .entitlements(blob: entitlementsBlob))
            )
        }
        let serializedSuper = try SignatureSuperBlob(entries: entries).serialize()
        try serializedSuper.validate()
        let region = try MachOCodeSignatureRegion(serializedSuperBlob: serializedSuper)
        let finalized = try writer.finalize(prepared, region: region)
        let cdDigest = try digest.digest(directoryBlob.bytes, algorithm: .sha256)
        return SingleBinaryResult(
            signedBytes: finalized.bytes,
            codeDirectoryDigest: cdDigest,
            superBlobLength: serializedSuper.bytes.count
        )
    }

    /// Seals `_CodeSignature/CodeResources` and signs all nested dynamic
    /// libraries/frameworks plus the main executable inside `bundleURL` with `CS_ADHOC`.
    func signBundleDirectory(
        at bundleURL: URL,
        bundleIdentifier: String,
        executableName: String,
        entitlements: CodeSigningEntitlements? = nil
    ) throws -> BundleSignReport {
        let fm = FileManager.default
        var nestedCount = 0

        let subdirs = ["Frameworks", "Tweaks", "PlugIns"]
        for subdir in subdirs {
            let dirURL = bundleURL.appendingPathComponent(subdir, isDirectory: true)
            guard fm.fileExists(atPath: dirURL.path) else { continue }
            nestedCount += try signNestedBinaries(in: dirURL, parentIdentifier: bundleIdentifier)
        }

        let codeResourcesBytes = try generateAndWriteCodeResources(
            at: bundleURL,
            executableName: executableName
        )

        let infoPlistURL = bundleURL.appendingPathComponent("Info.plist", isDirectory: false)
        let infoPlistData = try? Data(contentsOf: infoPlistURL)

        let execURL = bundleURL.appendingPathComponent(executableName, isDirectory: false)
        let rawExec = try Data(contentsOf: execURL)
        let signedMain = try signMachO(
            rawExec,
            identifier: bundleIdentifier,
            infoPlistData: infoPlistData,
            codeResourcesData: codeResourcesBytes,
            entitlements: entitlements
        )
        try signedMain.signedBytes.write(to: execURL, options: .atomic)

        return BundleSignReport(
            mainCodeDirectoryDigest: signedMain.codeDirectoryDigest,
            signedNestedBinaryCount: nestedCount,
            codeResourcesBytes: codeResourcesBytes.count
        )
    }

    // MARK: - Helpers

    private func buildSpecialSlots(
        infoPlistData: Data?,
        codeResourcesData: Data?,
        entitlementsBlob: EntitlementsBlob?,
        hashSize: Int
    ) throws -> [CodeDirectorySpecialSlot] {
        let infoHash: Data? = try infoPlistData.map {
            Data(try digest.digest($0, algorithm: .sha256).bytes.prefix(hashSize))
        }
        let resourcesHash: Data? = try codeResourcesData.map {
            Data(try digest.digest($0, algorithm: .sha256).bytes.prefix(hashSize))
        }
        let entHash: Data? = try entitlementsBlob.map {
            Data(try digest.digest($0.bytes, algorithm: .sha256).bytes.prefix(hashSize))
        }
        if entHash != nil {
            return [
                CodeDirectorySpecialSlot(index: 1, hash: infoHash),
                CodeDirectorySpecialSlot(index: 2, hash: nil),
                CodeDirectorySpecialSlot(index: 3, hash: resourcesHash),
                CodeDirectorySpecialSlot(index: 4, hash: nil),
                CodeDirectorySpecialSlot(index: 5, hash: entHash)
            ]
        }
        if resourcesHash != nil {
            return [
                CodeDirectorySpecialSlot(index: 1, hash: infoHash),
                CodeDirectorySpecialSlot(index: 2, hash: nil),
                CodeDirectorySpecialSlot(index: 3, hash: resourcesHash)
            ]
        }
        if infoHash != nil {
            return [CodeDirectorySpecialSlot(index: 1, hash: infoHash)]
        }
        return []
    }

    private func computeDirectoryLength(_ request: CodeDirectoryConstructionRequest) throws -> Int {
        let slotCount = try CodeDirectory.expectedCodeSlotCount(
            codeLimit: request.codeLimit,
            pageSize: request.pageSize
        )
        let zeroSlots = (0..<slotCount).map {
            CodeDirectoryCodeSlot(index: $0, hash: Data(repeating: 0, count: request.hashConfiguration.hashSize))
        }
        let placeholder = try CodeDirectory(
            version: request.version,
            flags: request.flags,
            identifier: request.identifier,
            teamIdentifier: request.teamIdentifier,
            platform: request.platform,
            hashConfiguration: request.hashConfiguration,
            pageSize: request.pageSize,
            codeLimit: request.codeLimit,
            specialSlots: request.specialSlots,
            codeSlots: zeroSlots
        )
        return try CodeDirectorySerializer().makeLayout(for: placeholder).length
    }

    private func signNestedBinaries(in directoryURL: URL, parentIdentifier: String) throws -> Int {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: directoryURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }
        var count = 0
        for case let fileURL as URL in enumerator {
            guard (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                continue
            }
            let ext = fileURL.pathExtension.lowercased()
            let parentExt = fileURL.deletingLastPathComponent().pathExtension.lowercased()
            let isDylib = ext == "dylib"
            let isFrameworkExec = parentExt == "framework" && fileURL.lastPathComponent == fileURL.deletingLastPathComponent().deletingPathExtension().lastPathComponent
            guard isDylib || isFrameworkExec else { continue }
            guard let data = try? Data(contentsOf: fileURL),
                  GuestMachOPatcher.inspectCandidateBinary(data)?.hasArm64Slice == true else {
                continue
            }
            let itemID = "\(parentIdentifier).\(fileURL.deletingPathExtension().lastPathComponent)"
            if let signed = try? signMachO(data, identifier: itemID) {
                try signed.signedBytes.write(to: fileURL, options: .atomic)
                count += 1
            }
        }
        return count
    }

    private func generateAndWriteCodeResources(at bundleURL: URL, executableName: String) throws -> Data {
        let fm = FileManager.default
        var filesDict: [String: Data] = [:]
        var files2Dict: [String: [String: Data]] = [:]

        if let enumerator = fm.enumerator(
            at: bundleURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: []
        ) {
            let rootPrefix = bundleURL.standardizedFileURL.path + "/"
            for case let fileURL as URL in enumerator {
                guard (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                    continue
                }
                let fullPath = fileURL.standardizedFileURL.path
                guard fullPath.hasPrefix(rootPrefix) else { continue }
                let relPath = String(fullPath.dropFirst(rootPrefix.count))
                if relPath == executableName || relPath.hasPrefix("_CodeSignature/") || relPath == "CodeResources" {
                    continue
                }
                guard let content = try? Data(contentsOf: fileURL) else { continue }
                let sha1 = try digest.digest(content, algorithm: .sha1).bytes
                let sha256 = try digest.digest(content, algorithm: .sha256).bytes
                if relPath != "Info.plist" {
                    filesDict[relPath] = sha1
                }
                files2Dict[relPath] = ["hash": sha1, "hash2": sha256]
            }
        }

        let plistRoot: [String: Any] = [
            "files": filesDict,
            "files2": files2Dict,
            "rules": [
                "^.*": true,
                "^.*\\.lproj/": ["optional": true, "weight": 1000],
                "^.*\\.lproj/locversion.plist$": ["omit": true, "weight": 1100]
            ],
            "rules2": [
                "^.*": true,
                "^Info\\.plist$": ["omit": true, "weight": 20],
                "^embedded\\.mobileprovision$": ["weight": 20],
                "^.*\\.lproj/": ["optional": true, "weight": 1000]
            ]
        ]
        let serialized = try PropertyListSerialization.data(fromPropertyList: plistRoot, format: .xml, options: 0)
        let codeSigDir = bundleURL.appendingPathComponent("_CodeSignature", isDirectory: true)
        try fm.createDirectory(at: codeSigDir, withIntermediateDirectories: true)
        try serialized.write(to: codeSigDir.appendingPathComponent("CodeResources"), options: .atomic)
        return serialized
    }
}
