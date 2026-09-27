import Foundation

// MARK: - Synthetic images

/// Hand-assembled Mach-O bytes for the Lab's synthetic packages.
///
/// These are structural images, not signed binaries: a 64-bit little-endian
/// thin header for `arm64`, optionally carrying one code-signature load
/// command and the bytes it points at. They exist so the production parser,
/// the nested-code discovery rules and the plan validator see the shape of a
/// real executable without a real application, a real key, or a byte copied
/// from anywhere outside this file.
///
/// Nothing here is a signature. Where a signature region is present it holds
/// a SuperBlob header ZynSign writes itself, and the Lab never claims it is
/// valid — the check reports the state the production inspector establishes.
enum LabMachOImage {

    /// `MH_EXECUTE`.
    static let executeFileType: UInt32 = 2

    /// `MH_DYLIB`.
    static let dynamicLibraryFileType: UInt32 = 6

    /// `LC_CODE_SIGNATURE`.
    private static let codeSignatureCommand: UInt32 = 0x1D

    /// `CSMAGIC_EMBEDDED_SIGNATURE`, the SuperBlob magic a signature region
    /// begins with.
    private static let embeddedSignatureMagic: UInt32 = 0xFADE_0CC0

    /// Builds a thin `arm64` image.
    ///
    /// - Parameters:
    ///   - fileType: The Mach-O file type to declare.
    ///   - signature: The bytes of a code-signature region to append, or
    ///     `nil` for an image with no signature command at all.
    static func thinARM64(fileType: UInt32, signature: Data? = nil) -> Data {
        let headerSize = 32
        let commandSize = 16
        let commandsSize = signature == nil ? 0 : commandSize
        let commandCount = signature == nil ? 0 : 1
        let signatureLength = signature?.count ?? 0
        let signatureOffset = signature == nil ? 0 : headerSize + commandsSize

        var bytes = [UInt8](repeating: 0, count: headerSize + commandsSize)
        put(0xFEED_FACF, at: 0, into: &bytes)                    // magic, 64-bit little-endian
        put(0x0100_000C, at: 4, into: &bytes)                    // CPU_TYPE_ARM64
        put(0, at: 8, into: &bytes)                              // CPU_SUBTYPE_ARM64_ALL
        put(fileType, at: 12, into: &bytes)
        put(UInt32(commandCount), at: 16, into: &bytes)
        put(UInt32(commandsSize), at: 20, into: &bytes)
        put(0, at: 24, into: &bytes)                             // flags
        put(0, at: 28, into: &bytes)                             // reserved

        if signature != nil {
            put(codeSignatureCommand, at: headerSize, into: &bytes)
            put(UInt32(commandSize), at: headerSize + 4, into: &bytes)
            put(UInt32(signatureOffset), at: headerSize + 8, into: &bytes)
            put(UInt32(signatureLength), at: headerSize + 12, into: &bytes)
        }
        if let signature {
            bytes.append(contentsOf: signature)
        }
        return Data(bytes)
    }

    /// A minimal, structurally well-formed embedded-signature SuperBlob:
    /// a magic, a length, and no entries.
    ///
    /// The Lab uses it so the parser's signature region is present and
    /// measurable. It carries no CodeDirectory, no hash and no CMS blob, and
    /// the check reports whatever state the production inspector records.
    static var emptyEmbeddedSignature: Data {
        var bytes = [UInt8](repeating: 0, count: 8)
        put(embeddedSignatureMagic, at: 0, into: &bytes)
        put(8, at: 4, into: &bytes)
        return Data(bytes)
    }

    private static func put(_ value: UInt32, at offset: Int, into bytes: inout [UInt8]) {
        for index in 0..<4 {
            bytes[offset + index] = UInt8(truncatingIfNeeded: value >> (index * 8))
        }
    }
}

// MARK: - Synthetic packages

/// One synthetic application package the Lab builds.
///
/// A `LabPackage` is a declaration, not a file: the entries ZynSign would
/// read from a real container, the identity the bundle declares, and the
/// nested-code locations the fixture put inside it. The Lab serializes it
/// with the production writer, so the bytes a scenario reads were produced
/// by the same code path that produces a signed package.
struct LabPackage: Equatable, Sendable {

    /// The entries, in the order they were built.
    let entries: [ArchiveWriteEntry]

    /// The application bundle's directory name (`Example.app`).
    let bundleName: String

