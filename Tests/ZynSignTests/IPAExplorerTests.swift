import XCTest
@testable import ZynSign

/// Read-only IPA explorer behavior: classification, counts, search, the
/// visible tree, bounded Mach-O facts, and on-demand entry previews.
///
/// Fixtures are synthetic. No test reads a real package, and none asserts
/// that a signature, profile, or executable is trusted or installable.
final class IPAExplorerTests: XCTestCase {

    private let bundleRoot = "Payload/Example.app"

    // MARK: - Classification

    func testClassificationLabelsKnownKindsAndKeepsUnknownFiles() {
        XCTAssertEqual(classify("Info.plist"), .metadata)
        XCTAssertEqual(classify("info.plist"), .propertyList)
        XCTAssertEqual(classify("embedded.mobileprovision"), .provisioningProfile)
        XCTAssertEqual(classify("Example", role: .executable), .executable)
        XCTAssertEqual(classify("Frameworks/Core.framework/Core"), .executable)
        XCTAssertEqual(classify("PlugIns/Share.appex/Share"), .executable)
        XCTAssertEqual(classify("Vendor.dylib"), .executable)
        XCTAssertEqual(classify("Frameworks/Core.framework", kind: .directory), .framework)
        XCTAssertEqual(classify("PlugIns/Share.appex", kind: .directory), .appExtension)
        XCTAssertEqual(classify("Icon.PNG"), .image)
        XCTAssertEqual(classify("config.json"), .text)
        XCTAssertEqual(classify("notes.xml"), .text)
        XCTAssertEqual(classify("Settings.plist"), .propertyList)
        XCTAssertEqual(classify("en.lproj", kind: .directory), .localization)
        XCTAssertEqual(classify("Link", kind: .symbolicLink), .symbolicLink)
        XCTAssertEqual(classify("mystery.bin"), .generic)
        XCTAssertEqual(BundleFileClassification.recognize(entry("mystery.bin")).displayName, "Generic file")
    }

    func testUnknownFilesRemainListed() {
        let contents = contents([
            file("Info.plist", bytes: Data("plist".utf8)),
            file("mystery.bin", bytes: Data([0x00, 0x01])),
        ])
        XCTAssertNotNil(contents.entry(at: path("mystery.bin")))
        XCTAssertEqual(classify(contents.entry(at: path("mystery.bin"))!), .generic)
    }

    // MARK: - Statistics

    func testStatisticsCountStructureWithoutReadingBytes() {
        let contents = sampleContents()
        let statistics = BundleStatistics(contents: contents)
        XCTAssertEqual(statistics.frameworks, 1)
        XCTAssertEqual(statistics.extensions, 1)
        XCTAssertEqual(statistics.executables, 3)
        XCTAssertEqual(statistics.images, 1)
        XCTAssertEqual(statistics.totalFiles, 7)
        XCTAssertEqual(statistics.bundleSize, contents.totalDeclaredByteCount)
        XCTAssertGreaterThan(statistics.bundleSize, 0)
    }

    // MARK: - Search

    func testSearchRanksNameMatchesAndHighlightsTheOriginalString() {
        let contents = contents([
            file("png", bytes: Data([0x01])),
            file("pngfile", bytes: Data([0x01])),
            file("file.png", bytes: Data([0x01])),
            directory("pngdir"),
            file("pngdir/other", bytes: Data([0x01])),
            file("Icon.PNG", bytes: Data([0x01])),
            file("Café.txt", bytes: Data("café".utf8)),
        ])
        let result = BundleSearchIndex(contents: contents).search("png")
        XCTAssertEqual(result.matches.map(\.name), ["png", "pngdir", "pngfile", "Icon.PNG", "file.png", "other"])
        XCTAssertEqual(result.matches.map(\.field), [.name, .name, .name, .name, .name, .folder])
        let icon = result.matches.first { $0.name == "Icon.PNG" }
        XCTAssertEqual(icon?.highlight, ExplorerHighlight(start: 5, length: 3))
        let highlighted = icon?.highlight?.range(in: "Icon.PNG").map { String("Icon.PNG"[$0]) }
        XCTAssertEqual(highlighted, "PNG")

        let accented = BundleSearchIndex(contents: contents).search("cafe")
        XCTAssertEqual(accented.matches.map(\.name), ["Café.txt"])
        XCTAssertEqual(accented.matches.first?.highlight?.range(in: "Café.txt").map { String("Café.txt"[$0]) }, "Café")
    }

