import Foundation

/// Application use case: discovers, inspects, and organizes all resources
/// and media assets in an imported IPA bundle for the Resource & Asset Studio.
///
/// Designed to be fast, low-memory, and strictly read-only. Bounded prefix
/// reads extract dimensions, durations, and font tables without decoding
/// large bitmaps or loading full media files until requested.
public struct IPAResourceStudioInspection: Sendable {

    private let library: ApplicationLibrary
    private let readerProvider: any ArtifactArchiveReaderProvider
    private let limits: ArchiveLimits

    init(
        library: ApplicationLibrary,
        readerProvider: any ArtifactArchiveReaderProvider,
        limits: ArchiveLimits = .default
    ) {
        self.library = library
        self.readerProvider = readerProvider
        self.limits = limits
    }

    // MARK: - Fast Summary (Structure Only)

    /// Computes the resource summary instantly from bundle structure without reading file bytes.
    public func quickSummary(from contents: BundleContents) -> ResourceSummary {
        var icons = 0
        var launch = 0
        var images = 0
        var fonts = 0
        var audio = 0
        var video = 0
        var localization = 0
        var totalBytes = 0

        for entry in contents.allEntries {
            guard entry.kind == .regularFile else {
                if entry.isDirectory && entry.name.hasSuffix(".lproj") {
                    localization += 1
                }
                continue
            }

            let name = entry.name.lowercased()
            let ext = BundleFileClassification.fileExtension(entry.name)
            let bytes = entry.declaredByteCount ?? 0
            totalBytes += bytes

            if name.contains("appicon") || (name.contains("icon") && ext == "png") {
                icons += 1
            } else if name.contains("launch") || name.hasPrefix("default") && ext == "png" {
                launch += 1
            } else if ["png", "jpg", "jpeg", "gif", "heic", "heif", "webp", "svg", "icns", "car"].contains(ext) {
                images += 1
            } else if ["ttf", "otf", "ttc", "dfont"].contains(ext) {
                fonts += 1
            } else if ["mp3", "wav", "m4a", "aac", "caf", "aiff", "ogg", "flac"].contains(ext) {
                audio += 1
            } else if ["mp4", "mov", "m4v", "webm"].contains(ext) {
                video += 1
            } else if ext == "strings" || ext == "stringsdict" || entry.path.rawValue.contains(".lproj/") {
                localization += 1
            }
        }

        let totalResources = icons + launch + images + fonts + audio + video + localization
        return ResourceSummary(
            iconCount: icons,
            launchAssetCount: launch,
            imageCount: images,
            fontCount: fonts,
            audioCount: audio,
            videoCount: video,
            localizationCount: localization,
            totalResourceCount: totalResources,
            totalByteCount: totalBytes
        )
    }

    // MARK: - Full Deep Inspection