    /// The bundle identifier the information file declares.
    let bundleIdentifier: String

    /// The nested-code locations the fixture wrote, bundle-relative.
    let declaredNestedLocations: [String]

    /// The number of entries the container will record.
    var entryCount: Int { entries.count }
}

/// Builds the synthetic packages the signing scenario lab runs.
///
/// Every entry is generated here; no package, profile, certificate, key, or
/// byte of a real application is committed or downloaded. The packages are
/// shaped like the ones ZynSign accepts — and, in the refusal scenarios,
/// like the ones it must refuse — so the scenarios exercise the real rules
/// rather than a stand-in for them.
enum LabPackageFactory {

    /// The bundle identifier root every synthetic package uses. Chosen so a
    /// Lab artifact is unmistakable in a log and cannot collide with a real
    /// application the user imported.
    static let identifierRoot = "com.zynsign.lab"

    /// Builds the package for one scenario.
    ///
    /// - Throws: A typed internal failure when a fixture path refuses
    ///   ZynSign's own path rules. A fixture that cannot be named is a defect
    ///   in the Lab, and it is reported rather than skipped.
    static func package(for scenario: SigningScenarioIdentifier) throws -> LabPackage {
        switch scenario {
        case .simpleApplication:
            return try build(
                bundleName: "Simple.app",
                executable: "Simple",
                identifierSuffix: "simple",
                resources: ["Assets.car", "embedded.mobileprovision"],
                signatureRegion: false
            )
        case .applicationWithFrameworks:
            var package = try build(
                bundleName: "WithFrameworks.app",
                executable: "WithFrameworks",
                identifierSuffix: "frameworks",
                signatureRegion: false
            )
            package = try appending(
                framework: "Core.framework",
                executable: "Core",
                to: package
            )
            return try appendingStandaloneLibrary(named: "libhelper.dylib", to: package)
        case .applicationWithExtensions:
            var package = try build(
                bundleName: "WithExtensions.app",
                executable: "WithExtensions",
                identifierSuffix: "extensions",
                signatureRegion: false
            )
            return try appending(
                extension: "WidgetExtension.appex",
                executable: "WidgetExtension",
                to: package
            )
        case .multipleBundles:
            return try buildAmbiguous()
        case .unsignedApplication:
            return try build(
                bundleName: "Unsigned.app",
                executable: "Unsigned",
                identifierSuffix: "unsigned",
                resources: [],
                signatureRegion: false,
                codeResources: false
            )
        case .alreadySignedApplication:
            return try build(
                bundleName: "AlreadySigned.app",
                executable: "AlreadySigned",
                identifierSuffix: "alreadysigned",
                resources: ["embedded.mobileprovision"],
                signatureRegion: true,
                codeResources: true
            )
        case .largePackage:
            return try buildLarge()
        case .edgeCaseLayout:
            return try buildEdgeCase()
        }
    }

    // MARK: - Assembly

    private static func build(
        bundleName: String,
        executable: String,
        identifierSuffix: String,
        resources: [String],
        signatureRegion: Bool,
        codeResources: Bool = true
    ) throws -> LabPackage {
        let root = "Payload/\(bundleName)"
        var builder = LabEntryBuilder()
        try builder.addDirectory("Payload")
        try builder.addDirectory(root)
        try builder.addFile(
            "\(root)/Info.plist",
            content: try informationPlist(
                identifier: "\(identifierRoot).\(identifierSuffix)",
                executable: executable
            )
        )
        try builder.addFile(
            "\(root)/\(executable)",
            content: LabMachOImage.thinARM64(
                fileType: LabMachOImage.executeFileType,
                signature: signatureRegion ? LabMachOImage.emptyEmbeddedSignature : nil
            ),
            executable: true
        )
        if codeResources {
            try builder.addFile(
                "\(root)/_CodeSignature/CodeResources",
                content: try propertyList(["files": [:], "files2": [:]])
            )
        }
        for resource in resources {
            try builder.addFile("\(root)/\(resource)", content: resourceContent(named: resource))
        }
        return LabPackage(
            entries: builder.entries,
            bundleName: bundleName,
            bundleIdentifier: "\(identifierRoot).\(identifierSuffix)",
            declaredNestedLocations: []
        )
    }