    func testSearchMatchesOnlyTheImmediateParentAndCapsTheDisplay() {
        let nested = contents([
            directory("Frameworks"),
            directory("Frameworks/Core.framework"),
            file("Frameworks/Core.framework/Info.plist", bytes: Data("x".utf8)),
        ])
        let folder = BundleSearchIndex(contents: nested).search("Frameworks")
        XCTAssertEqual(Set(folder.matches.map(\.name)), ["Frameworks", "Core.framework"])

        var many: [ArchiveEntry] = []
        for index in 0..<201 {
            many.append(file(String(format: "hit-%03d", index), bytes: Data([0x01])))
        }
        let capped = BundleSearchIndex(contents: contents(many)).search("hit", limit: 200)
        XCTAssertEqual(capped.matches.count, 200)
        XCTAssertEqual(capped.totalMatchCount, 201)
        XCTAssertTrue(capped.isTruncated)
        XCTAssertEqual(BundleSearchIndex(contents: nested).search("   "), .empty)
    }

    // MARK: - Tree

    func testTheTreeRendersOnlyExpandedRowsAndPagesLargeFolders() {
        var entries = [directory("Frameworks"), file("Frameworks/Core.framework/Core", bytes: Data([0x90]))]
        for index in 0..<201 {
            entries.append(file(String(format: "item-%03d", index), bytes: Data([0x01])))
        }
        let tree = contents(entries)
        let collapsed = ExplorerTreeProjection.visibleItems(contents: tree, expanded: [], windows: [:])
        XCTAssertEqual(collapsed.map(\.id), ["row-payload"])

        let visible = ExplorerTreeProjection.visibleItems(
            contents: tree,
            expanded: [.payload, .application],
            windows: [:]
        )
        let rows = visible.compactMap { item -> ExplorerTreeRow? in
            if case .row(let row) = item { return row }
            return nil
        }
        XCTAssertEqual(rows.first?.name, "Payload")
        XCTAssertEqual(rows.dropFirst().first?.name, "Example.app")
        XCTAssertFalse(rows.contains { $0.name == "Core" })
        XCTAssertEqual(rows.filter { $0.depth == 2 }.count, ExplorerTreeProjection.pageSize)
        guard case .showMore(let parent, let hidden) = visible.last else {
            return XCTFail("Expected a show-more item")
        }
        XCTAssertEqual(parent, .application)
        XCTAssertEqual(hidden, 2)

        let target = path("item-200")
        let revealed = ExplorerTreeProjection.revealedExpansion(of: .entry(target), existing: [])
        XCTAssertTrue(revealed.contains(.payload))
        XCTAssertTrue(revealed.contains(.application))
        let window = ExplorerTreeProjection.windowNeeded(toShow: .entry(target), contents: tree)
        XCTAssertEqual(window?.0, .application)
        XCTAssertEqual(window?.1, 400)
        let nested = path("Frameworks/Core.framework/Core")
        let nestedExpansion = ExplorerTreeProjection.revealedExpansion(of: .entry(nested), existing: [])
        XCTAssertTrue(nestedExpansion.contains(.entry(path("Frameworks"))))
        XCTAssertTrue(nestedExpansion.contains(.entry(path("Frameworks/Core.framework"))))
        XCTAssertFalse(nestedExpansion.contains(.entry(nested)))
    }

    func testQuickActionsDoNotEditAndCopyThePackageRelativePath() {
        XCTAssertFalse(ExplorerQuickAction.exposesEditing)
        XCTAssertEqual(
            Set(ExplorerQuickAction.allCases.map(\.rawValue)),
            ["View Details", "Reveal in Tree", "Copy Path", "Copy Filename"]
        )
        let location = ExplorerLocation.displayPath(bundleName: "Example.app", entry: path("Info.plist"))
        XCTAssertEqual(location, "Payload/Example.app/Info.plist")
        XCTAssertFalse(location.contains("://"))
        XCTAssertFalse(location.hasPrefix("/"))
    }

