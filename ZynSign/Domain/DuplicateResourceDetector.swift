import Foundation

/// One group of duplicate or redundant bundled resources.
public struct DuplicateGroup: Identifiable, Equatable, Hashable, Sendable {

    public let id: String
    public let category: ResourceCategory
    public let reason: String
    public let singleFileSize: Int
    public let fileCount: Int
    public let wastedBytes: Int
    public let paths: [BundlePath]

    public var wastedBytesFormatted: String {
        ByteCountFormatter.string(fromByteCount: Int64(wastedBytes), countStyle: .file)
    }

    public init(
        id: String,
        category: ResourceCategory,
        reason: String,
        singleFileSize: Int,
        paths: [BundlePath]
    ) {
        self.id = id
        self.category = category
        self.reason = reason
        self.singleFileSize = singleFileSize
        self.fileCount = paths.count
        self.wastedBytes = max(0, (paths.count - 1) * singleFileSize)
        self.paths = paths
    }
}

/// The complete duplicate resource analysis of an inspected application bundle.
public struct DuplicateReport: Equatable, Hashable, Sendable {

    public let groups: [DuplicateGroup]
    public let totalDuplicateCount: Int
    public let totalWastedBytes: Int

    public var hasDuplicates: Bool {
        !groups.isEmpty
    }

    public var wastedSpaceFormatted: String {
        ByteCountFormatter.string(fromByteCount: Int64(totalWastedBytes), countStyle: .file)
    }

    public init(groups: [DuplicateGroup] = []) {
        self.groups = groups.sorted { $0.wastedBytes > $1.wastedBytes }
        self.totalDuplicateCount = groups.reduce(0) { $0 + $1.fileCount }
        self.totalWastedBytes = groups.reduce(0) { $0 + $1.wastedBytes }
    }

    public static let empty = DuplicateReport(groups: [])
}

/// Analyzes an imported application bundle to detect redundant and duplicate resources.
public enum DuplicateResourceDetector {

    /// Scans bundled assets and identifies duplicate files, fonts, images, and localizations.
    public static func detect(
        images: [ImageAsset],
        fonts: [FontAsset],
        localizationFiles: [LocalizationFileAsset],
        allEntries: [(path: BundlePath, size: Int)]
    ) -> DuplicateReport {
        var groups: [DuplicateGroup] = []

        // 1. Detect duplicate images (same dimensions + size or same base name & size)
        var imagesByKey: [String: [ImageAsset]] = [:]
        for img in images where img.fileSize > 0 {
            let key: String
            if let dims = img.dimensions {
                key = "\(dims.width)x\(dims.height)_\(img.fileSize)"
            } else {
                key = "\(img.fileName)_\(img.fileSize)"
            }
            imagesByKey[key, default: []].append(img)
        }
        for (key, matches) in imagesByKey where matches.count > 1 {
            let paths = matches.map(\.bundlePath)
            let sample = matches[0]
            let reason: String
            if let dims = sample.dimensions {
                reason = "Identical image dimensions (\(dims.width)×\(dims.height)) and file size"
            } else {
                reason = "Identical image filename and file size"
            }
            groups.append(DuplicateGroup(
                id: "image:\(key)",
                category: .image,
                reason: reason,
                singleFileSize: sample.fileSize,
                paths: paths
            ))
        }

        // 2. Detect duplicate fonts (same font postscript name or font family + style)
        var fontsByName: [String: [FontAsset]] = [:]
        for font in fonts {
            let key = "\(font.fontFamily)_\(font.style)".lowercased()
            fontsByName[key, default: []].append(font)
        }
        for (key, matches) in fontsByName where matches.count > 1 {
            let paths = matches.map(\.bundlePath)
            let sample = matches[0]
            groups.append(DuplicateGroup(
                id: "font:\(key)",
                category: .font,
                reason: "Multiple font files for \(sample.fontFamily) (\(sample.style))",
                singleFileSize: sample.fileSize,
                paths: paths
            ))
        }

        // 3. Detect duplicate localization files (same table name in multiple identical paths or empty strings)
        var locByKey: [String: [LocalizationFileAsset]] = [:]
        for file in localizationFiles where file.fileSize > 0 {
            let key = "\(file.languageCode)_\(file.tableName)_\(file.fileSize)"
            locByKey[key, default: []].append(file)
        }
        for (key, matches) in locByKey where matches.count > 1 {
            let paths = matches.map(\.bundlePath)
            let sample = matches[0]
            groups.append(DuplicateGroup(
                id: "loc:\(key)",
                category: .localization,
                reason: "Duplicate string table \(sample.tableName) in \(sample.languageCode)",
                singleFileSize: sample.fileSize,
                paths: paths
            ))
        }

        // 4. Detect identical files across bundle directories (same filename + same non-zero byte size)
        var entriesByNameAndSize: [String: [(path: BundlePath, size: Int)]] = [:]
        for entry in allEntries where entry.size > 2048 { // threshold: > 2 KB
            let key = "\(entry.path.name ?? "")_\(entry.size)"
            entriesByNameAndSize[key, default: []].append(entry)
        }
        for (key, matches) in entriesByNameAndSize where matches.count > 1 {
            let paths = matches.map(\.path)
            let alreadyGrouped = groups.contains { g in
                Set(g.paths).intersection(Set(paths)).count > 1
            }
            if !alreadyGrouped {
                let sample = matches[0]
                groups.append(DuplicateGroup(
                    id: "file:\(key)",
                    category: .other,
                    reason: "Identical filename and size across multiple directories",
                    singleFileSize: sample.size,
                    paths: paths
                ))
            }
        }

        return DuplicateReport(groups: groups)
    }
}
