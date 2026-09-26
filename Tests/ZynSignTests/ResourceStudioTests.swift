import XCTest
@testable import ZynSign

final class ResourceStudioTests: XCTestCase {

    // MARK: - Categories & Filters

    func testResourceCategoryProperties() {
        XCTAssertEqual(ResourceCategory.icon.displayName, "Icons")
        XCTAssertEqual(ResourceCategory.launch.displayName, "Launch Assets")
        XCTAssertEqual(ResourceCategory.image.displayName, "Images")
        XCTAssertEqual(ResourceCategory.font.displayName, "Fonts")
        XCTAssertEqual(ResourceCategory.audio.displayName, "Audio")
        XCTAssertEqual(ResourceCategory.video.displayName, "Videos")
        XCTAssertEqual(ResourceCategory.localization.displayName, "Localization Files")
        XCTAssertEqual(ResourceCategory.other.displayName, "Other Resources")

        XCTAssertFalse(ResourceCategory.icon.systemImage.isEmpty)
        XCTAssertFalse(ResourceCategory.font.systemImage.isEmpty)
    }

    func testResourceFilterMatching() {
        let allFilter = ResourceFilter.all
        XCTAssertTrue(allFilter.matches(category: .image, fileSize: 100))
        XCTAssertTrue(allFilter.matches(category: .font, fileSize: 200))

        let imageFilter = ResourceFilter.images
        XCTAssertTrue(imageFilter.matches(category: .image, fileSize: 100))
        XCTAssertTrue(imageFilter.matches(category: .icon, fileSize: 100))
        XCTAssertTrue(imageFilter.matches(category: .launch, fileSize: 100))
        XCTAssertFalse(imageFilter.matches(category: .audio, fileSize: 100))

        let fontFilter = ResourceFilter.fonts
        XCTAssertTrue(fontFilter.matches(category: .font, fileSize: 100))
        XCTAssertFalse(fontFilter.matches(category: .image, fileSize: 100))

        let largeFilter = ResourceFilter.largeFiles
        XCTAssertTrue(largeFilter.matches(category: .video, fileSize: 2_000_000, largeFileThreshold: 1_000_000))
        XCTAssertFalse(largeFilter.matches(category: .video, fileSize: 500_000, largeFileThreshold: 1_000_000))
    }

    func testResourceSummaryCounts() {
        let summary = ResourceSummary(
            iconCount: 5,
            launchAssetCount: 2,
            imageCount: 20,
            fontCount: 4,
            audioCount: 3,
            videoCount: 1,
            localizationCount: 8,
            totalResourceCount: 43,
            totalByteCount: 10_000_000,
            duplicateCount: 3,
            wastedDuplicateBytes: 500_000
        )

        XCTAssertEqual(summary[.icon], 5)
        XCTAssertEqual(summary[.launch], 2)
        XCTAssertEqual(summary[.image], 20)
        XCTAssertEqual(summary[.font], 4)
        XCTAssertEqual(summary[.audio], 3)
        XCTAssertEqual(summary[.video], 1)
        XCTAssertEqual(summary[.localization], 8)
        XCTAssertEqual(summary.totalResourceCount, 43)
        XCTAssertEqual(summary.duplicateCount, 3)
        XCTAssertEqual(summary.wastedDuplicateBytes, 500_000)
    }

    // MARK: - Metadata Parsers

    func testPNGDimensionParser() {
        // Construct synthetic valid PNG header with IHDR chunk: 100 x 200 px
        var data = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) // Signature (8 bytes)
        // IHDR chunk: length (4 bytes: 13), type (4 bytes: 'IHDR'), width (4 bytes: 100), height (4 bytes: 200), ...
        data.append(contentsOf: [0x00, 0x00, 0x00, 0x0D]) // Length 13
        data.append(contentsOf: [0x49, 0x48, 0x44, 0x52]) // 'IHDR'
        data.append(contentsOf: [0x00, 0x00, 0x00, 0x64]) // Width: 100
        data.append(contentsOf: [0x00, 0x00, 0x00, 0xC8]) // Height: 200
        data.append(contentsOf: [0x08, 0x06, 0x00, 0x00, 0x00]) // bit depth, color type, etc.

