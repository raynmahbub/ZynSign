import Foundation

/// Fast in-memory search index for all bundled application resources.
///
/// Search spans filenames, extensions, localization keys and language names,
/// font families and styles, image dimensions, and media formats.
public final class ResourceSearchIndex: @unchecked Sendable {

    public struct IndexedEntry: @unchecked Sendable {
        public let item: any ResourceItem
        public let searchableText: String
        public let category: ResourceCategory
        public let fileSize: Int
    }

    private let entries: [IndexedEntry]

    public init(
        icons: [AppIconAsset] = [],
        launchImages: [ImageAsset] = [],
        images: [ImageAsset] = [],
        fonts: [FontAsset] = [],
        localizationFiles: [LocalizationFileAsset] = [],
        audio: [AudioAsset] = [],
        videos: [VideoAsset] = []
    ) {
        var list: [IndexedEntry] = []

        // Icons
        for icon in icons {
            let tokens = [
                icon.fileName,
                icon.bundlePath.rawValue,
                icon.format,
                icon.iconSetName,
                icon.roleDescription,
                icon.dimensionsDescription,
                icon.idiom ?? "",
                "icon"
            ]
            list.append(IndexedEntry(
                item: icon,
                searchableText: tokens.joined(separator: " ").lowercased(),
                category: .icon,
                fileSize: icon.fileSize
            ))
        }

        // Launch Images
        for launch in launchImages {
            let tokens = [
                launch.fileName,
                launch.bundlePath.rawValue,
                launch.format,
                launch.dimensionsDescription,
                "launch",
                "launchimage"
            ]
            list.append(IndexedEntry(
                item: launch,
                searchableText: tokens.joined(separator: " ").lowercased(),
                category: .launch,
                fileSize: launch.fileSize
            ))
        }

        // Images
        for img in images {
            let tokens = [
                img.fileName,
                img.bundlePath.rawValue,
                img.format,
                img.dimensionsDescription,
                img.tag ?? "",
                "image",
                "photo"
            ]
            list.append(IndexedEntry(
                item: img,
                searchableText: tokens.joined(separator: " ").lowercased(),
                category: img.category,
                fileSize: img.fileSize
            ))
        }

        // Fonts
        for font in fonts {
            let tokens = [
                font.fileName,
                font.bundlePath.rawValue,
                font.fontName,
                font.fontFamily,
                font.style,
                font.format,
                "font",
                "typeface"
            ]
            list.append(IndexedEntry(
                item: font,
                searchableText: tokens.joined(separator: " ").lowercased(),
                category: .font,
                fileSize: font.fileSize
            ))
        }

        // Localization
        for loc in localizationFiles {
            var tokens = [
                loc.fileName,
                loc.bundlePath.rawValue,
                loc.tableName,
                loc.languageCode,
                loc.format,
                "localization",
                "strings"
            ]
            // Include top keys in search index
            for entry in loc.entries.prefix(50) {
                tokens.append(entry.key)
                tokens.append(entry.value)
            }
            list.append(IndexedEntry(
                item: loc,
                searchableText: tokens.joined(separator: " ").lowercased(),
                category: .localization,
                fileSize: loc.fileSize
            ))
        }

        // Audio
        for a in audio {
            let tokens = [
                a.fileName,
                a.bundlePath.rawValue,
                a.format,
                a.durationFormatted,
                "audio",
                "sound",
                "music"
            ]
            list.append(IndexedEntry(
                item: a,
                searchableText: tokens.joined(separator: " ").lowercased(),
                category: .audio,
                fileSize: a.fileSize
            ))
        }

        // Videos
        for v in videos {
            let tokens = [
                v.fileName,
                v.bundlePath.rawValue,
                v.format,
                v.durationFormatted,
                v.resolutionDescription,
                "video",
                "movie"
            ]
            list.append(IndexedEntry(
                item: v,
                searchableText: tokens.joined(separator: " ").lowercased(),
                category: .video,
                fileSize: v.fileSize
            ))
        }

        self.entries = list
    }

    /// Performs an instant combined query and filter search.
    public func search(query: String, filter: ResourceFilter = .all, limit: Int = 300) -> [any ResourceItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let tokens = trimmed.isEmpty ? [] : trimmed.components(separatedBy: .whitespaces).filter { !$0.isEmpty }

        var results: [any ResourceItem] = []
        for entry in entries {
            // Check filter
            guard filter.matches(category: entry.category, fileSize: entry.fileSize) else {
                continue
            }

            // Check query tokens
            if !tokens.isEmpty {
                let matchesAll = tokens.allSatisfy { token in
                    entry.searchableText.contains(token)
                }
                guard matchesAll else { continue }
            }

            results.append(entry.item)
            if results.count >= limit {
                break
            }
        }
        return results
    }

    public static let empty = ResourceSearchIndex()
}
