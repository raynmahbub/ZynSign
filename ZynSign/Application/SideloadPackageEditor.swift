import Foundation

/// What the editor changed, for the run journal and the result screen.
struct SideloadEditReport: Equatable, Sendable {
    var removedPaths: [String] = []
    var rewrittenInfoPlists: [String] = []
    var injectedLibraries: [String] = []
    var patchedBinaries: [String] = []
    var rewrittenExecutableNames: [String] = []

    var isEmpty: Bool {
        removedPaths.isEmpty && rewrittenInfoPlists.isEmpty
            && injectedLibraries.isEmpty && patchedBinaries.isEmpty
            && rewrittenExecutableNames.isEmpty
    }

    var summary: String {
        var parts: [String] = []
        if !removedPaths.isEmpty { parts.append("removed \(removedPaths.count)") }
        if !rewrittenInfoPlists.isEmpty { parts.append("rewrote \(rewrittenInfoPlists.count) Info.plist") }
        if !injectedLibraries.isEmpty { parts.append("injected \(injectedLibraries.count)") }
        if !patchedBinaries.isEmpty { parts.append("patched \(patchedBinaries.count)") }
        return parts.isEmpty ? "No package edits." : "Package edits: " + parts.joined(separator: ", ") + "."
    }
}

/// Why the package could not be edited as asked.
enum SideloadEditError: Error, Equatable, Hashable, Sendable {
    case executableMissing(String)
    case unreadableInfoPlist(String)
    case unwritableFile(String)
    case universalImageUnsupported(String)
    case imageAlreadySigned(String)
    case injectionRefused(String, DylibInjectionError)
    case unsupportedImage(String)

    var message: String {
        switch self {
        case .executableMissing(let name):
            return "The bundle does not contain its declared executable “\(name)”."
        case .unreadableInfoPlist(let path):
            return "\(path) could not be read as a property list."
        case .unwritableFile(let path):
            return "\(path) could not be written."
        case .universalImageUnsupported(let path):
            return "\(path) is a universal binary; injection needs a single arm64 slice."
        case .imageAlreadySigned(let path):
            return "\(path) already carries a signature; injecting a library would invalidate it."
        case .injectionRefused(let path, let error):
            return "\(path): \(error.message)"
        case .unsupportedImage(let path):
            return "\(path) is not a thin little-endian Mach-O image this app can edit."
        }
    }
}

/// Applies the sideloading options to an extracted application bundle.
///
/// The editor runs inside the signing working copy, after extraction and
/// before any binary is signed: the order matters, because the CodeDirectory
/// hashes the header the editor changes. Removals come first (so refused code
/// is never signed), then Info.plist overrides (so the identifier the engine
/// reports is the identifier written), then injection (so the load command is
/// covered by the signature that follows).
struct SideloadPackageEditor {

    let options: SideloadSigningOptions
    private let parser = ReadOnlyMachOParser()

    init(options: SideloadSigningOptions) {
        self.options = options
    }

