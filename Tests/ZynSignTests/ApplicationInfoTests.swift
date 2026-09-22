import XCTest
@testable import ZynSign

final class ApplicationInfoTests: XCTestCase {

    func testResolvesAllValuesFromCompleteDictionary() {
        let info = ApplicationInfo.resolve(from: [
            "CFBundleDisplayName": "ZynSign",
            "CFBundleShortVersionString": "0.1.0",
            "CFBundleVersion": "1",
        ])
        XCTAssertEqual(info, ApplicationInfo(
            displayName: "ZynSign",
            marketingVersion: "0.1.0",
            buildVersion: "1"
        ))
    }

    func testPrefersDisplayNameOverBundleName() {
        let info = ApplicationInfo.resolve(from: [
            "CFBundleDisplayName": "Display",
            "CFBundleName": "Name",
        ])
        XCTAssertEqual(info.displayName, "Display")
    }

    func testFallsBackToBundleNameWhenDisplayNameMissing() {
        let info = ApplicationInfo.resolve(from: ["CFBundleName": "Name"])
        XCTAssertEqual(info.displayName, "Name")
    }

    func testFallsBackWhenVersionsMissing() {
        let info = ApplicationInfo.resolve(from: ["CFBundleDisplayName": "ZynSign"])
        XCTAssertEqual(info.marketingVersion, ApplicationInfo.unknownVersion)
        XCTAssertEqual(info.buildVersion, ApplicationInfo.unknownVersion)
    }

    func testFallsBackToDefaultsForMissingDictionary() {
        let info = ApplicationInfo.resolve(from: nil)
        XCTAssertEqual(info, ApplicationInfo(
            displayName: ApplicationInfo.defaultDisplayName,
            marketingVersion: ApplicationInfo.unknownVersion,
            buildVersion: ApplicationInfo.unknownVersion
        ))
    }

    func testNonStringValuesFallBackInsteadOfCrashing() {
        let info = ApplicationInfo.resolve(from: [
            "CFBundleDisplayName": 42,
            "CFBundleShortVersionString": 1.5,
        ])
        XCTAssertEqual(info.displayName, ApplicationInfo.defaultDisplayName)
        XCTAssertEqual(info.marketingVersion, ApplicationInfo.unknownVersion)
    }
}