    /// Performs the comprehensive read-only Resource & Asset Studio inspection.
    public func inspect(recordWithID id: ApplicationRecordIdentifier) async throws -> ResourceCatalog {
        try Task.checkCancellation()

        guard let entry = try await library.entry(withID: id) else {
            throw ZynSignError.libraryRecordNotFound(
                diagnosticDetail: "No record '\(id.rawValue)' exists to inspect."
            )
        }
        guard entry.isArtifactAvailable else {
            throw ZynSignError.bundleArtifactMissing(
                diagnosticDetail: "The library holds no artifact for record '\(id.rawValue)'."
            )
        }

        let reader = try readerProvider.archiveReader(for: entry.record.artifact.artifactID)
        defer { reader.close() }

        let table = try reader.readEntryTable()
        try Task.checkCancellation()

        guard case .exactlyOne(let bundleRoot) = ApplicationBundleDiscovery.discover(in: table).outcome else {
            throw ZynSignError.missingApplicationBundle(
                diagnosticDetail: "No single application bundle in record '\(id.rawValue)'."
            )
        }

        // 1. Read bounded Info.plist for declared icons, launch screen, fonts, etc.
        let infoPlistData = try? readBundleFile(
            named: IPALayout.bundleInformationFileName,
            reader: reader,
            bundleRoot: bundleRoot,
            maxBytes: 1 * 1024 * 1024
        )
        let infoDict: [String: Any] = {
            guard let data = infoPlistData else { return [:] }
            var format = PropertyListSerialization.PropertyListFormat.xml
            return (try? PropertyListSerialization.propertyList(from: data, options: [], format: &format) as? [String: Any]) ?? [:]
        }()

        // 2. Discover App Icons
        let discoveredIcons = discoverAppIcons(table: table, bundleRoot: bundleRoot, infoDict: infoDict, reader: reader)

        // 3. Discover Launch Screen
        let launchAsset = discoverLaunchAssets(table: table, bundleRoot: bundleRoot, infoDict: infoDict, reader: reader)

        // 4. Discover Images
        let images = discoverImages(table: table, bundleRoot: bundleRoot, reader: reader, iconPaths: Set(discoveredIcons.map(\.bundlePath)), launchPaths: Set(launchAsset.launchImages.map(\.bundlePath)))

        // 5. Discover Fonts
        let fonts = discoverFonts(table: table, bundleRoot: bundleRoot, infoDict: infoDict, reader: reader)

        // 6. Discover Localization
        let (locGroups, locFiles) = discoverLocalization(table: table, bundleRoot: bundleRoot, reader: reader)

        // 7. Discover Audio
        let audio = discoverAudio(table: table, bundleRoot: bundleRoot, reader: reader)

        // 8. Discover Videos
        let videos = discoverVideos(table: table, bundleRoot: bundleRoot, reader: reader)

        // 9. All regular entries for duplicate detection
        let allRegularEntries: [(path: BundlePath, size: Int)] = table.compactMap { e in
            guard e.kind == .regularFile, let p = e.path, let bp = BundlePath(p, relativeTo: bundleRoot) else { return nil }
            return (bp, e.uncompressedSize)
        }

        // 10. Duplicate Resource Detection
        let duplicates = DuplicateResourceDetector.detect(
            images: images,
            fonts: fonts,
            localizationFiles: locFiles,
            allEntries: allRegularEntries
        )

        // 11. Asset Relationships Grouping
        let relationships = AssetRelationshipGrouper.group(
            icons: discoveredIcons,
            launch: launchAsset,
            localizations: locFiles,
            fonts: fonts
        )

        // 12. Build Summary
        let totalCount = discoveredIcons.count + launchAsset.totalAssetCount + images.count + fonts.count + audio.count + videos.count + locFiles.count
        // Byte totals accumulate one source at a time so each sub-expression
        // stays small enough for the type checker to solve quickly.
        var totalBytes = 0
        totalBytes += discoveredIcons.map(\.fileSize).reduce(0, +)
        totalBytes += images.map(\.fileSize).reduce(0, +)
        totalBytes += fonts.map(\.fileSize).reduce(0, +)
        totalBytes += audio.map(\.fileSize).reduce(0, +)
        totalBytes += videos.map(\.fileSize).reduce(0, +)
        totalBytes += locFiles.map(\.fileSize).reduce(0, +)

        let summary = ResourceSummary(
            iconCount: discoveredIcons.count,
            launchAssetCount: launchAsset.totalAssetCount,
            imageCount: images.count,
            fontCount: fonts.count,
            audioCount: audio.count,
            videoCount: videos.count,
            localizationCount: locFiles.count,
            totalResourceCount: totalCount,
            totalByteCount: totalBytes,
            duplicateCount: duplicates.totalDuplicateCount,
            wastedDuplicateBytes: duplicates.totalWastedBytes
        )

        return ResourceCatalog(
            summary: summary,
            icons: discoveredIcons,
            launchAsset: launchAsset,
            images: images,
            fonts: fonts,
            localizations: locGroups,
            localizationFiles: locFiles,
            audio: audio,
            videos: videos,
            duplicates: duplicates,
            relationships: relationships
        )
    }

    // MARK: - On-Demand Content Reads