    func testResourceFilterKeepsPreviewableResourcesOnly() {
        XCTAssertEqual(ExplorerResourceFilter.reason(for: entry("Icon.png")), "Image")
        XCTAssertEqual(ExplorerResourceFilter.reason(for: entry("config.json")), "JSON")
        XCTAssertEqual(ExplorerResourceFilter.reason(for: entry("notes.xml")), "XML")
        XCTAssertEqual(ExplorerResourceFilter.reason(for: entry("en.lproj", kind: .directory)), "Localization")
        XCTAssertEqual(ExplorerResourceFilter.reason(for: entry("LaunchScreen.storyboardc", kind: .directory)), "Launch asset")
        XCTAssertNil(ExplorerResourceFilter.reason(for: entry("mystery.bin")))
    }

    func testExtensionKindsFollowTheDeclaredPointIdentifier() {
        XCTAssertEqual(ExplorerExtensionKind.recognize(pointIdentifier: "com.apple.share-services"), .share)
        XCTAssertEqual(ExplorerExtensionKind.recognize(pointIdentifier: "com.apple.widgetkit-extension"), .widget)
        XCTAssertEqual(ExplorerExtensionKind.recognize(pointIdentifier: "com.apple.widget-extension"), .widget)
        XCTAssertEqual(ExplorerExtensionKind.recognize(pointIdentifier: "com.apple.usernotifications.content-extension"), .notification)
        XCTAssertEqual(ExplorerExtensionKind.recognize(pointIdentifier: "com.apple.usernotifications.service"), .notification)
        XCTAssertEqual(ExplorerExtensionKind.recognize(pointIdentifier: "com.example.other"), .other(pointIdentifier: "com.example.other"))
        XCTAssertEqual(ExplorerExtensionKind.recognize(pointIdentifier: nil), .other(pointIdentifier: nil))
    }

    // MARK: - Mach-O prefix

    func testMachOPrefixReportsHeaderFactsWithoutGuessingATruncatedImage() {
        let image = MachOFixtures.thin(
            subtype: 2,
            commands: [encryptionCommand(cryptid: 1), MachOFixtures.command(0x1D, size: 16)]
        )
        let report = MachOPrefixInspector.inspect(prefix: Data(image), declaredByteCount: image.count, checksumVerified: true)
        let slice = try? XCTUnwrap(report?.slices.first)
        XCTAssertEqual(slice?.architectureName, "arm64e")
        XCTAssertEqual(slice?.fileTypeName, "Executable")
        XCTAssertEqual(slice?.loadCommandCount, 2)
        XCTAssertEqual(slice?.encryption, .encrypted(cryptid: 1))
        XCTAssertEqual(slice?.signature, .commandPresent)
        XCTAssertEqual(report?.encryptionSummary, .encrypted(cryptid: 1))
        XCTAssertTrue(report?.note.contains("not evidence") ?? false)

        let clear = MachOFixtures.thin(commands: [encryptionCommand(cryptid: 0)])
        XCTAssertEqual(
            MachOPrefixInspector.inspect(prefix: Data(clear), declaredByteCount: clear.count, checksumVerified: true)?.slices.first?.encryption,
            .notEncrypted
        )
        let absent = MachOFixtures.thin(commands: [MachOFixtures.command(0x1D, size: 16)])
        XCTAssertEqual(
            MachOPrefixInspector.inspect(prefix: Data(absent), declaredByteCount: absent.count, checksumVerified: true)?.slices.first?.encryption,
            .commandAbsent
        )
        XCTAssertEqual(
            MachOPrefixInspector.inspect(prefix: Data(absent), declaredByteCount: absent.count, checksumVerified: true)?.slices.first?.signature,
            .commandPresent
        )

        var truncated = [UInt8](repeating: 0, count: 4)
        MachOFixtures.put(0xFEEDFACF, at: 0, in: &truncated, order: .littleEndian)
        let partial = MachOPrefixInspector.inspect(prefix: Data(truncated), declaredByteCount: 4, checksumVerified: true)
        XCTAssertEqual(partial?.slices.first?.encryption, .unreadable)
        XCTAssertNil(MachOPrefixInspector.inspect(prefix: Data([0x00, 0x01, 0x02, 0x03]), declaredByteCount: 4, checksumVerified: true))
    }