        let dims = ResourceMetadataParsers.parsePNGDimensions(from: data)
        XCTAssertNotNil(dims)
        XCTAssertEqual(dims?.width, 100)
        XCTAssertEqual(dims?.height, 200)
        XCTAssertEqual(dims?.format, "PNG")
    }

    func testJPEGDimensionParser() {
        // Construct synthetic JPEG with SOF0 marker: width 640, height 480
        var data = Data([0xFF, 0xD8]) // SOI
        // SOF0 marker (0xFF, 0xC0)
        data.append(contentsOf: [0xFF, 0xC0])
        data.append(contentsOf: [0x00, 0x11]) // Length: 17
        data.append(0x08) // Precision: 8
        data.append(contentsOf: [0x01, 0xE0]) // Height: 480
        data.append(contentsOf: [0x02, 0x80]) // Width: 640
        data.append(contentsOf: [0x03, 0x01, 0x11, 0x00, 0x02, 0x11, 0x01, 0x03, 0x11, 0x01])

        let dims = ResourceMetadataParsers.parseJPEGDimensions(from: data)
        XCTAssertNotNil(dims)
        XCTAssertEqual(dims?.width, 640)
        XCTAssertEqual(dims?.height, 480)
        XCTAssertEqual(dims?.format, "JPEG")
    }

    func testGIFDimensionParser() {
        // GIF89a with width 320, height 240 (little endian)
        var data = Data("GIF89a".utf8)
        data.append(contentsOf: [0x40, 0x01]) // Width: 320
        data.append(contentsOf: [0xF0, 0x00]) // Height: 240

        let dims = ResourceMetadataParsers.parseGIFDimensions(from: data)
        XCTAssertNotNil(dims)
        XCTAssertEqual(dims?.width, 320)
        XCTAssertEqual(dims?.height, 240)
        XCTAssertEqual(dims?.format, "GIF")
    }

    func testFontFallbackMetadata() {
        let data = Data([0x00, 0x01, 0x00, 0x00]) // truncated TTF header
        let meta = ResourceMetadataParsers.parseFontMetadata(from: data, fallbackName: "Roboto-Bold.ttf")
        XCTAssertEqual(meta.familyName, "Roboto")
        XCTAssertEqual(meta.style, "Bold")
        XCTAssertEqual(meta.format, "TTF")
    }

    func testWAVHeaderParser() {
        // Construct synthetic WAV header: sampleRate 44100, channels 2, byteRate 176400, data size 352800 (2.0s)
        var data = Data([0x52, 0x49, 0x46, 0x46]) // 'RIFF'
        data.append(contentsOf: [0x00, 0x00, 0x00, 0x00]) // size placeholder
        data.append(contentsOf: [0x57, 0x41, 0x56, 0x45]) // 'WAVE'
        data.append(contentsOf: [0x66, 0x6D, 0x74, 0x20]) // 'fmt '
        data.append(contentsOf: [0x10, 0x00, 0x00, 0x00]) // Subchunk1Size: 16
        data.append(contentsOf: [0x01, 0x00]) // AudioFormat: 1 (PCM)
        data.append(contentsOf: [0x02, 0x00]) // NumChannels: 2
        data.append(contentsOf: [0x44, 0xAC, 0x00, 0x00]) // SampleRate: 44100
        data.append(contentsOf: [0x10, 0xB1, 0x02, 0x00]) // ByteRate: 176400
        data.append(contentsOf: [0x04, 0x00]) // BlockAlign: 4
        data.append(contentsOf: [0x10, 0x00]) // BitsPerSample: 16
        data.append(contentsOf: [0x64, 0x61, 0x74, 0x61]) // 'data'
        data.append(contentsOf: [0x20, 0x62, 0x05, 0x00]) // Subchunk2Size: 352800

        let parsed = ResourceMetadataParsers.parseWAVMetadata(from: data)
        XCTAssertNotNil(parsed.duration)
        XCTAssertEqual(parsed.duration, 2.0, accuracy: 0.05)
        XCTAssertEqual(parsed.channels, 2)
        XCTAssertEqual(parsed.sampleRate, 44100)
    }

    func testStringsFileParser() {
        let text = """
        /* Main application greeting */
        "WELCOME_TITLE" = "Welcome to ZynSign";
        // Prompt for file import
        "IMPORT_BUTTON" = "Import Package";
        "VERSION_LABEL" = "v1.0.0";
        """
        let data = Data(text.utf8)
        let entries = ResourceMetadataParsers.parseStringsFile(from: data)

        XCTAssertEqual(entries.count, 3)
        let keys = entries.map(\.key)
        XCTAssertTrue(keys.contains("WELCOME_TITLE"))
        XCTAssertTrue(keys.contains("IMPORT_BUTTON"))
        XCTAssertTrue(keys.contains("VERSION_LABEL"))

        let welcome = entries.first { $0.key == "WELCOME_TITLE" }
        XCTAssertEqual(welcome?.value, "Welcome to ZynSign")
    }

    // MARK: - Duplicate Detection

    func testDuplicateResourceDetection() {
        let p1 = BundlePath(components: ["Assets", "icon_1.png"])!
        let p2 = BundlePath(components: ["Backup", "icon_1.png"])!
        let p3 = BundlePath(components: ["Fonts", "CustomFont.ttf"])!
        let p4 = BundlePath(components: ["OldFonts", "CustomFont.ttf"])!

        let img1 = ImageAsset(bundlePath: p1, fileName: "icon_1.png", fileSize: 50_000, format: "PNG", pixelWidth: 120, pixelHeight: 120)
        let img2 = ImageAsset(bundlePath: p2, fileName: "icon_1.png", fileSize: 50_000, format: "PNG", pixelWidth: 120, pixelHeight: 120)

        let font1 = FontAsset(bundlePath: p3, fileName: "CustomFont.ttf", fileSize: 80_000, format: "TTF", fontName: "Custom-Regular", fontFamily: "CustomFont", style: "Regular")
        let font2 = FontAsset(bundlePath: p4, fileName: "CustomFont.ttf", fileSize: 80_000, format: "TTF", fontName: "Custom-Regular", fontFamily: "CustomFont", style: "Regular")

        let report = DuplicateResourceDetector.detect(
            images: [img1, img2],
            fonts: [font1, font2],
            localizationFiles: [],
            allEntries: [(p1, 50_000), (p2, 50_000), (p3, 80_000), (p4, 80_000)]
        )

        XCTAssertTrue(report.hasDuplicates)
        XCTAssertEqual(report.groups.count, 2)
        XCTAssertEqual(report.totalDuplicateCount, 4)
        XCTAssertEqual(report.totalWastedBytes, 130_000) // (2-1)*50000 + (2-1)*80000
    }

    // MARK: - Asset Relationships

    func testAssetRelationshipsGrouping() {
        let p1 = BundlePath(components: ["AppIcon60x60@2x.png"])!
        let p2 = BundlePath(components: ["AppIcon60x60@3x.png"])!
        let p3 = BundlePath(components: ["Fonts", "Sans-Regular.ttf"])!
        let p4 = BundlePath(components: ["Fonts", "Sans-Bold.ttf"])!
        let p5 = BundlePath(components: ["en.lproj", "Localizable.strings"])!
        let p6 = BundlePath(components: ["fr.lproj", "Localizable.strings"])!

        let icon1 = AppIconAsset(bundlePath: p1, fileName: "AppIcon60x60@2x.png", fileSize: 10_000, isPrimary: true, iconSetName: "Primary", pixelWidth: 120, pixelHeight: 120)
        let icon2 = AppIconAsset(bundlePath: p2, fileName: "AppIcon60x60@3x.png", fileSize: 15_000, isPrimary: true, iconSetName: "Primary", pixelWidth: 180, pixelHeight: 180)

        let font1 = FontAsset(bundlePath: p3, fileName: "Sans-Regular.ttf", fileSize: 40_000, format: "TTF", fontName: "Sans-Regular", fontFamily: "Sans", style: "Regular")
        let font2 = FontAsset(bundlePath: p4, fileName: "Sans-Bold.ttf", fileSize: 45_000, format: "TTF", fontName: "Sans-Bold", fontFamily: "Sans", style: "Bold")

        let loc1 = LocalizationFileAsset(bundlePath: p5, fileName: "Localizable.strings", fileSize: 2_000, format: "STRINGS", languageCode: "en", tableName: "Localizable", keyCount: 50)
        let loc2 = LocalizationFileAsset(bundlePath: p6, fileName: "Localizable.strings", fileSize: 2_200, format: "STRINGS", languageCode: "fr", tableName: "Localizable", keyCount: 50)

        let relationships = AssetRelationshipGrouper.group(
            icons: [icon1, icon2],
            launch: LaunchScreenAsset.empty,
            localizations: [loc1, loc2],
            fonts: [font1, font2]
        )

        XCTAssertEqual(relationships.iconSets.count, 1)
        XCTAssertEqual(relationships.iconSets.first?.icons.count, 2)

        XCTAssertEqual(relationships.fontFamilies.count, 1)
        XCTAssertEqual(relationships.fontFamilies.first?.familyName, "Sans")
        XCTAssertEqual(relationships.fontFamilies.first?.fonts.count, 2)

        XCTAssertEqual(relationships.localizationTables.count, 1)
        XCTAssertEqual(relationships.localizationTables.first?.tableName, "Localizable")
        XCTAssertEqual(relationships.localizationTables.first?.languages, ["en", "fr"])
    }

    // MARK: - Search Index

    func testResourceSearchIndex() {
        let p1 = BundlePath(components: ["AppIcon60x60@2x.png"])!
        let p2 = BundlePath(components: ["background.png"])!
        let p3 = BundlePath(components: ["audio.mp3"])!
        let p4 = BundlePath(components: ["video.mp4"])!
        let p5 = BundlePath(components: ["CustomFont.otf"])!

        let icon = AppIconAsset(bundlePath: p1, fileName: "AppIcon60x60@2x.png", fileSize: 10_000, isPrimary: true)
        let img = ImageAsset(bundlePath: p2, fileName: "background.png", fileSize: 2_000_000, format: "PNG", category: .image)
        let audio = AudioAsset(bundlePath: p3, fileName: "audio.mp3", fileSize: 300_000, format: "MP3", duration: 45.0)
        let video = VideoAsset(bundlePath: p4, fileName: "video.mp4", fileSize: 5_000_000, format: "MP4", duration: 120.0, pixelWidth: 1920, pixelHeight: 1080)
        let font = FontAsset(bundlePath: p5, fileName: "CustomFont.otf", fileSize: 60_000, format: "OTF", fontName: "Custom-Bold", fontFamily: "CustomFont", style: "Bold")

        let index = ResourceSearchIndex(
            icons: [icon],
            images: [img],
            fonts: [font],
            audio: [audio],
            videos: [video]
        )

        // Query test
        let resultsAudio = index.search(query: "audio")
        XCTAssertEqual(resultsAudio.count, 1)
        XCTAssertEqual(resultsAudio.first?.fileName, "audio.mp3")

        // Filter test
        let resultsLarge = index.search(query: "", filter: .largeFiles)
        XCTAssertEqual(resultsLarge.count, 2) // img (2MB) and video (5MB)

        let resultsFonts = index.search(query: "Custom", filter: .fonts)
        XCTAssertEqual(resultsFonts.count, 1)
        XCTAssertEqual(resultsFonts.first?.fileName, "CustomFont.otf")
    }

    // MARK: - Quick Summary from BundleContents

    func testQuickSummaryComputation() {
        let table = [
            ArchiveEntry(path: ArchivePath("Payload/App.app/AppIcon60x60@2x.png")!, kind: .regularFile, uncompressedSize: 10_000),
            ArchiveEntry(path: ArchivePath("Payload/App.app/LaunchImage.png")!, kind: .regularFile, uncompressedSize: 20_000),
            ArchiveEntry(path: ArchivePath("Payload/App.app/photo.jpg")!, kind: .regularFile, uncompressedSize: 100_000),
            ArchiveEntry(path: ArchivePath("Payload/App.app/font.ttf")!, kind: .regularFile, uncompressedSize: 40_000),
            ArchiveEntry(path: ArchivePath("Payload/App.app/sound.wav")!, kind: .regularFile, uncompressedSize: 80_000),
            ArchiveEntry(path: ArchivePath("Payload/App.app/movie.mp4")!, kind: .regularFile, uncompressedSize: 500_000),
            ArchiveEntry(path: ArchivePath("Payload/App.app/en.lproj/Localizable.strings")!, kind: .regularFile, uncompressedSize: 5_000),
            ArchiveEntry(path: ArchivePath("Payload/App.app/en.lproj")!, kind: .directory)
        ]

        let contents = BundleContents(entryTable: table, bundlePath: ArchivePath("Payload/App.app")!)
        let inspection = IPAResourceStudioInspection(
            library: MockResourceLibrary(),
            readerProvider: MockResourceReaderProvider()
        )

        let summary = inspection.quickSummary(from: contents)
        XCTAssertEqual(summary.iconCount, 1)
        XCTAssertEqual(summary.launchAssetCount, 1)
        XCTAssertEqual(summary.imageCount, 1)
        XCTAssertEqual(summary.fontCount, 1)
        XCTAssertEqual(summary.audioCount, 1)
        XCTAssertEqual(summary.videoCount, 1)
        XCTAssertEqual(summary.localizationCount, 2) // en.lproj dir + Localizable.strings
        XCTAssertEqual(summary.totalResourceCount, 8)
    }

    // MARK: - Read Bounds & Limits

    func testResourceLimits() {
        XCTAssertEqual(ResourceStudioLimits.imageHeaderPrefixBytes, 4 * 1024)
        XCTAssertEqual(ResourceStudioLimits.maximumImagePreviewBytes, 12 * 1024 * 1024)
        XCTAssertEqual(ResourceStudioLimits.fontHeaderPrefixBytes, 64 * 1024)
        XCTAssertEqual(ResourceStudioLimits.maximumFontRegistrationBytes, 16 * 1024 * 1024)
        XCTAssertEqual(ResourceStudioLimits.maximumStringsFileBytes, 2 * 1024 * 1024)
        XCTAssertEqual(ResourceStudioLimits.maximumAudioPlaybackBytes, 32 * 1024 * 1024)
        XCTAssertEqual(ResourceStudioLimits.maximumVideoPlaybackBytes, 64 * 1024 * 1024)
    }
}