    /// Reads raw data for a specific resource entry.
    public func readEntryData(
        recordWithID id: ApplicationRecordIdentifier,
        bundlePath: BundlePath,
        maximumBytes: Int
    ) async throws -> Data {
        guard let entry = try await library.entry(withID: id), entry.isArtifactAvailable else {
            throw ZynSignError.bundleArtifactMissing(diagnosticDetail: "Artifact unavailable.")
        }
        let reader = try readerProvider.archiveReader(for: entry.record.artifact.artifactID)
        defer { reader.close() }

        let table = try reader.readEntryTable()
        guard case .exactlyOne(let bundleRoot) = ApplicationBundleDiscovery.discover(in: table).outcome,
              let archivePath = Self.archivePath(for: bundlePath, within: bundleRoot) else {
            throw ZynSignError.bundleInspectionFailure(diagnosticDetail: "Cannot resolve path \(bundlePath.rawValue)")
        }
        return try reader.readEntryData(at: archivePath, maximumBytes: maximumBytes)
    }

    /// Reads and parses `.strings` entries on demand.
    public func readStringsEntries(
        recordWithID id: ApplicationRecordIdentifier,
        bundlePath: BundlePath
    ) async throws -> [LocalizationEntry] {
        let data = try await readEntryData(
            recordWithID: id,
            bundlePath: bundlePath,
            maximumBytes: ResourceStudioLimits.maximumStringsFileBytes
        )
        return ResourceMetadataParsers.parseStringsFile(from: data)
    }

    // MARK: - Private Discovery Helpers

    private func discoverAppIcons(
        table: [ArchiveEntry],
        bundleRoot: ArchivePath,
        infoDict: [String: Any],
        reader: any ArchiveReader
    ) -> [AppIconAsset] {
        var icons: [AppIconAsset] = []
        var seenPaths = Set<String>()

        // 1. Check CFBundleIcons / CFBundleIcons~ipad
        var primaryIconNames: [String] = []
        var alternateIconSets: [String: [String]] = [:]

        if let cfIcons = infoDict["CFBundleIcons"] as? [String: Any] {
            if let primary = cfIcons["CFBundlePrimaryIcon"] as? [String: Any] {
                if let files = primary["CFBundleIconFiles"] as? [String] {
                    primaryIconNames.append(contentsOf: files)
                }
            }
            if let alternates = cfIcons["CFBundleAlternateIcons"] as? [String: Any] {
                for (altName, altDict) in alternates {
                    if let dict = altDict as? [String: Any], let files = dict["CFBundleIconFiles"] as? [String] {
                        alternateIconSets[altName] = files
                    }
                }
            }
        }

        if let cfIconsIpad = infoDict["CFBundleIcons~ipad"] as? [String: Any] {
            if let primary = cfIconsIpad["CFBundlePrimaryIcon"] as? [String: Any] {
                if let files = primary["CFBundleIconFiles"] as? [String] {
                    primaryIconNames.append(contentsOf: files)
                }
            }
            if let alternates = cfIconsIpad["CFBundleAlternateIcons"] as? [String: Any] {
                for (altName, altDict) in alternates {
                    if let dict = altDict as? [String: Any], let files = dict["CFBundleIconFiles"] as? [String] {
                        alternateIconSets["\(altName) (iPad)"] = files
                    }
                }
            }
        }

        // 2. Discover all icon files in the bundle
        for archiveEntry in table where archiveEntry.kind == .regularFile {
            guard let ap = archiveEntry.path, let bp = BundlePath(ap, relativeTo: bundleRoot) else { continue }
            let name = bp.name ?? bp.rawValue
            let lower = name.lowercased()
            let ext = BundleFileClassification.fileExtension(name)

            guard ext == "png" else { continue }

            let isDeclaredPrimary = primaryIconNames.contains { p in lower.contains(p.lowercased()) }
            var alternateSet: String? = nil
            for (altName, altFiles) in alternateIconSets {
                if altFiles.contains(where: { lower.contains($0.lowercased()) }) {
                    alternateSet = altName
                    break
                }
            }

            let isGeneralIcon = lower.contains("appicon") || lower.hasPrefix("icon") || isDeclaredPrimary || alternateSet != nil

            guard isGeneralIcon else { continue }
            guard !seenPaths.contains(bp.rawValue) else { continue }
            seenPaths.insert(bp.rawValue)

            // Bounded prefix read for dimensions
            let prefix = (try? reader.readEntryPrefix(at: ap, maximumBytes: ResourceStudioLimits.imageHeaderPrefixBytes)) ?? Data()
            let dims = ResourceMetadataParsers.parseImageDimensions(from: prefix)

            // Parse scale and idiom from filename
            let scale: Int? = {
                if name.contains("@3x") { return 3 }
                if name.contains("@2x") { return 2 }
                if name.contains("@1x") { return 1 }
                return nil
            }()

            let idiom: String? = {
                if lower.contains("~ipad") || lower.contains("ipad") { return "iPad" }
                if lower.contains("~iphone") || lower.contains("iphone") { return "iPhone" }
                if lower.contains("carplay") { return "CarPlay" }
                if lower.contains("watch") { return "Watch" }
                return nil
            }()

            let isPrimary = isDeclaredPrimary || (icons.isEmpty && alternateSet == nil)
            let isAlternate = alternateSet != nil
            let iconSetName = alternateSet ?? (isPrimary ? "Primary" : "AppIcon")

            icons.append(AppIconAsset(
                bundlePath: bp,
                fileName: name,
                fileSize: archiveEntry.uncompressedSize,
                format: "PNG",
                role: isPrimary ? .primary : (isAlternate ? .alternate : .standard),
                isPrimary: isPrimary,
                isAlternate: isAlternate,
                iconSetName: iconSetName,
                pixelWidth: dims?.width,
                pixelHeight: dims?.height,
                scale: scale,
                idiom: idiom
            ))
        }

        return icons.sorted { ($0.isPrimary ? 0 : 1) < ($1.isPrimary ? 0 : 1) }
    }