    func testAFatSlicePastThePrefixIsNamedAndNotInvented() {
        var bytes = [UInt8](repeating: 0, count: 28)
        MachOFixtures.put(0xCAFEBABE, at: 0, in: &bytes)
        MachOFixtures.put(1, at: 4, in: &bytes)
        MachOFixtures.put(0x0100_000C, at: 8, in: &bytes)
        MachOFixtures.put(2, at: 12, in: &bytes)
        MachOFixtures.put(0x1_0000, at: 16, in: &bytes)
        MachOFixtures.put(100, at: 20, in: &bytes)
        let report = MachOPrefixInspector.inspect(prefix: Data(bytes), declaredByteCount: 0x1_0000 + 100, checksumVerified: false)
        XCTAssertEqual(report?.container, .universal)
        XCTAssertEqual(report?.slices.first?.architectureName, "arm64e")
        XCTAssertEqual(report?.slices.first?.encryption, .unreadable)
        XCTAssertEqual(report?.slices.first?.signature, .unreadable)
        XCTAssertEqual(MachOPrefixInspector.architectureName(cpu: .arm64, subtype: 0), "arm64")
    }

    // MARK: - Entry inspection

    func testPreviewsTextJSONAndPropertyListsWithoutWriting() async throws {
        let json = Data("{\"z\":1,\"a\":\"ok\"}".utf8)
        let info = try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleExecutable": "Example", "CFBundleShortVersionString": "9.9"],
            format: .xml,
            options: 0
        )
        let settings = try PropertyListSerialization.data(
            fromPropertyList: ["Theme": "Dark"],
            format: .xml,
            options: 0
        )
        let files = [
            "\(bundleRoot)/Info.plist": info,
            "\(bundleRoot)/config.json": json,
            "\(bundleRoot)/Settings.plist": settings,
        ]
        let inspection = try makeInspection(files: files)
        let contents = contents(files.map { file($0.key, bytes: $0.value) })

        let metadata = try await inspection.preview(recordWithID: recordID, contents: contents, entry: try entry(in: contents, "Info.plist"))
        guard case .text(let plist) = metadata.body else { return XCTFail("Expected a property-list preview") }
        XCTAssertEqual(plist.kind, .propertyList)
        XCTAssertTrue(plist.text.contains("CFBundleShortVersionString: 9.9"))
        XCTAssertEqual(metadata.locationText, "Payload/Example.app/Info.plist")

        let jsonPreview = try await inspection.preview(recordWithID: recordID, contents: contents, entry: try entry(in: contents, "config.json"))
        guard case .text(let shown) = jsonPreview.body else { return XCTFail("Expected JSON") }
        XCTAssertEqual(shown.kind, .json)
        XCTAssertTrue(shown.text.contains("\"a\""))
        XCTAssertLessThan(shown.text.range(of: "\"a\"")!.lowerBound, shown.text.range(of: "\"z\"")!.lowerBound)

