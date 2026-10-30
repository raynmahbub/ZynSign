import Foundation

/// What the editor changed, for the run journal and the result screen.
struct SideloadEditReport: Equatable, Sendable {
    var removedPaths: [String] = []
    var rewrittenInfoPlists: [String] = []
    var injectedLibraries: [String] = []
    var disinjectedLibraries: [String] = []
    var stagedTweaks: [String] = []
    var stagedBundles: [String] = []
    var patchedBinaries: [String] = []
    var localizedStringsUpdated: [String] = []
    var replacedAppIcon: Bool = false
    var rewrittenExecutableNames: [String] = []

    var isEmpty: Bool {
        removedPaths.isEmpty && rewrittenInfoPlists.isEmpty
            && injectedLibraries.isEmpty && disinjectedLibraries.isEmpty
            && stagedTweaks.isEmpty && stagedBundles.isEmpty
            && patchedBinaries.isEmpty && localizedStringsUpdated.isEmpty
            && !replacedAppIcon && rewrittenExecutableNames.isEmpty
    }

    var summary: String {
        var parts: [String] = []
        if !removedPaths.isEmpty { parts.append("removed \(removedPaths.count)") }
        if !rewrittenInfoPlists.isEmpty { parts.append("rewrote \(rewrittenInfoPlists.count) Info.plist") }
        if !stagedTweaks.isEmpty { parts.append("staged \(stagedTweaks.count) tweaks") }
        if !stagedBundles.isEmpty { parts.append("staged \(stagedBundles.count) bundles") }
        if !injectedLibraries.isEmpty { parts.append("injected \(injectedLibraries.count)") }
        if !disinjectedLibraries.isEmpty { parts.append("disinjected \(disinjectedLibraries.count)") }
        if !patchedBinaries.isEmpty { parts.append("patched \(patchedBinaries.count)") }
        if replacedAppIcon { parts.append("replaced app icon") }
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
    case tweakNameConflict(String)
    case unsafeBundlePath(String)

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
        case .tweakNameConflict(let name):
            return "\(name) already exists in Frameworks with different bytes; rename or remove the staged tweak."
        case .unsafeBundlePath(let path):
            return "“\(path)” is outside the application bundle."
        }
    }
}

/// Applies the sideloading options to an extracted application bundle.
struct SideloadPackageEditor {

    let options: SideloadSigningOptions
    private let parser = ReadOnlyMachOParser()

    init(options: SideloadSigningOptions) {
        self.options = options
    }

    /// Edit `bundleDirectory` in place. The directory is the `.app` bundle.
    func apply(in bundleDirectory: URL) throws -> SideloadEditReport {
        var report = SideloadEditReport()
        try applyRemovals(in: bundleDirectory, report: &report)

        let mainInfoURL = bundleDirectory.appendingPathComponent("Info.plist")
        let original = try readInfoPlist(mainInfoURL)
        let oldIdentifier = original["CFBundleIdentifier"] as? String ?? ""
        let oldDisplayName = (original["CFBundleDisplayName"] as? String)
            ?? (original["CFBundleName"] as? String)
            ?? ""

        if !options.stagedBundlePayloads.isEmpty {
            try stageBundlePayloads(in: bundleDirectory, report: &report)
        }

        let updatedMain = try applyMainInfoPlistEdits(
            original: original,
            mainInfoURL: mainInfoURL,
            oldIdentifier: oldIdentifier,
            oldDisplayName: oldDisplayName,
            bundleDirectory: bundleDirectory,
            report: &report
        )

        let effectiveParentID = (updatedMain["CFBundleIdentifier"] as? String) ?? oldIdentifier
        if !effectiveParentID.isEmpty, effectiveParentID != oldIdentifier || !options.stagedBundlePayloads.isEmpty {
            try rewriteExtensionIdentifiers(
                in: bundleDirectory,
                oldParentIdentifier: oldIdentifier,
                newParentIdentifier: effectiveParentID,
                report: &report
            )
        }

        if options.localizesDisplayName,
           let localizedName = (updatedMain["CFBundleDisplayName"] as? String) ?? options.displayName,
           !localizedName.isEmpty {
            updateLocalizedStrings(in: bundleDirectory, displayName: localizedName, report: &report)
        }

        let stagedInstallNames = try stageDylibTweaks(in: bundleDirectory, report: &report)
        try applyMachOPatchesAndInjection(
            in: bundleDirectory,
            mainInfo: updatedMain,
            stagedTweakInstallNames: stagedInstallNames,
            report: &report
        )
        return report
    }