    private func discoverLaunchAssets(
        table: [ArchiveEntry],
        bundleRoot: ArchivePath,
        infoDict: [String: Any],
        reader: any ArchiveReader
    ) -> LaunchScreenAsset {
        var storyboardPaths: [BundlePath] = []
        var launchImages: [ImageAsset] = []
        var launchNibs: [BundlePath] = []

        let declaredStoryboard = infoDict["UILaunchStoryboardName"] as? String
        var declaredConfig: [String: String] = [:]
        if let config = infoDict["UILaunchScreen"] as? [String: Any] {
            for (k, v) in config {
                declaredConfig[k] = String(describing: v)
            }
        }

        for archiveEntry in table {
            guard let ap = archiveEntry.path, let bp = BundlePath(ap, relativeTo: bundleRoot) else { continue }
            let name = bp.name ?? bp.rawValue
            let lower = name.lowercased()

            if name.hasSuffix(".storyboard") || name.hasSuffix(".storyboardc") {
                if lower.contains("launch") {
                    storyboardPaths.append(bp)
                }
            } else if name.hasSuffix(".nib") {
                if lower.contains("launch") {
                    launchNibs.append(bp)
                }
            } else if archiveEntry.kind == .regularFile {
                let ext = BundleFileClassification.fileExtension(name)
                if ["png", "jpg", "jpeg"].contains(ext) && (lower.contains("launch") || lower.hasPrefix("default")) {
                    let prefix = (try? reader.readEntryPrefix(at: ap, maximumBytes: ResourceStudioLimits.imageHeaderPrefixBytes)) ?? Data()
                    let dims = ResourceMetadataParsers.parseImageDimensions(from: prefix)
                    launchImages.append(ImageAsset(
                        bundlePath: bp,
                        fileName: name,
                        fileSize: archiveEntry.uncompressedSize,
                        format: ext.uppercased(),
                        pixelWidth: dims?.width,
                        pixelHeight: dims?.height,
                        isLaunchImage: true,
                        category: .launch,
                        tag: "Launch Image"
                    ))
                }
            }
        }

        let activeType: LaunchScreenAsset.LaunchType = {
            if declaredStoryboard != nil || !storyboardPaths.isEmpty {
                return .storyboard
            }
            if !declaredConfig.isEmpty {
                return .launchScreenPlist
            }
            if !launchNibs.isEmpty {
                return .launchScreenNib
            }
            if !launchImages.isEmpty {
                return .launchImages
            }
            return .none
        }()

        let activeSummary: String = {
            switch activeType {
            case .storyboard:
                return "Active: Storyboard (\(declaredStoryboard ?? storyboardPaths.first.flatMap { $0.name } ?? "LaunchScreen"))"
            case .launchScreenPlist:
                return "Active: Info.plist (UILaunchScreen key)"
            case .launchScreenNib:
                return "Active: Compiled NIB (\(launchNibs.first.flatMap { $0.name } ?? "LaunchScreen.nib"))"
            case .launchImages:
                return "Active: Static Launch Images (\(launchImages.count) assets)"
            case .none:
                return "No launch asset declared"
            }
        }()

        return LaunchScreenAsset(
            activeType: activeType,
            activeAssetSummary: activeSummary,
            storyboardPaths: storyboardPaths,
            launchImages: launchImages,
            launchNibEntries: launchNibs,
            declaredStoryboardName: declaredStoryboard,
            declaredConfiguration: declaredConfig
        )
    }