        let other = try await inspection.preview(recordWithID: recordID, contents: contents, entry: try entry(in: contents, "Settings.plist"))
        guard case .text(let propertyList) = other.body else { return XCTFail("Expected a property list") }
        XCTAssertTrue(propertyList.text.contains("Theme: Dark"))
        XCTAssertEqual(previewProvider.readers.last?.closeCount, 3)
    }

    func testRefusesAnOversizedImageAndDoesNotReadIt() async throws {
        let image = file("Icon.png", bytes: Data(), uncompressed: ExplorerReadBounds.imageBytes + 1)
        let inspection = try makeInspection(files: [:], extra: [image])
        let tree = contents([image])
        let preview = try await inspection.preview(recordWithID: recordID, contents: tree, entry: try entry(in: tree, "Icon.png"))
        guard case .unavailable(let title, let message) = preview.body else { return XCTFail("Expected a refusal") }
        XCTAssertEqual(title, "Image Too Large")
        XCTAssertTrue(message.contains("was not read"))
        XCTAssertEqual(previewProvider.readers.last?.requestedPaths, [])
        XCTAssertEqual(previewProvider.readers.last?.closeCount, 1)
    }

    func testASymbolicLinkIsListedAndNotFollowed() async throws {
        let link = makeEntry("\(bundleRoot)/Frameworks/Link", kind: .symbolicLink)
        let inspection = try makeInspection(files: [:], extra: [link], failIfOpened: true)
        let tree = contents([link])
        let preview = try await inspection.preview(recordWithID: recordID, contents: tree, entry: try entry(in: tree, "Frameworks/Link"))
        guard case .unavailable(let title, _) = preview.body else { return XCTFail("Expected a link refusal") }
        XCTAssertEqual(title, "Symbolic Link")
        XCTAssertEqual(previewProvider.openCount, 0)
    }

    func testAForeignReadErrorIsNotCopiedIntoThePreview() async throws {
        let blob = file("notes.txt", bytes: Data("hello".utf8))
        let reader = ForeignArchiveReader(entryTable: [payloadEntry, bundleEntry, blob], secret: "SECRET_FOREIGN_DETAIL")
        let inspection = try makeInspection(reader: reader)
        let tree = contents([blob])
        let preview = try await inspection.preview(recordWithID: recordID, contents: tree, entry: try entry(in: tree, "notes.txt"))
        guard case .unavailable(_, let message) = preview.body else { return XCTFail("Expected an unavailable preview") }
        XCTAssertEqual(message, "This file could not be previewed.")
        XCTAssertFalse(message.contains("SECRET_FOREIGN_DETAIL"))
        XCTAssertFalse(preview.locationText.contains("SECRET_FOREIGN_DETAIL"))
        XCTAssertEqual(reader.closeCount, 1)
        XCTAssertEqual(IPABundleEntryInspection.failureMessage(for: SecretPreviewError(text: "SECRET_FOREIGN_DETAIL")), "This file could not be previewed.")
    }

    func testFrameworkAndExtensionPagesStayReadOnlyAndDoNotDumpDevices() async throws {
        let info = try PropertyListSerialization.data(fromPropertyList: [
            "CFBundleShortVersionString": "2.0",
            "CFBundleVersion": "20",
            "CFBundleIdentifier": "com.example.core",
            "CFBundleExecutable": "Core",
        ], format: .xml, options: 0)
        let macho = Data(MachOFixtures.thin(commands: [MachOFixtures.command(0x1D, size: 16)]))
        let extensionInfo = try PropertyListSerialization.data(fromPropertyList: [
            "CFBundleIdentifier": "com.example.share",
            "CFBundleExecutable": "Share",
            "CFBundleShortVersionString": "1.0",
            "NSExtension": ["NSExtensionPointIdentifier": "com.apple.share-services"],
        ], format: .xml, options: 0)
        let device = String(repeating: "A", count: 40)
        let profile = try PropertyListSerialization.data(fromPropertyList: [
            "Name": "Synthetic Extension Profile",
            "TeamIdentifier": ["TEAM123456"],
            "Entitlements": ["ProvisionedDevices": [device, device]],
        ], format: .xml, options: 0)
        let files = [
            "\(bundleRoot)/Frameworks/Core.framework/Info.plist": info,
            "\(bundleRoot)/Frameworks/Core.framework/Core": macho,
            "\(bundleRoot)/PlugIns/Share.appex/Info.plist": extensionInfo,
            "\(bundleRoot)/PlugIns/Share.appex/Share": Data([0x01]),
            "\(bundleRoot)/PlugIns/Share.appex/embedded.mobileprovision": profile,
        ]
        let inspection = try makeInspection(files: files)
        let tree = contents(files.map { file($0.key, bytes: $0.value) })

        let framework = try await inspection.preview(
            recordWithID: recordID,
            contents: tree,
            entry: try entry(in: tree, "Frameworks/Core.framework")
        )
        guard case .framework(let report) = framework.body else { return XCTFail("Expected a framework page") }
        XCTAssertEqual(report.name, "Core.framework")
        XCTAssertEqual(report.version, "2.0")
        XCTAssertEqual(report.executableName, "Core")
        XCTAssertEqual(report.signature, .commandPresent)
        XCTAssertTrue(report.note.contains("not evidence"))
        XCTAssertFalse(report.note.localizedCaseInsensitiveContains("trusted"))

        let extensionPage = try await inspection.preview(
            recordWithID: recordID,
            contents: tree,
            entry: try entry(in: tree, "PlugIns/Share.appex")
        )
        guard case .appExtension(let extensionReport) = extensionPage.body else { return XCTFail("Expected an extension page") }
        XCTAssertEqual(extensionReport.kind, .share)
        XCTAssertEqual(extensionReport.bundleIdentifier, "com.example.share")
        XCTAssertEqual(extensionReport.executableName, "Share")
        XCTAssertEqual(extensionReport.version, "1.0")
        XCTAssertEqual(extensionReport.entitlementLines.map(\.valueText), ["2 values"])
        XCTAssertFalse(extensionReport.entitlementLines.contains { $0.valueText.contains(device) })
        XCTAssertTrue(extensionReport.entitlementsNote.contains("not verified"))
    }

    func testAProfilePreviewUnwrapsDeclaredCMSContentAndDoesNotVerifyIt() async throws {
        let wrapped = CMSFixtures.validRSASignedAttributes
        let inspection = try makeInspection(files: ["\(bundleRoot)/embedded.mobileprovision": wrapped])
        let tree = contents([file("\(bundleRoot)/embedded.mobileprovision", bytes: wrapped)])
        let preview = try await inspection.preview(
            recordWithID: recordID,
            contents: tree,
            entry: try entry(in: tree, "embedded.mobileprovision")
        )
        guard case .profile(let summary) = preview.body else { return XCTFail("Expected a profile page") }
        XCTAssertEqual(wrapped.first, 0x30)
        XCTAssertEqual(summary.name, CMSFixtures.validRSAProfileName)
        XCTAssertEqual(summary.teamIdentifiers, [CMSFixtures.validRSATeamIdentifier])
        XCTAssertTrue(summary.note.contains("Declared by the embedded profile, not verified."))
        XCTAssertFalse(summary.note.localizedCaseInsensitiveContains("trusted"))
        XCTAssertFalse(summary.entitlementLines.contains { $0.valueText.count > ExplorerReadBounds.maximumValueCharacters + 1 })
    }

    func testAnExecutablePreviewIsAHeaderSummaryNotASignatureBlob() async throws {
        var image = MachOFixtures.thin(commands: [encryptionCommand(cryptid: 0), MachOFixtures.command(0x1D, size: 16)])
        image.append(contentsOf: Array(repeating: 0xAB, count: 64))
        let inspection = try makeInspection(files: ["\(bundleRoot)/Example": Data(image)])
        let tree = contents([file("\(bundleRoot)/Example", bytes: Data(image))], executableName: "Example")
        let preview = try await inspection.preview(recordWithID: recordID, contents: tree, entry: try entry(in: tree, "Example"))
        guard case .macho(let report) = preview.body else { return XCTFail("Expected a Mach-O page") }
        XCTAssertEqual(report.architectureSummary, "arm64")
        XCTAssertEqual(report.fileTypeSummary, "Executable")
        XCTAssertEqual(report.encryptionSummary, .notEncrypted)
        XCTAssertEqual(report.signatureSummary, ExplorerSignaturePresence.commandPresent.displayName)
        XCTAssertTrue(report.note.contains("not evidence"))
        XCTAssertFalse(report.note.contains("ABAB"))
    }

    // MARK: - Fixtures

    private let recordID = ApplicationRecordIdentifier()
    private var previewProvider: PreviewArchiveProvider!

    private var payloadEntry: ArchiveEntry { makeEntry("Payload", kind: .directory) }
    private var bundleEntry: ArchiveEntry { makeEntry(bundleRoot, kind: .directory) }

    private func path(_ raw: String) -> BundlePath {
        guard let path = BundlePath(rawValue: raw) else {
            preconditionFailure("Unsafe bundle path in a test: \(raw)")
        }
        return path
    }

    private func entry(_ raw: String, kind: ArchiveEntryKind = .regularFile, role: BundleEntryRole? = nil) -> BundleEntry {
        BundleEntry(path: path(raw), kind: kind, declaredByteCount: kind == .regularFile ? 1 : nil, role: role)
    }

    private func classify(_ raw: String, kind: ArchiveEntryKind = .regularFile, role: BundleEntryRole? = nil) -> BundleFileClassification {
        BundleFileClassification.recognize(entry(raw, kind: kind, role: role))
    }

    private func file(_ name: String, bytes: Data, uncompressed: Int? = nil) -> ArchiveEntry {
        let size = uncompressed ?? bytes.count
        let archiveName = name.hasPrefix("Payload/") ? name : "\(bundleRoot)/\(name)"
        return makeEntry(archiveName, uncompressedSize: size, compressedSize: size)
    }

    private func directory(_ name: String) -> ArchiveEntry {
        let archiveName = name.hasPrefix("Payload/") ? name : "\(bundleRoot)/\(name)"
        return makeEntry(archiveName, kind: .directory)
    }

    private func contents(_ entries: [ArchiveEntry], executableName: String? = "Example") -> BundleContents {
        BundleContents(
            entryTable: [payloadEntry, bundleEntry] + entries,
            bundlePath: makePath(bundleRoot),
            declaredExecutableName: executableName
        )
    }

    private func sampleContents() -> BundleContents {
        contents([
            file("Info.plist", bytes: Data("info".utf8)),
            file("Example", bytes: Data(repeating: 0x90, count: 32)),
            file("Icon.png", bytes: Data([0x89, 0x50])),
            file("config.json", bytes: Data("{}".utf8)),
            directory("Frameworks"),
            file("Frameworks/Core.framework/Core", bytes: Data(repeating: 0x11, count: 8)),
            directory("PlugIns"),
            file("PlugIns/Share.appex/Share", bytes: Data(repeating: 0x22, count: 8)),
            file("mystery.bin", bytes: Data([0x00])),
        ], executableName: "Example")
    }

    private func entry(in contents: BundleContents, _ raw: String) throws -> BundleEntry {
        try XCTUnwrap(contents.entry(at: path(raw)))
    }

    private func encryptionCommand(cryptid: UInt32) -> [UInt8] {
        var bytes = MachOFixtures.command(0x21, size: 20)
        MachOFixtures.put(UInt64(cryptid), at: 16, in: &bytes, order: .littleEndian)
        return bytes
    }

    private func makeInspection(
        files: [String: Data],
        extra: [ArchiveEntry] = [],
        failIfOpened: Bool = false
    ) throws -> IPABundleEntryInspection {
        var table = [payloadEntry, bundleEntry]
        var content: [String: Data] = [:]
        for (name, bytes) in files {
            table.append(file(name, bytes: bytes))
            content[name] = bytes
        }
        table.append(contentsOf: extra)
        let reader = SyntheticArchiveReader(entryTable: table, contentByPath: content)
        return try makeInspection(reader: reader, failIfOpened: failIfOpened)
    }

    private func makeInspection(reader: some ArchiveReader, failIfOpened: Bool = false) throws -> IPABundleEntryInspection {
        let artifactID = ArtifactIdentifier()
        let held = Data([0x01])
        let record = LibraryFixtures.record(
            id: recordID,
            artifact: LibraryFixtures.reference(to: held, artifactID: artifactID)
        )
        let records = InMemoryApplicationRecordStore(records: [record])
        let artifacts = SyntheticLibraryArtifactStore()
        artifacts.hold(held, as: artifactID)
        let library = ApplicationLibrary(records: records, artifacts: artifacts)
        let provider = PreviewArchiveProvider(reader: reader, failIfOpened: failIfOpened)
        previewProvider = provider
        return IPABundleEntryInspection(
            library: library,
            readerProvider: provider
        )
    }
}

