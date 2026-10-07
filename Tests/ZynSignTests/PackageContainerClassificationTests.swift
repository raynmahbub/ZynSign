import XCTest
@testable import ZynSign

/// Tests for classifying a staged container from its entry table, and for
/// the analysis derived from an application package's entries.
final class PackageContainerClassificationTests: XCTestCase {

    // MARK: - Classification

    func testTheApplicationPackageLayoutIsRecognisedWhateverTheFileIsCalled() {
        XCTAssertEqual(PackageContainerClassification.classify(validPackageEntryTable()), .applicationPackage)
    }

    func testABrokenPackageLayoutIsLeftToThePackageInspections() {
        // An empty Payload folder is still a package layout; the package
        // inspections explain what is missing in their own words.
        XCTAssertEqual(
            PackageContainerClassification.classify([makeEntry("Payload", kind: .directory)]),
            .applicationPackage
        )
    }

    func testAnArchiveOfPackagesOffersEachInOrder() {
        let classification = PackageContainerClassification.classify([
            makeEntry("Apps", kind: .directory),
            makeEntry("Apps/Zeta.ipa", uncompressedSize: 500, compressedSize: 400),
            makeEntry("Alpha.IPA", uncompressedSize: 100, compressedSize: 90),
            makeEntry("Beta.tipa", uncompressedSize: 200, compressedSize: 150),
            makeEntry("Notes.txt", uncompressedSize: 10, compressedSize: 10),
        ])
        guard case .packageCollection(let candidates) = classification else {
            return XCTFail("Expected packages to be offered, got \(classification).")
        }
        XCTAssertEqual(candidates.map(\.path.rawValue), ["Alpha.IPA", "Apps/Zeta.ipa", "Beta.tipa"])
        XCTAssertEqual(candidates.map(\.byteCount), [100, 500, 200])
        XCTAssertEqual(candidates[1].fileName, "Zeta.ipa")
        XCTAssertEqual(candidates[1].folder, "Apps")
        XCTAssertNil(candidates[0].folder)
    }

    func testResourceForksAndHiddenFilesAreNeverOffered() {
        let classification = PackageContainerClassification.classify([
            makeEntry("__MACOSX/App.ipa", uncompressedSize: 10),
            makeEntry("._App.ipa", uncompressedSize: 10),
            makeEntry(".hidden.ipa", uncompressedSize: 10),
            makeEntry("App.ipa", uncompressedSize: 10),
        ])
        XCTAssertEqual(classification, .packageCollection([
            NestedPackageCandidate(path: makePath("App.ipa"), byteCount: 10, compressedByteCount: 0),
        ]))
    }

    func testAnUnsafeEntryNameRefusesTheWholeArchive() {
        let classification = PackageContainerClassification.classify([
            makeEntry("Good.ipa", uncompressedSize: 10),
            makeRejectedEntry("../escape.ipa"),
        ])
        guard case .unsafe(.unsafeEntryName(let name)) = classification else {
            return XCTFail("Expected the archive to be refused, got \(classification).")
        }
        XCTAssertEqual(name, "../escape.ipa")
    }

    func testDuplicateEntriesRefuseTheWholeArchive() {
        XCTAssertEqual(
            PackageContainerClassification.classify([
                makeEntry("App.ipa", uncompressedSize: 10),
                makeEntry("App.ipa", uncompressedSize: 20),
            ]),
            .unsafe(.duplicateEntries("App.ipa"))
        )
    }

    func testPackagesDifferingOnlyByCaseRefuseTheArchive() {
        XCTAssertEqual(
            PackageContainerClassification.classify([
                makeEntry("App.ipa", uncompressedSize: 10),
                makeEntry("APP.ipa", uncompressedSize: 20),
            ]),
            .unsafe(.duplicateEntries("APP.ipa"))
        )
    }

    func testALinkWithAPackageNameRefusesTheArchive() {
        XCTAssertEqual(
            PackageContainerClassification.classify([makeEntry("App.ipa", kind: .symbolicLink)]),
            .unsafe(.linkedPackage("App.ipa"))
        )
    }

    func testAnArchiveWithoutPackagesSaysSo() {
        XCTAssertEqual(
            PackageContainerClassification.classify([makeEntry("Photo.jpg", uncompressedSize: 10)]),
            .noPackages
        )
        XCTAssertEqual(PackageContainerClassification.classify([]), .noPackages)
    }

    func testUnsupportedLayoutsAreExplained() {
        XCTAssertEqual(
            PackageContainerClassification.classify([makeEntry("MyApp.xcarchive/Products/Applications/MyApp.app/Info.plist")]),
            .unsupportedLayout(.xcodeArchive)
        )
        XCTAssertEqual(
            PackageContainerClassification.classify([makeEntry("MyApp.app/Info.plist")]),
            .unsupportedLayout(.bareApplicationBundle)
        )
        XCTAssertEqual(
            PackageContainerClassification.classify([makeEntry("Inner.zip", uncompressedSize: 10)]),
            .unsupportedLayout(.nestedArchives)
        )
    }