    private func discoverImages(
        table: [ArchiveEntry],
        bundleRoot: ArchivePath,
        reader: any ArchiveReader,
        iconPaths: Set<BundlePath>,
        launchPaths: Set<BundlePath>
    ) -> [ImageAsset] {
        var images: [ImageAsset] = []
        let supportedExtensions = ["png", "jpg", "jpeg", "gif", "heic", "heif", "webp", "svg", "icns", "car"]

        for archiveEntry in table where archiveEntry.kind == .regularFile {
            guard let ap = archiveEntry.path, let bp = BundlePath(ap, relativeTo: bundleRoot) else { continue }
            let name = bp.name ?? bp.rawValue
            let ext = BundleFileClassification.fileExtension(name)

            guard supportedExtensions.contains(ext) else { continue }
            guard !iconPaths.contains(bp), !launchPaths.contains(bp) else { continue }

            let dims: ResourceMetadataParsers.ImageDimensions? = {
                if ext == "car" || ext == "svg" { return nil }
                guard let prefix = try? reader.readEntryPrefix(at: ap, maximumBytes: ResourceStudioLimits.imageHeaderPrefixBytes) else { return nil }
                return ResourceMetadataParsers.parseImageDimensions(from: prefix)
            }()

            let scale: Int? = {
                if name.contains("@3x") { return 3 }
                if name.contains("@2x") { return 2 }
                if name.contains("@1x") { return 1 }
                return nil
            }()

            images.append(ImageAsset(
                bundlePath: bp,
                fileName: name,
                fileSize: archiveEntry.uncompressedSize,
                format: ext.uppercased(),
                pixelWidth: dims?.width,
                pixelHeight: dims?.height,
                scale: scale,
                category: .image
            ))
        }

        return images.sorted { $0.fileName.localizedStandardCompare($1.fileName) == .orderedAscending }
    }