    private static func appending(framework name: String, executable: String, to package: LabPackage) throws -> LabPackage {
        var builder = LabEntryBuilder(entries: package.entries)
        let root = "Payload/\(package.bundleName)/Frameworks"
        try builder.addDirectory(root)
        try builder.addDirectory("\(root)/\(name)")
        try builder.addFile(
            "\(root)/\(name)/Info.plist",
            content: try informationPlist(
                identifier: "\(identifierRoot).\(executable.lowercased())",
                executable: executable
            )
        )
        try builder.addFile(
            "\(root)/\(name)/\(executable)",
            content: LabMachOImage.thinARM64(fileType: LabMachOImage.dynamicLibraryFileType),
            executable: true
        )
        return LabPackage(
            entries: builder.entries,
            bundleName: package.bundleName,
            bundleIdentifier: package.bundleIdentifier,
            declaredNestedLocations: package.declaredNestedLocations + ["Frameworks/\(name)"]
        )
    }

    private static func appendingStandaloneLibrary(named name: String, to package: LabPackage) throws -> LabPackage {
        var builder = LabEntryBuilder(entries: package.entries)
        let root = "Payload/\(package.bundleName)/Frameworks"
        try builder.addDirectory(root)
        try builder.addFile(
            "\(root)/\(name)",
            content: LabMachOImage.thinARM64(fileType: LabMachOImage.dynamicLibraryFileType),
            executable: true
        )
        return LabPackage(
            entries: builder.entries,
            bundleName: package.bundleName,
            bundleIdentifier: package.bundleIdentifier,
            declaredNestedLocations: package.declaredNestedLocations + ["Frameworks/\(name)"]
        )
    }

    private static func appending(extension name: String, executable: String, to package: LabPackage) throws -> LabPackage {
        var builder = LabEntryBuilder(entries: package.entries)
        let root = "Payload/\(package.bundleName)/PlugIns"
        try builder.addDirectory(root)
        try builder.addDirectory("\(root)/\(name)")
        try builder.addFile(
            "\(root)/\(name)/Info.plist",
            content: try informationPlist(
                identifier: "\(package.bundleIdentifier).\(executable.lowercased())",
                executable: executable
            )
        )
        try builder.addFile(
            "\(root)/\(name)/\(executable)",
            content: LabMachOImage.thinARM64(fileType: LabMachOImage.executeFileType),
            executable: true
        )
        return LabPackage(
            entries: builder.entries,
            bundleName: package.bundleName,
            bundleIdentifier: package.bundleIdentifier,
            declaredNestedLocations: package.declaredNestedLocations + ["PlugIns/\(name)"]
        )
    }

    /// Two application bundles directly inside the payload: the layout
    /// discovery must refuse rather than choose between.
    private static func buildAmbiguous() throws -> LabPackage {
        var builder = LabEntryBuilder()
        try builder.addDirectory("Payload")
        for name in ["First.app", "Second.app"] {
            let root = "Payload/\(name)"
            try builder.addDirectory(root)
            try builder.addFile(
                "\(root)/Info.plist",
                content: try informationPlist(
                    identifier: "\(identifierRoot).\(name.replacingOccurrences(of: ".app", with: "").lowercased())",
                    executable: "App"
                )
            )
            try builder.addFile(
                "\(root)/App",
                content: LabMachOImage.thinARM64(fileType: LabMachOImage.executeFileType),
                executable: true
            )
        }
        return LabPackage(
            entries: builder.entries,
            bundleName: "First.app",
            bundleIdentifier: "\(identifierRoot).first",
            declaredNestedLocations: []
        )
    }

    /// A package at the size an ordinary large application reaches: one
    /// bundle, several hundred resources, about twelve megabytes of content.
    /// Chosen to measure inspection and discovery work, not to stress the
    /// device — a Lab must never be the thing that exhausts the machine it
    /// is validating.
    private static func buildLarge() throws -> LabPackage {
        let package = try build(
            bundleName: "Large.app",
            executable: "Large",
            identifierSuffix: "large",
            resources: [],
            signatureRegion: false
        )
        var builder = LabEntryBuilder(entries: package.entries)
        let root = "Payload/\(package.bundleName)"
        try builder.addDirectory("\(root)/Resources")
        let payload = Data(repeating: 0x5A, count: 32 * 1_024)
        for index in 0..<384 {
            try builder.addFile(
                "\(root)/Resources/asset-\(String(format: "%04d", index)).bin",
                content: payload
            )
        }
        return LabPackage(
            entries: builder.entries,
            bundleName: package.bundleName,
            bundleIdentifier: package.bundleIdentifier,
            declaredNestedLocations: []
        )
    }