    func testAnArchiveOfCertificateMaterialPointsAtCertificates() {
        // The common certificate bundle: a .p12 and its profile, zipped
        // together by whoever issued them. It is not "nothing importable" —
        // Certificates & Profiles takes those files directly.
        XCTAssertEqual(
            PackageContainerClassification.classify([
                makeEntry("certs/Signer.p12", uncompressedSize: 10),
                makeEntry("certs/Distribution.mobileprovision", uncompressedSize: 20),
            ]),
            .unsupportedLayout(.certificateMaterial)
        )
        XCTAssertEqual(
            PackageContainerClassification.classify([makeEntry("Credentials.pfx", uncompressedSize: 10)]),
            .unsupportedLayout(.certificateMaterial)
        )
    }

    func testCertificateFilesNeverMaskAPackageInTheSameArchive() {
        // Packages win: an archive holding an .ipa is still importable, and
        // the certificate file inside it is simply not offered.
        let classification = PackageContainerClassification.classify([
            makeEntry("Signer.p12", uncompressedSize: 10),
            makeEntry("App.ipa", uncompressedSize: 20),
        ])
        guard case .packageCollection(let candidates) = classification else {
            return XCTFail("Expected the package to be offered, got \(classification).")
        }
        XCTAssertEqual(candidates.map(\.path.rawValue), ["App.ipa"])
    }

    func testResourceForkCertificateShadowsAreNotSigningMaterial() {
        XCTAssertEqual(
            PackageContainerClassification.classify([makeEntry("__MACOSX/Signer.p12", uncompressedSize: 10)]),
            .noPackages
        )
        XCTAssertEqual(
            PackageContainerClassification.classify([makeEntry("._Signer.p12", uncompressedSize: 10)]),
            .noPackages
        )
    }

    // MARK: - Analysis

    private let root = makePath("Payload/Example.app")

    func testAnalysisCountsFrameworksExtensionsAndTheSignature() {
        let entries = validPackageEntryTable() + [
            makeEntry("Payload/Example.app/_CodeSignature/CodeResources", uncompressedSize: 100),
            makeEntry("Payload/Example.app/embedded.mobileprovision", uncompressedSize: 50),
            makeEntry("Payload/Example.app/Frameworks/A.framework", kind: .directory),
            makeEntry("Payload/Example.app/Frameworks/A.framework/A", uncompressedSize: 1_000),
            makeEntry("Payload/Example.app/Frameworks/B.framework/B", uncompressedSize: 2_000),
            makeEntry("Payload/Example.app/Frameworks/libswiftCore.dylib", uncompressedSize: 300),
            makeEntry("Payload/Example.app/PlugIns/Widget.appex/Widget", uncompressedSize: 400),
            makeEntry("Payload/Example.app/Extensions/Share.appex/Info.plist", uncompressedSize: 10),
            makeEntry("Payload/Other.app/Frameworks/C.framework/C", uncompressedSize: 5),
        ]
        let metadata = ApplicationMetadata(
            identity: LibraryFixtures.identity(),
            minimumOSVersion: "16.0",
            deviceFamily: [.phone, .pad]
        )

        let analysis = ApplicationAnalysis.derive(from: entries, bundleRoot: root, metadata: metadata)

        XCTAssertEqual(analysis.signingState, .signaturePresent)
        XCTAssertTrue(analysis.includesProvisioningProfile)
        XCTAssertEqual(analysis.frameworkCount, 2, "Only .framework bundles of this application count.")
        XCTAssertEqual(analysis.extensionCount, 2)
        XCTAssertEqual(analysis.minimumOSVersion, "16.0")
        XCTAssertEqual(analysis.supportedDevices, ["iPhone", "iPad"])
        XCTAssertEqual(analysis.fileCount, entries.filter { $0.kind == .regularFile }.count)
        XCTAssertEqual(analysis.unpackedByteCount, entries.filter { $0.kind == .regularFile }.map(\.uncompressedSize).reduce(0, +))
    }

    func testASignatureDirectoryWithoutItsSealIsNotASignature() {
        let entries = validPackageEntryTable() + [
            makeEntry("Payload/Example.app/_CodeSignature", kind: .directory),
        ]
        let analysis = ApplicationAnalysis.derive(from: entries, bundleRoot: root, metadata: nil)
        XCTAssertEqual(analysis.signingState, .unsigned)
        XCTAssertFalse(analysis.includesProvisioningProfile)
        XCTAssertTrue(analysis.supportedDevices.isEmpty)
        XCTAssertNil(analysis.minimumOSVersion)
    }

    func testAnalysisWithoutABundleRootCountsOnlyThePackage() {
        let analysis = ApplicationAnalysis.derive(from: validPackageEntryTable(), bundleRoot: nil, metadata: nil)
        XCTAssertEqual(analysis.frameworkCount, 0)
        XCTAssertEqual(analysis.signingState, .unsigned)
        XCTAssertGreaterThan(analysis.fileCount, 0)
    }

    func testAnalysisSurvivesACacheRoundTrip() throws {
        let analysis = ImportHubFixtures.analysis
        let decoded = try JSONDecoder().decode(ApplicationAnalysis.self, from: JSONEncoder().encode(analysis))
        XCTAssertEqual(decoded, analysis)
    }

    func testTheSigningStateNeverClaimsVerification() {
        XCTAssertFalse(ApplicationAnalysis.SigningState.signaturePresent.displayName.lowercased().contains("valid"))
        XCTAssertTrue(ApplicationAnalysis.SigningState.signaturePresent.explanation.contains("has not verified"))
    }
}