    /// Edit `bundleDirectory` in place. The directory is the `.app` bundle.
    func apply(in bundleDirectory: URL) throws -> SideloadEditReport {
        var report = SideloadEditReport()
        let fileManager = FileManager.default

        // 1. Refused nested code.
        if options.removesPlugIns || options.removesAppExtensions {
            for name in ["PlugIns", "Extensions"] {
                let path = bundleDirectory.appendingPathComponent(name, isDirectory: true)
                if fileManager.fileExists(atPath: path.path) {
                    try fileManager.removeItem(at: path)
                    report.removedPaths.append(name)
                }
            }
        }
        if options.removesWatchApps {
            let path = bundleDirectory.appendingPathComponent("Watch", isDirectory: true)
            if fileManager.fileExists(atPath: path.path) {
                try fileManager.removeItem(at: path)
                report.removedPaths.append("Watch")
            }
        }

        // 2. Info.plist overrides, main app first so an extension can follow
        //    the renamed parent.
        let mainInfoURL = bundleDirectory.appendingPathComponent("Info.plist")
        let original = try readInfoPlist(mainInfoURL)
        let plan = InfoPlistOverrides.mainApplicationPlan(options)
        if !plan.isEmpty {
            var updated = original
            for (key, setting) in plan.values {
                updated[key] = Self.value(for: setting)
            }
            for key in plan.keysToRemove {
                updated.removeValue(forKey: key)
            }
            try writeInfoPlist(updated, to: mainInfoURL)
            report.rewrittenInfoPlists.append("Info.plist")
        }

        let oldIdentifier = original["CFBundleIdentifier"] as? String ?? ""
        if let newIdentifier = options.bundleIdentifier, !oldIdentifier.isEmpty {
            try rewriteExtensionIdentifiers(in: bundleDirectory,
                                            oldParentIdentifier: oldIdentifier,
                                            newParentIdentifier: newIdentifier,
                                            report: &report)
        }

        // 3. Injection into the main executable, and into nested code when
        //    the user asked for it.
        if !options.injectedLibraries.isEmpty {
            guard let executableName = original["CFBundleExecutable"] as? String else {
                throw SideloadEditError.unreadableInfoPlist("Info.plist has no CFBundleExecutable")
            }
            let executable = bundleDirectory.appendingPathComponent(executableName)
            guard fileManager.fileExists(atPath: executable.path) else {
                throw SideloadEditError.executableMissing(executableName)
            }
            try inject(options.injectedLibraries, into: executable)
            report.patchedBinaries.append(executableName)
            if options.injectsIntoNestedCode {
                for candidate in try nestedBinaries(in: bundleDirectory) {
                    try inject(options.injectedLibraries, into: candidate)
                    report.patchedBinaries.append(candidate.lastPathComponent)
                }
            }
            report.injectedLibraries = options.injectedLibraries.map(\.installName)
        }

        return report
    }

    // MARK: - Binaries

    /// Insert the load commands, then let the existing signature writer cover
    /// them. The image is refused rather than partially edited.
    private func inject(_ libraries: [InjectedLibrary], into url: URL) throws {
        guard var bytes = try? Data(contentsOf: url) else {
            throw SideloadEditError.unwritableFile(url.lastPathComponent)
        }
        let image: MachOImage
        do {
            image = try parser.parse(bytes)
        } catch {
            throw SideloadEditError.unsupportedImage(url.lastPathComponent)
        }
        guard image.slices.count == 1, let slice = image.slices.first else {
            throw SideloadEditError.universalImageUnsupported(url.lastPathComponent)
        }
        guard slice.header.wordSize == .bits64,
              slice.header.byteOrder == .littleEndian else {
            throw SideloadEditError.unsupportedImage(url.lastPathComponent)
        }
        if let signature = slice.embeddedSignature, signature.command.dataSize > 0 {
            throw SideloadEditError.imageAlreadySigned(url.lastPathComponent)
        }
        let layout = MachOHeaderLayout(
            headerSize: slice.headerSize,
            numberOfCommands: slice.header.loadCommandCount,
            sizeOfCommands: slice.header.loadCommandsSize,
            firstSectionFileOffset: slice.firstFileBackedContentOffset,
            firstSegmentFileOffset: slice.segments
                .map { Int(clamping: $0.fileOffset) }
                .filter { $0 > 0 }
                .min(),
            hasCodeSignatureCommand: slice.loadCommands.contains(where: \.isCodeSignature),
            hasLinkeditSegment: slice.segments.contains(where: { $0.name.isLinkEdit })
        )
        let plans: [DylibInjectionPlan]
        do {
            plans = try DylibInjectionPlanner.plan(for: layout, injecting: libraries)
        } catch let error as DylibInjectionError {
            throw SideloadEditError.injectionRefused(url.lastPathComponent, error)
        }
        var insertion = Data()
        for plan in plans { insertion.append(plan.loadCommand) }
        let commandStart = slice.headerSize + slice.header.loadCommandsSize
        // Only the library commands are written here. The signature writer adds
        // LC_CODE_SIGNATURE itself, immediately after the (now larger) command
        // area, and it requires those bytes to be zero. The planner reserved
        // those 16 bytes when it checked the padding, so what is left between
        // the inserted commands and the first file-backed byte must stay
        // untouched — writing anything there is exactly the
        // "nonZeroLoadCommandPadding" refusal the writer raises.
        // Header bookkeeping: ncmds at 16, sizeofcmds at 20 in both word sizes.
        let newCommandCount = UInt32(slice.header.loadCommandCount + plans.count)
        let newCommandsSize = UInt32(slice.header.loadCommandsSize + insertion.count)
        bytes.replaceSubrange(commandStart..<(commandStart + insertion.count),
                              with: insertion)
        bytes.replaceSubrange(16..<20, with: Data(littleEndian: newCommandCount))
        bytes.replaceSubrange(20..<24, with: Data(littleEndian: newCommandsSize))
        do {
            try bytes.write(to: url, options: .atomic)
        } catch {
            throw SideloadEditError.unwritableFile(url.lastPathComponent)
        }
    }