    private func discoverFonts(
        table: [ArchiveEntry],
        bundleRoot: ArchivePath,
        infoDict: [String: Any],
        reader: any ArchiveReader
    ) -> [FontAsset] {
        var fonts: [FontAsset] = []
        let fontExtensions = ["ttf", "otf", "ttc", "dfont"]

        for archiveEntry in table where archiveEntry.kind == .regularFile {
            guard let ap = archiveEntry.path, let bp = BundlePath(ap, relativeTo: bundleRoot) else { continue }
            let name = bp.name ?? bp.rawValue
            let ext = BundleFileClassification.fileExtension(name)

            guard fontExtensions.contains(ext) else { continue }

            // Bounded prefix read for font table
            let prefix = (try? reader.readEntryPrefix(at: ap, maximumBytes: ResourceStudioLimits.fontHeaderPrefixBytes)) ?? Data()
            let metadata = ResourceMetadataParsers.parseFontMetadata(from: prefix, fallbackName: name)

            fonts.append(FontAsset(
                bundlePath: bp,
                fileName: name,
                fileSize: archiveEntry.uncompressedSize,
                format: metadata.format,
                fontName: metadata.postScriptName,
                fontFamily: metadata.familyName,
                style: metadata.style
            ))
        }

        return fonts.sorted { $0.fontFamily.localizedStandardCompare($1.fontFamily) == .orderedAscending }
    }

    private func discoverLocalization(
        table: [ArchiveEntry],
        bundleRoot: ArchivePath,
        reader: any ArchiveReader
    ) -> ([LocalizationLanguageGroup], [LocalizationFileAsset]) {
        var filesByLang: [String: [LocalizationFileAsset]] = [:]
        var lprojPathByLang: [String: BundlePath] = [:]
        var allFiles: [LocalizationFileAsset] = []

        for archiveEntry in table where archiveEntry.kind == .regularFile {
            guard let ap = archiveEntry.path, let bp = BundlePath(ap, relativeTo: bundleRoot) else { continue }
            let name = bp.name ?? bp.rawValue
            let ext = BundleFileClassification.fileExtension(name)

            guard ext == "strings" || ext == "stringsdict" else { continue }

            // Find parent .lproj directory if any
            let parentLproj = bp.components.first { $0.hasSuffix(".lproj") }
            let langCode = parentLproj?.replacingOccurrences(of: ".lproj", with: "") ?? "base"

            let tableName = name.replacingOccurrences(of: ".\(ext)", with: "")

            // Bounded strings parse for key count
            var keyCount = 0
            var sampleEntries: [LocalizationEntry] = []
            if archiveEntry.uncompressedSize <= ResourceStudioLimits.maximumStringsFileBytes,
               let data = try? reader.readEntryData(at: ap, maximumBytes: ResourceStudioLimits.maximumStringsFileBytes) {
                let parsed = ResourceMetadataParsers.parseStringsFile(from: data)
                keyCount = parsed.count
                sampleEntries = Array(parsed.prefix(25))
            }

            let fileAsset = LocalizationFileAsset(
                bundlePath: bp,
                fileName: name,
                fileSize: archiveEntry.uncompressedSize,
                format: ext.uppercased(),
                languageCode: langCode,
                tableName: tableName,
                keyCount: keyCount,
                entries: sampleEntries
            )

            allFiles.append(fileAsset)
            filesByLang[langCode, default: []].append(fileAsset)
            if let parentLproj, let lprojBp = bp.parent {
                lprojPathByLang[langCode] = lprojBp
            }
        }

        let groups = filesByLang.map { langCode, files in
            let displayName = Self.resolveLanguageDisplayName(for: langCode)
            let path = lprojPathByLang[langCode] ?? BundlePath(components: ["\(langCode).lproj"]) ?? .root
            let totalKeys = files.reduce(0) { $0 + $1.keyCount }
            return LocalizationLanguageGroup(
                languageCode: langCode,
                displayName: displayName,
                lprojPath: path,
                files: files.sorted { $0.tableName.localizedStandardCompare($1.tableName) == .orderedAscending },
                totalKeyCount: totalKeys
            )
        }.sorted { (lhs: LocalizationLanguageGroup, rhs: LocalizationLanguageGroup) in
            lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
        }

        return (groups, allFiles)
    }

