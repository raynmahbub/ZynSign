import XCTest
@testable import ZynSign

final class ApplicationBundleTests: XCTestCase {

    private func identity() throws -> ApplicationIdentity {
        try ApplicationIdentity(
            bundleIdentifier: "com.example.application",
            displayName: "Example",
            shortVersionString: "1.0",
            buildVersion: "1"
        )
    }

    private func bundlePath(_ rawValue: String = "Payload/Example.app") throws -> ArchivePath {
        try XCTUnwrap(ArchivePath(rawValue: rawValue))
    }

    func testCreatesIdentifiedBundleWithResolvedExecutable() throws {
        let bundle = try ApplicationBundle(
            bundlePath: bundlePath(),
            identity: identity(),
            executablePath: ArchivePath(rawValue: "Payload/Example.app/Example")
        )
        XCTAssertEqual(bundle.bundlePath.rawValue, "Payload/Example.app")
        XCTAssertEqual(bundle.bundleName, "Example.app")
        XCTAssertTrue(bundle.isIdentified)
        XCTAssertEqual(bundle.identity?.bundleIdentifier.rawValue, "com.example.application")
        XCTAssertEqual(bundle.executablePath?.rawValue, "Payload/Example.app/Example")
    }

    func testCreatesUnidentifiedBundleWithoutExecutable() throws {
        let bundle = try ApplicationBundle(bundlePath: bundlePath())
        XCTAssertNil(bundle.identity)
        XCTAssertNil(bundle.executablePath)
        XCTAssertFalse(bundle.isIdentified)
    }

    func testBundleOutsidePayloadStaysRepresentable() throws {
        let bundle = try ApplicationBundle(bundlePath: bundlePath("Unpacked/Example.app"))
        XCTAssertEqual(bundle.bundlePath.rawValue, "Unpacked/Example.app")
    }

    func testAcceptsCaseInsensitiveApplicationSuffix() throws {
        let bundle = try ApplicationBundle(bundlePath: bundlePath("Payload/Example.APP"))
        XCTAssertEqual(bundle.bundleName, "Example.APP")
    }

    func testRejectsNonApplicationDirectory() throws {
        XCTAssertThrowsError(try ApplicationBundle(bundlePath: bundlePath("Payload/Example.framework"))) { error in
            guard let zynSignError = error as? ZynSignError else {
                return XCTFail("Expected ZynSignError, got \(type(of: error))")
            }
            XCTAssertEqual(zynSignError.category, .invalidInput)
        }
    }

    func testRejectsApplicationSuffixWithoutBaseName() throws {
        XCTAssertThrowsError(try ApplicationBundle(bundlePath: bundlePath("Payload/.app"))) { error in
            XCTAssertTrue(error is ZynSignError)
        }
    }

    func testRejectsExecutableOutsideBundle() throws {
        XCTAssertThrowsError(
            try ApplicationBundle(
                bundlePath: bundlePath(),
                identity: identity(),
                executablePath: ArchivePath(rawValue: "Payload/Other.app/Other")
            )
        ) { error in
            guard let zynSignError = error as? ZynSignError else {
                return XCTFail("Expected ZynSignError, got \(type(of: error))")
            }
            XCTAssertEqual(zynSignError.category, .invalidInput)
            XCTAssertFalse(zynSignError.userMessage.isEmpty)
        }
    }

    func testRejectsExecutableEqualToBundlePath() throws {
        XCTAssertThrowsError(
            try ApplicationBundle(
                bundlePath: bundlePath(),
                executablePath: bundlePath()
            )
        ) { error in
            XCTAssertTrue(error is ZynSignError)
        }
    }

    func testBundlesWithSameValuesAreEqual() throws {
        let first = try ApplicationBundle(bundlePath: bundlePath(), identity: identity())
        let second = try ApplicationBundle(bundlePath: bundlePath(), identity: identity())
        XCTAssertEqual(first, second)
        XCTAssertEqual(
            Set([first, second]).count,
            1
        )
    }
}