    /// Every thin Mach-O under the bundle that is not the main executable.
    private func nestedBinaries(in bundleDirectory: URL) throws -> [URL] {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: bundleDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var found: [URL] = []
        for case let url as URL in enumerator {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                continue
            }
            guard let handle = try? FileHandle(forReadingFrom: url) else { continue }
            let magic = (try? handle.read(upToCount: 4)) ?? Data()
            try? handle.close()
            if magic == Data([0xCF, 0xFA, 0xED, 0xFE]) {
                found.append(url)
            }
        }
        return found.sorted { $0.path < $1.path }
    }

    // MARK: - Property lists

    private func readInfoPlist(_ url: URL) throws -> [String: Any] {
        guard let data = try? Data(contentsOf: url),
              let value = try? PropertyListSerialization.propertyList(
                from: data, options: [], format: nil),
              let dictionary = value as? [String: Any] else {
            throw SideloadEditError.unreadableInfoPlist(url.path)
        }
        return dictionary
    }

    private func writeInfoPlist(_ values: [String: Any], to url: URL) throws {
        do {
            let data = try PropertyListSerialization.data(
                fromPropertyList: values, format: .binary, options: 0)
            try data.write(to: url, options: .atomic)
        } catch {
            throw SideloadEditError.unwritableFile(url.path)
        }
    }

    private func rewriteExtensionIdentifiers(in bundleDirectory: URL,
                                             oldParentIdentifier: String,
                                             newParentIdentifier: String,
                                             report: inout SideloadEditReport) throws {
        let fileManager = FileManager.default
        for name in ["PlugIns", "Extensions"] {
            let root = bundleDirectory.appendingPathComponent(name, isDirectory: true)
            guard fileManager.fileExists(atPath: root.path),
                  let children = try? fileManager.contentsOfDirectory(
                    at: root, includingPropertiesForKeys: nil) else { continue }
            for child in children where child.pathExtension == "appex" {
                let infoURL = child.appendingPathComponent("Info.plist")
                let values = try readInfoPlist(infoURL)
                guard let identifier = values["CFBundleIdentifier"] as? String,
                      let updated = InfoPlistOverrides.extensionIdentifier(
                        oldIdentifier: identifier,
                        oldParentIdentifier: oldParentIdentifier,
                        newParentIdentifier: newParentIdentifier) else { continue }
                var changed = values
                changed["CFBundleIdentifier"] = updated
                try writeInfoPlist(changed, to: infoURL)
                report.rewrittenInfoPlists.append("\(name)/\(child.lastPathComponent)/Info.plist")
            }
        }
    }

    private static func value(for setting: InfoPlistOverridePlan.PlistSetting) -> Any {
        switch setting {
        case .string(let value): return value
        case .boolean(let value): return value
        case .integer(let value): return value
        }
    }
}

extension Data {
    /// The four little-endian bytes of a `UInt32`, without a pointer dance.
    init(littleEndian value: UInt32) {
        self.init([
            UInt8(value & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 24) & 0xFF),
        ])
    }
}