    /// A coherent package whose layout is unusual rather than broken: deep
    /// nesting, non-ASCII names, a bundle nested inside the application
    /// bundle where discovery must report it rather than follow it, and a
    /// resource directory named the way macOS archives name theirs.
    private static func buildEdgeCase() throws -> LabPackage {
        let package = try build(
            bundleName: "Edge.app",
            executable: "Edge",
            identifierSuffix: "edge",
            resources: [],
            signatureRegion: false
        )
        var builder = LabEntryBuilder(entries: package.entries)
        let root = "Payload/\(package.bundleName)"
        // A bundle inside the application bundle: a real layout (wrapper
        // applications, bundled tools) that discovery must report as
        // unexpected placement rather than sign or silently skip.
        try builder.addDirectory("\(root)/Wrapper/Nested.app")
        try builder.addFile(
            "\(root)/Wrapper/Nested.app/Info.plist",
            content: try informationPlist(identifier: "\(identifierRoot).nested", executable: "Nested")
        )
        try builder.addFile(
            "\(root)/Wrapper/Nested.app/Nested",
            content: LabMachOImage.thinARM64(fileType: LabMachOImage.executeFileType),
            executable: true
        )
        // Deep, non-ASCII resource names, at a depth ordinary packages reach.
        let deep = (0..<8).map { "level\($0)" }.joined(separator: "/")
        try builder.addFile("\(root)/\(deep)/リソース.txt", content: Data("lab".utf8))
        try builder.addFile("\(root)/__MACOSX/._Edge", content: Data([0x00, 0x01]))
        return LabPackage(
            entries: builder.entries,
            bundleName: package.bundleName,
            bundleIdentifier: package.bundleIdentifier,
            declaredNestedLocations: ["Wrapper/Nested.app"]
        )
    }

    // MARK: - Content

    private static func informationPlist(identifier: String, executable: String) throws -> Data {
        try propertyList([
            "CFBundleIdentifier": identifier,
            "CFBundleName": executable,
            "CFBundleExecutable": executable,
            "CFBundleShortVersionString": "1.0",
            "CFBundleVersion": "1",
            "CFBundlePackageType": "APPL",
            "CFBundleSupportedPlatforms": ["iPhoneOS"],
            "CFBundleInfoDictionaryVersion": "6.0",
            "MinimumOSVersion": "17.0",
            "UIDeviceFamily": [1, 2]
        ])
    }

    private static func propertyList(_ root: [String: Any]) throws -> Data {
        do {
            return try PropertyListSerialization.data(fromPropertyList: root, format: .xml, options: 0)
        } catch {
            throw ZynSignError(
                category: .internalFailure,
                userMessage: "The Compatibility Lab could not build a synthetic package.",
                diagnosticDetail: "A Lab property list could not be serialized.",
                underlyingError: error
            )
        }
    }

    private static func resourceContent(named name: String) -> Data {
        let seed = Data(name.utf8)
        var content = Data()
        content.append(seed)
        content.append(Data(repeating: 0x11, count: 64))
        return content
    }
}

/// Collects validated entries for one synthetic package.
///
/// The builder refuses a name ZynSign's own path rules refuse, and says so
/// with a typed error instead of dropping the entry: a fixture that cannot
/// be named would otherwise exercise a layout it did not intend to.
private struct LabEntryBuilder {

    private(set) var entries: [ArchiveWriteEntry] = []

    init(entries: [ArchiveWriteEntry] = []) {
        self.entries = entries
    }

    mutating func addDirectory(_ path: String) throws {
        entries.append(ArchiveWriteEntry(path: try validated(path), kind: .directory))
    }

    mutating func addFile(_ path: String, content: Data, executable: Bool = false) throws {
        entries.append(
            ArchiveWriteEntry(
                path: try validated(path),
                kind: .regularFile(isExecutable: executable),
                content: content
            )
        )
    }

    private func validated(_ path: String) throws -> ArchivePath {
        guard let archivePath = ArchivePath(rawValue: path) else {
            throw ZynSignError(
                category: .internalFailure,
                userMessage: "The Compatibility Lab could not build a synthetic package.",
                diagnosticDetail: "The Lab fixture path '\(path)' does not satisfy ZynSign's archive path rules."
            )
        }
        return archivePath
    }
}