private struct SecretPreviewError: LocalizedError {
    let text: String
    var errorDescription: String? { text }
}

private final class ForeignArchiveReader: ArchiveReader {
    let entryTable: [ArchiveEntry]
    let secret: String
    private(set) var closeCount = 0
    private(set) var requestedPaths: [ArchivePath] = []

    init(entryTable: [ArchiveEntry], secret: String) {
        self.entryTable = entryTable
        self.secret = secret
    }

    func readEntryTable() throws -> [ArchiveEntry] { entryTable }
    func containsEntry(at path: ArchivePath) throws -> Bool { entryTable.contains { $0.path == path } }
    func entryKind(at path: ArchivePath) throws -> ArchiveEntryKind? { entryTable.first { $0.path == path }?.kind }
    func readEntryData(at path: ArchivePath, maximumBytes: Int) throws -> Data {
        requestedPaths.append(path)
        throw SecretPreviewError(text: secret)
    }
    func close() { closeCount += 1 }
}

private final class PreviewArchiveProvider: ArtifactArchiveReaderProvider, @unchecked Sendable {
    private let lock = NSLock()
    private let reader: any ArchiveReader
    private let failIfOpened: Bool
    private var _openCount = 0
    private var _readers: [SyntheticArchiveReader] = []

    init(reader: any ArchiveReader, failIfOpened: Bool = false) {
        self.reader = reader
        self.failIfOpened = failIfOpened
    }

    var openCount: Int { lock.withLock { _openCount } }
    var readers: [SyntheticArchiveReader] { lock.withLock { _readers } }

    func archiveReader(for artifact: ArtifactIdentifier) throws -> any ArchiveReader {
        let shouldFail = lock.withLock { () -> Bool in
            _openCount += 1
            if let synthetic = reader as? SyntheticArchiveReader {
                _readers.append(synthetic)
            }
            return failIfOpened
        }
        if shouldFail {
            throw SecretPreviewError(text: "SECRET_FOREIGN_DETAIL")
        }
        return reader
    }
}