    // MARK: - Removals & Custom Icon

    private func applyRemovals(in bundleDirectory: URL, report: inout SideloadEditReport) throws {
        let fileManager = FileManager.default
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
        if options.removesProvisioningProfile {
            let prov = bundleDirectory.appendingPathComponent("embedded.mobileprovision")
            if fileManager.fileExists(atPath: prov.path) {
                try fileManager.removeItem(at: prov)
                report.removedPaths.append("embedded.mobileprovision")
            }
        }
        for rawRel in options.removedBundlePaths {
            let target = try resolveSafeSubpath(rawRel, inside: bundleDirectory)
            if fileManager.fileExists(atPath: target.path) {
                try fileManager.removeItem(at: target)
                report.removedPaths.append(rawRel)
            }
        }
    }

    private func applyMainInfoPlistEdits(
        original: [String: Any],
        mainInfoURL: URL,
        oldIdentifier: String,
        oldDisplayName: String,
        bundleDirectory: URL,
        report: inout SideloadEditReport
    ) throws -> [String: Any] {
        var updated = original
        var didMutate = false

        if let rawXML = options.rawInfoPlistXMLOverride,
           !rawXML.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let parsed = try PlistDocumentCodec.parseXML(rawXML)
            updated = parsed.mapValues { $0.toFoundationObject() }
            didMutate = true
        } else {
            let plan = InfoPlistOverrides.mainApplicationPlan(
                options,
                originalBundleIdentifier: oldIdentifier,
                originalDisplayName: oldDisplayName
            )
            if !plan.isEmpty {
                for (key, setting) in plan.values { updated[key] = Self.value(for: setting) }
                for key in plan.keysToRemove { updated.removeValue(forKey: key) }
                didMutate = true
            }
            if !options.customInfoPlistEntries.isEmpty || !options.customInfoPlistRemovals.isEmpty {
                for key in options.customInfoPlistRemovals { updated.removeValue(forKey: key) }
                for (key, val) in options.customInfoPlistEntries { updated[key] = val.toFoundationObject() }
                didMutate = true
            }
        }

        if let iconData = options.customIconPNGData, !iconData.isEmpty {
            try writeCustomIcon(iconData, in: bundleDirectory, infoPlist: &updated)
            report.replacedAppIcon = true
            didMutate = true
        }