// MARK: - Test Mocks

private final class MockResourceLibrary: ApplicationLibrary, @unchecked Sendable {
    func entry(withID id: ApplicationRecordIdentifier) async throws -> LibraryEntry? { nil }
    func allEntries() async throws -> [LibraryEntry] { [] }
    func addOrUpdate(entry: LibraryEntry) async throws {}
    func remove(id: ApplicationRecordIdentifier) async throws -> LibraryEntry? { nil }
    func contains(id: ApplicationRecordIdentifier) async throws -> Bool { false }
}

private final class MockResourceReaderProvider: ArtifactArchiveReaderProvider, @unchecked Sendable {
    func archiveReader(for artifactID: ArtifactIdentifier) throws -> any ArchiveReader {
        MockArchiveReader()
    }
}

private final class MockArchiveReader: ArchiveReader {
    func readEntryTable() throws -> [ArchiveEntry] { [] }
    func containsEntry(at path: ArchivePath) throws -> Bool { false }
    func entryKind(at path: ArchivePath) throws -> ArchiveEntryKind? { nil }
    func readEntryData(at path: ArchivePath, maximumBytes: Int) throws -> Data { Data() }
    func readEntryPrefix(at path: ArchivePath, maximumBytes: Int) throws -> Data { Data() }
    func close() {}
}