    private func discoverAudio(
        table: [ArchiveEntry],
        bundleRoot: ArchivePath,
        reader: any ArchiveReader
    ) -> [AudioAsset] {
        var audio: [AudioAsset] = []
        let audioExtensions = ["mp3", "wav", "m4a", "aac", "caf", "aiff", "ogg", "flac"]

        for archiveEntry in table where archiveEntry.kind == .regularFile {
            guard let ap = archiveEntry.path, let bp = BundlePath(ap, relativeTo: bundleRoot) else { continue }
            let name = bp.name ?? bp.rawValue
            let ext = BundleFileClassification.fileExtension(name)

            guard audioExtensions.contains(ext) else { continue }

            var duration: TimeInterval?
            var sampleRate: Double?
            var channels: Int?

            if ext == "wav", let prefix = try? reader.readEntryPrefix(at: ap, maximumBytes: 4096) {
                let meta = ResourceMetadataParsers.parseWAVMetadata(from: prefix)
                duration = meta.duration
                sampleRate = meta.sampleRate
                channels = meta.channels
            }

            audio.append(AudioAsset(
                bundlePath: bp,
                fileName: name,
                fileSize: archiveEntry.uncompressedSize,
                format: ext.uppercased(),
                duration: duration,
                sampleRate: sampleRate,
                channelCount: channels
            ))
        }

        return audio.sorted { $0.fileName.localizedStandardCompare($1.fileName) == .orderedAscending }
    }

    private func discoverVideos(
        table: [ArchiveEntry],
        bundleRoot: ArchivePath,
        reader: any ArchiveReader
    ) -> [VideoAsset] {
        var videos: [VideoAsset] = []
        let videoExtensions = ["mp4", "mov", "m4v", "webm"]

        for archiveEntry in table where archiveEntry.kind == .regularFile {
            guard let ap = archiveEntry.path, let bp = BundlePath(ap, relativeTo: bundleRoot) else { continue }
            let name = bp.name ?? bp.rawValue
            let ext = BundleFileClassification.fileExtension(name)

            guard videoExtensions.contains(ext) else { continue }

            var duration: TimeInterval?
            var width: Int?
            var height: Int?

            if let prefix = try? reader.readEntryPrefix(at: ap, maximumBytes: ResourceStudioLimits.videoHeaderPrefixBytes) {
                let meta = ResourceMetadataParsers.parseMP4Metadata(from: prefix)
                duration = meta.duration
                width = meta.width
                height = meta.height
            }

            videos.append(VideoAsset(
                bundlePath: bp,
                fileName: name,
                fileSize: archiveEntry.uncompressedSize,
                format: ext.uppercased(),
                duration: duration,
                pixelWidth: width,
                pixelHeight: height
            ))
        }

        return videos.sorted { $0.fileName.localizedStandardCompare($1.fileName) == .orderedAscending }
    }

    // MARK: - Utilities

    private func readBundleFile(
        named: String,
        reader: any ArchiveReader,
        bundleRoot: ArchivePath,
        maxBytes: Int
    ) throws -> Data? {
        guard let path = bundleRoot.appending(component: named) else { return nil }
        return try? reader.readEntryData(at: path, maximumBytes: maxBytes)
    }

    static func archivePath(for entry: BundlePath, within bundle: ArchivePath) -> ArchivePath? {
        var path = bundle
        for component in entry.components {
            guard let next = path.appending(component: component) else { return nil }
            path = next
        }
        return path
    }

    public static func resolveLanguageDisplayName(for code: String) -> String {
        if code.lowercased() == "base" { return "Base Localization" }
        let currentLocale = Locale(identifier: "en")
        if let name = currentLocale.localizedString(forIdentifier: code) {
            return name.capitalized
        }
        // Fallback common language names
        switch code.lowercased() {
        case "en": return "English"
        case "fr": return "French"
        case "de": return "German"
        case "ja": return "Japanese"
        case "es": return "Spanish"
        case "it": return "Italian"
        case "zh-hans", "zh_cn": return "Chinese (Simplified)"
        case "zh-hant", "zh_tw": return "Chinese (Traditional)"
        case "ko": return "Korean"
        case "ru": return "Russian"
        case "pt", "pt-br": return "Portuguese"
        case "nl": return "Dutch"
        case "ar": return "Arabic"
        default: return code.uppercased()
        }
    }
}