        if didMutate {
            try writeInfoPlist(updated, to: mainInfoURL)
            report.rewrittenInfoPlists.append("Info.plist")
        }
        return updated
    }

    private func writeCustomIcon(
        _ pngData: Data,
        in bundleDirectory: URL,
        infoPlist: inout [String: Any]
    ) throws {
        let iconBase = "ZynCustomAppIcon60x60"
        for suffix in ["@2x.png", "@3x.png"] {
            let target = bundleDirectory.appendingPathComponent(iconBase + suffix)
            do {
                try pngData.write(to: target, options: .atomic)
            } catch {
                throw SideloadEditError.unwritableFile(iconBase + suffix)
            }
        }
        let iconDict: [String: Any] = [
            "CFBundlePrimaryIcon": [
                "CFBundleIconFiles": [iconBase],
                "CFBundleIconName": iconBase,
                "UIPrerenderedIcon": true
            ]
        ]
        infoPlist["CFBundleIcons"] = iconDict
        infoPlist["CFBundleIcons~ipad"] = iconDict
    }

    private func updateLocalizedStrings(
        in bundleDirectory: URL,
        displayName: String,
        report: inout SideloadEditReport
    ) {
        let fileManager = FileManager.default
        guard let children = try? fileManager.contentsOfDirectory(
            at: bundleDirectory, includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return }
        for dir in children where dir.pathExtension.lowercased() == "lproj" {
            let stringsURL = dir.appendingPathComponent("InfoPlist.strings")
            guard fileManager.fileExists(atPath: stringsURL.path),
                  let data = try? Data(contentsOf: stringsURL),
                  let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
                  var dict = plist as? [String: Any] else { continue }
            dict["CFBundleDisplayName"] = displayName
            dict["CFBundleName"] = displayName
            if let out = try? PropertyListSerialization.data(fromPropertyList: dict, format: .binary, options: 0),
               (try? out.write(to: stringsURL, options: .atomic)) != nil {
                report.localizedStringsUpdated.append("\(dir.lastPathComponent)/InfoPlist.strings")
            }
        }
    }

    // MARK: - Staged Tweaks & Bundle Payloads

    private func stageBundlePayloads(
        in bundleDirectory: URL,
        report: inout SideloadEditReport
    ) throws {
        let fileManager = FileManager.default
        for payload in options.stagedBundlePayloads {
            let parentDir: URL
            if payload.payloadType.targetSubdirectory.isEmpty {
                parentDir = bundleDirectory
            } else {
                parentDir = bundleDirectory.appendingPathComponent(
                    payload.payloadType.targetSubdirectory,
                    isDirectory: true
                )
            }
            for item in payload.files {
                let dest = try resolveSafeSubpath(item.relativePath, inside: parentDir)
                let folder = dest.deletingLastPathComponent()
                do {
                    try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
                    let outBytes = item.isExecutable ? Self.normalizeSignableMachOIfNeeded(item.bytes) : item.bytes
                    try outBytes.write(to: dest, options: .atomic)
                    if item.isExecutable {
                        try? fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest.path)
                    }
                } catch {
                    throw SideloadEditError.unwritableFile(item.relativePath)
                }
            }
            report.stagedBundles.append(payload.topLevelName)
        }
    }

    private func stageDylibTweaks(
        in bundleDirectory: URL,
        report: inout SideloadEditReport
    ) throws -> [String] {
        guard !options.tweaks.isEmpty else { return [] }
        let fileManager = FileManager.default
        let targetDir: URL
        switch options.tweakInjectFolder {
        case .frameworks:
            targetDir = bundleDirectory.appendingPathComponent("Frameworks", isDirectory: true)
        case .bundleRoot:
            targetDir = bundleDirectory
        }
        do {
            try fileManager.createDirectory(at: targetDir, withIntermediateDirectories: true)
        } catch {
            throw SideloadEditError.unwritableFile(options.tweakInjectFolder.rawValue)
        }

        var installNames: [String] = []
        for tweak in options.tweaks {
            let finalName = try resolveDylibDestinationName(
                tweak: tweak,
                in: targetDir
            )
            let destination = targetDir.appendingPathComponent(finalName)
            let preparedBytes = Self.normalizeSignableMachOIfNeeded(tweak.bytes)
            if let existing = try? Data(contentsOf: destination),
               existing == preparedBytes || existing == tweak.bytes {
                report.stagedTweaks.append(finalName)
                installNames.append(
                    options.tweakInjectFolder.installName(base: options.tweakInjectBase, fileName: finalName)
                )
                continue
            }
            do {
                try preparedBytes.write(to: destination, options: .atomic)
                try? fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)
            } catch {
                throw SideloadEditError.unwritableFile(finalName)
            }
            report.stagedTweaks.append(finalName)
            installNames.append(
                options.tweakInjectFolder.installName(base: options.tweakInjectBase, fileName: finalName)
            )
        }
        return installNames
    }

    /// Normalizes a staged Mach-O payload (thinning universal `arm64` archives
    /// and stripping upstream `ldid` code signatures) while leaving non-Mach-O
    /// resource/test payloads byte-for-byte untouched.
    static func normalizeSignableMachOIfNeeded(_ raw: Data) -> Data {
        guard raw.count >= 32 else { return raw }
        var working = raw
        if let thinned = try? GuestMachOPatcher.extractArm64Slice(working) {
            working = thinned
        }
        if MachOCodeSignatureStripper.carriesSignature(working),
           let stripped = try? MachOCodeSignatureStripper.stripSignature(from: working) {
            working = stripped
        }
        return working
    }

    private func resolveDylibDestinationName(
        tweak: SideloadStagedTweak,
        in targetDir: URL
    ) throws -> String {
        let initial = targetDir.appendingPathComponent(tweak.fileName)
        guard let existing = try? Data(contentsOf: initial) else { return tweak.fileName }
        if existing == tweak.bytes { return tweak.fileName }
        guard options.allowsTweakCollisionSuffixing else {
            throw SideloadEditError.tweakNameConflict(tweak.fileName)
        }
        let baseName = (tweak.fileName as NSString).deletingPathExtension
        for suffix in 2...32 {
            let candidate = "\(baseName)-\(suffix).dylib"
            let candidateURL = targetDir.appendingPathComponent(candidate)
            if !FileManager.default.fileExists(atPath: candidateURL.path) {
                return candidate
            }
        }
        throw SideloadEditError.tweakNameConflict(tweak.fileName)
    }

    // MARK: - Mach-O Patching & Load-Command Injection

    private func applyMachOPatchesAndInjection(
        in bundleDirectory: URL,
        mainInfo: [String: Any],
        stagedTweakInstallNames: [String],
        report: inout SideloadEditReport
    ) throws {
        let fileManager = FileManager.default
        let frameworkLinks = options.stagedBundlePayloads.compactMap { payload -> InjectedLibrary? in
            guard let sub = payload.linkedFrameworkExecutableSubpath else { return nil }
            return InjectedLibrary(installName: "\(options.tweakInjectBase.rawValue)/\(sub)")
        }
        let libraries = options.injectedLibraries
            + stagedTweakInstallNames.map { InjectedLibrary(installName: $0) }
            + frameworkLinks

        let needsBinaryPass = !libraries.isEmpty
            || !options.disinjectedLibraries.isEmpty
            || options.replacesSubstrateWithElleKit
            || options.fixesLegacyArm64eSlice
            || options.liquidGlassMode == .enable
        guard needsBinaryPass else { return }

        guard let executableName = mainInfo["CFBundleExecutable"] as? String else {
            throw SideloadEditError.unreadableInfoPlist("Info.plist has no CFBundleExecutable")
        }
        let mainExec = bundleDirectory.appendingPathComponent(executableName)
        guard fileManager.fileExists(atPath: mainExec.path) else {
            throw SideloadEditError.executableMissing(executableName)
        }

        if !options.disinjectedLibraries.isEmpty {
            try disinject(Set(options.disinjectedLibraries), from: mainExec, report: &report)
        }
        if options.liquidGlassMode == .enable,
           let raw = try? Data(contentsOf: mainExec) {
            let patched = MachOBinaryPatcher.patchMinimumSDKVersion(in: raw)
            if patched.modified {
                try patched.data.write(to: mainExec, options: .atomic)
                recordPatched(executableName, in: &report)
            }
        }

        let allBinaries = [mainExec] + (try nestedBinaries(in: bundleDirectory).filter { $0.path != mainExec.path })
        if options.replacesSubstrateWithElleKit || options.fixesLegacyArm64eSlice {
            try applyCompatibilityPatches(to: allBinaries, report: &report)
        }

        if !libraries.isEmpty {
            try inject(libraries, into: mainExec)
            recordPatched(executableName, in: &report)
            if options.injectsIntoNestedCode || !options.targetedExtensionNames.isEmpty {
                for candidate in try targetableExtensionBinaries(in: bundleDirectory, excluding: mainExec) {
                    try inject(libraries, into: candidate)
                    recordPatched(candidate.lastPathComponent, in: &report)
                }
            }
            report.injectedLibraries = libraries.map(\.installName)
        }
    }

    private func applyCompatibilityPatches(to binaries: [URL], report: inout SideloadEditReport) throws {
        let substrateMap: [String: String] = [
            "/Library/Frameworks/CydiaSubstrate.framework/CydiaSubstrate":
                "@rpath/CydiaSubstrate.framework/CydiaSubstrate",
            "/usr/lib/libsubstrate.dylib":
                "@rpath/CydiaSubstrate.framework/CydiaSubstrate"
        ]
        for binaryURL in binaries {
            guard var data = try? Data(contentsOf: binaryURL) else { continue }
            var changed = false
            if options.replacesSubstrateWithElleKit,
               let rewritten = try? MachOBinaryPatcher.rewriteInstallNames(in: data, replacements: substrateMap),
               rewritten.rewrittenCount > 0 {
                data = rewritten.data
                changed = true
            }
            if options.fixesLegacyArm64eSlice {
                let armFixed = MachOBinaryPatcher.fixLegacyArm64eSlices(in: data)
                if armFixed.modified {
                    data = armFixed.data
                    changed = true
                }
            }
            if changed {
                try data.write(to: binaryURL, options: .atomic)
                recordPatched(binaryURL.lastPathComponent, in: &report)
            }
        }
    }

    private func disinject(
        _ names: Set<String>,
        from binaryURL: URL,
        report: inout SideloadEditReport
    ) throws {
        guard let data = try? Data(contentsOf: binaryURL) else { return }
        if let outcome = try? MachOBinaryPatcher.removeLoadCommands(in: data, matchingInstallNames: names),
           outcome.removedCount > 0 {
            try outcome.data.write(to: binaryURL, options: .atomic)
            report.disinjectedLibraries.append(contentsOf: names.sorted())
            recordPatched(binaryURL.lastPathComponent, in: &report)
        }
    }

    private func recordPatched(_ name: String, in report: inout SideloadEditReport) {
        if !report.patchedBinaries.contains(name) {
            report.patchedBinaries.append(name)
        }
    }

    private func inject(_ libraries: [InjectedLibrary], into url: URL) throws {
        guard var bytes = try? Data(contentsOf: url) else {
            throw SideloadEditError.unwritableFile(url.lastPathComponent)
        }
        if let thinned = try? GuestMachOPatcher.extractArm64Slice(bytes), thinned.count != bytes.count {
            bytes = thinned
            if MachOCodeSignatureStripper.carriesSignature(bytes),
               let stripped = try? MachOCodeSignatureStripper.stripSignature(from: bytes) {
                bytes = stripped
            }
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
        let newCommandCount = UInt32(slice.header.loadCommandCount + plans.count)
        let newCommandsSize = UInt32(slice.header.loadCommandsSize + insertion.count)
        bytes.replaceSubrange(commandStart..<(commandStart + insertion.count), with: insertion)
        bytes.replaceSubrange(16..<20, with: Data(littleEndian: newCommandCount))
        bytes.replaceSubrange(20..<24, with: Data(littleEndian: newCommandsSize))
        do {
            try bytes.write(to: url, options: .atomic)
        } catch {
            throw SideloadEditError.unwritableFile(url.lastPathComponent)
        }
    }

    private func targetableExtensionBinaries(
        in bundleDirectory: URL,
        excluding mainExec: URL
    ) throws -> [URL] {
        let all = try nestedBinaries(in: bundleDirectory).filter { $0.path != mainExec.path }
        guard !options.targetedExtensionNames.isEmpty else {
            return options.injectsIntoNestedCode ? all : []
        }
        let targets = Set(options.targetedExtensionNames.map { $0.lowercased() })
        return all.filter { candidate in
            let parts = candidate.pathComponents.map { $0.lowercased() }
            return parts.contains { targets.contains($0) }
        }
    }

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
            if magic == Data([0xCF, 0xFA, 0xED, 0xFE]) || magic == Data([0xCA, 0xFE, 0xBA, 0xBE]) {
                found.append(url)
            }
        }
        return found.sorted { $0.path < $1.path }
    }

    // MARK: - Property Lists & Path Safety

    private func resolveSafeSubpath(_ relative: String, inside root: URL) throws -> URL {
        let parts = relative.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !parts.isEmpty, !parts.contains(".."), !parts.contains(".") else {
            throw SideloadEditError.unsafeBundlePath(relative)
        }
        var target = root
        for part in parts { target.appendPathComponent(part) }
        return target
    }

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

    private func rewriteExtensionIdentifiers(
        in bundleDirectory: URL,
        oldParentIdentifier: String,
        newParentIdentifier: String,
        report: inout SideloadEditReport
    ) throws {
        let fileManager = FileManager.default
        for name in ["PlugIns", "Extensions"] {
            let root = bundleDirectory.appendingPathComponent(name, isDirectory: true)
            guard fileManager.fileExists(atPath: root.path),
                  let children = try? fileManager.contentsOfDirectory(
                    at: root, includingPropertiesForKeys: nil) else { continue }
            for child in children where child.pathExtension == "appex" {
                let infoURL = child.appendingPathComponent("Info.plist")
                guard var values = try? readInfoPlist(infoURL),
                      let identifier = values["CFBundleIdentifier"] as? String else { continue }
                let updated: String
                if !oldParentIdentifier.isEmpty,
                   let cascaded = InfoPlistOverrides.extensionIdentifier(
                    oldIdentifier: identifier,
                    oldParentIdentifier: oldParentIdentifier,
                    newParentIdentifier: newParentIdentifier
                   ) {
                    updated = cascaded
                } else {
                    let suffix = (identifier.split(separator: ".").last.map(String.init))
                        ?? child.deletingPathExtension().lastPathComponent
                    updated = "\(newParentIdentifier).\(suffix)"
                }
                values["CFBundleIdentifier"] = updated
                try writeInfoPlist(values, to: infoURL)
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
    init(littleEndian value: UInt32) {
        self.init([
            UInt8(value & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 24) & 0xFF),
        ])
    }
}
