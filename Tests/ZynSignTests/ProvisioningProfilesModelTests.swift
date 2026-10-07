import XCTest
import UniformTypeIdentifiers
@testable import ZynSign

/// The Profiles section model's pure projections: search matching, sort
/// orders, type and expiration filters, and the import-failure notice
/// titles. The view-observed phases are exercised through these static
/// rules so no view is needed. The model is main-actor isolated, so the
/// tests are too — the same convention `ApplicationLibraryModelTests`
/// uses.
@MainActor
final class ProvisioningProfilesModelTests: XCTestCase {

    private let referenceDate = Date()

    private func makeSummary(
        name: String,
        teamName: String? = nil,
        teamIdentifier: String? = "TEAM123456",
        patterns: [String] = ["com.example.synthetic"],
        uuid: String? = nil,
        applicationIdentifier: String? = nil,
        bundleIdentifier: String? = "com.example.synthetic",
        profileType: ProvisioningProfileClassification? = .development,
        expirationIn days: Int = 120,
        importedAt: Date? = nil
    ) -> ProvisioningProfileSummary {
        ProvisioningProfileSummary(
            name: name,
            teamIdentifier: teamIdentifier,
            bundleIdentifierPatterns: patterns,
            expirationDate: referenceDate.addingTimeInterval(Double(days) * 86400),
            entitlementsKeys: [],
            allowsDebug: false,
            sourceFileName: "\(name).mobileprovision",
            importedAt: importedAt ?? referenceDate,
            uuid: uuid,
            teamName: teamName,
            profileType: profileType,
            applicationIdentifier: applicationIdentifier,
            bundleIdentifier: bundleIdentifier
        )
    }

    // MARK: - Search

    func testEmptyQueryMatchesEverything() {
        XCTAssertTrue(
            ProvisioningProfilesModel.matches(makeSummary(name: "Anything"), query: "")
        )
        XCTAssertTrue(
            ProvisioningProfilesModel.matches(
                makeSummary(name: "Anything"),
                query: "   "
            )
        )
    }

    func testSearchMatchesNameTeamUUIDAppIDAndPatterns() {
        let summary = makeSummary(
            name: "Wonder Profile",
            teamName: "Acme Studios",
            teamIdentifier: "TEAMABC123",
            patterns: ["com.example.*"],
            uuid: "12345678-1234-4ABC-8DEF-1234567890AB",
            applicationIdentifier: "TEAMABC123.com.example.synthetic",
            bundleIdentifier: "com.example.synthetic"
        )
        XCTAssertTrue(ProvisioningProfilesModel.matches(summary, query: "wonder"))
        XCTAssertTrue(ProvisioningProfilesModel.matches(summary, query: "acme"))
        XCTAssertTrue(ProvisioningProfilesModel.matches(summary, query: "teamabc"))
        XCTAssertTrue(ProvisioningProfilesModel.matches(summary, query: "4ABC-8DEF"))
        XCTAssertTrue(ProvisioningProfilesModel.matches(summary, query: "com.example.synthetic"))
        XCTAssertTrue(ProvisioningProfilesModel.matches(summary, query: "TEAMABC123.com"))
        XCTAssertFalse(ProvisioningProfilesModel.matches(summary, query: "org.other"))
    }

    // MARK: - Sort

    func testExpirationSortSinksExpiredAndUsesSoonestFirst() {
        let expired = makeSummary(name: "Expired", expirationIn: -1)
        let soon = makeSummary(name: "Soon", expirationIn: 5)
        let later = makeSummary(name: "Later", expirationIn: 300)
        let sorted = ProvisioningProfilesModel.ordered(
            [later, expired, soon],
            by: .expiration
        )
        XCTAssertEqual(sorted.map(\.name), ["Soon", "Later", "Expired"])
    }

    func testNameSortIsCaseInsensitiveAlphabetical() {
        let sorted = ProvisioningProfilesModel.ordered(
            [makeSummary(name: "beta"), makeSummary(name: "Alpha")],
            by: .name
        )
        XCTAssertEqual(sorted.map(\.name), ["Alpha", "beta"])
    }

    func testRecentlyImportedSortIsNewestFirst() {
        let older = makeSummary(name: "Older", importedAt: referenceDate.addingTimeInterval(-100))
        let newer = makeSummary(name: "Newer", importedAt: referenceDate)
        let sorted = ProvisioningProfilesModel.ordered(
            [older, newer],
            by: .recentlyImported
        )
        XCTAssertEqual(sorted.map(\.name), ["Newer", "Older"])
    }

    func testTypeSortGroupsByDistributionTypeName() {
        let development = makeSummary(name: "Dev", profileType: .development)
        let appStore = makeSummary(name: "Store", profileType: .appStore)
        let enterprise = makeSummary(name: "Ent", profileType: .enterprise)
        let sorted = ProvisioningProfilesModel.ordered(
            [development, appStore, enterprise],
            by: .type
        )
        // Alphabetical by display name: "App Store", "Development",
        // "Enterprise".
        XCTAssertEqual(sorted.map(\.name), ["Store", "Dev", "Ent"])
    }

    // MARK: - Filters

    func testTypeFilter() {
        let development = makeSummary(name: "Dev", profileType: .development)
        let appStore = makeSummary(name: "Store", profileType: .appStore)
        XCTAssertTrue(ProvisioningProfilesModel.TypeFilter.all.includes(development))
        XCTAssertTrue(ProvisioningProfilesModel.TypeFilter.development.includes(development))
        XCTAssertFalse(ProvisioningProfilesModel.TypeFilter.development.includes(appStore))
        XCTAssertTrue(ProvisioningProfilesModel.TypeFilter.appStore.includes(appStore))
    }

    func testExpirationFilter() {
        let healthy = makeSummary(name: "Healthy", expirationIn: 90)
        let expiring = makeSummary(name: "Expiring", expirationIn: 10)
        let expired = makeSummary(name: "Expired", expirationIn: -1)
        let date = referenceDate
        XCTAssertTrue(
            ProvisioningProfilesModel.ExpirationFilter.all.includes(healthy, referenceDate: date)
        )
        XCTAssertTrue(
            ProvisioningProfilesModel.ExpirationFilter.healthy.includes(healthy, referenceDate: date)
        )
        XCTAssertTrue(
            ProvisioningProfilesModel.ExpirationFilter.expiringSoon.includes(expiring, referenceDate: date)
        )
        XCTAssertFalse(
            ProvisioningProfilesModel.ExpirationFilter.expiringSoon.includes(healthy, referenceDate: date)
        )
        XCTAssertTrue(
            ProvisioningProfilesModel.ExpirationFilter.expired.includes(expired, referenceDate: date)
        )
    }

    // MARK: - Full projection

    func testDisplayedAppliesSearchFiltersAndSortTogether() {
        let matchingHealthy = makeSummary(name: "Alpha", expirationIn: 90)
        let matchingExpired = makeSummary(name: "Beta", expirationIn: -1)
        let otherTeam = makeSummary(
            name: "Gamma",
            teamIdentifier: "TEAMZZZZZZ",
            patterns: ["org.other.app"],
            bundleIdentifier: "org.other.app",
            expirationIn: 10
        )
        let profiles = [matchingHealthy, matchingExpired, otherTeam]

        let result = ProvisioningProfilesModel.displayed(
            profiles,
            matching: "com.example",
            sortedBy: .expiration,
            typeFilter: .all,
            expirationFilter: .all,
            referenceDate: referenceDate
        )
        XCTAssertEqual(result.map(\.name), ["Alpha", "Beta"])

        let expiringOnly = ProvisioningProfilesModel.displayed(
            profiles,
            matching: "",
            sortedBy: .name,
            typeFilter: .all,
            expirationFilter: .expiringSoon,
            referenceDate: referenceDate
        )
        XCTAssertEqual(expiringOnly.map(\.name), ["Gamma"])
    }

    // MARK: - Import picker and failure notices

    func testPickerOffersBothProvisioningProfileExtensions() {
        let types = ProvisioningProfilesModel.importableTypes
        if let mobileprovision = UTType(filenameExtension: "mobileprovision") {
            XCTAssertTrue(types.contains(mobileprovision))
        }
        if let provisionprofile = UTType(filenameExtension: "provisionprofile") {
            XCTAssertTrue(types.contains(provisionprofile))
        }
        XCTAssertTrue(types.contains(.data))
        XCTAssertTrue(types.contains(.item))
    }

    func testPickerFailureIsSurfacedButCancellationStaysQuiet() {
        let model = ProvisioningProfilesModel(profiles: nil, importer: nil)
        let pickerFailure = NSError(domain: "ProfilePicker", code: 17)

        model.handlePickerResult(.failure(pickerFailure))
        XCTAssertEqual(model.notice?.title, "Couldn't Open Profile")
        XCTAssertFalse(model.notice?.message.isEmpty ?? true)

        model.clearNotice()
        model.handlePickerResult(.failure(NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError)))
        XCTAssertNil(model.notice)
    }

    func testInputTooLargeFailureUsesGenericNoticeTitle() {
        let error = ZynSignError.provisioningProfileInputTooLarge(
            diagnosticDetail: "synthetic"
        )
        // Input-too-large is invalid input, not an unsupported format.
        let notice = ProvisioningProfilesModel.notice(for: error)
        XCTAssertEqual(notice.title, "Import Failed")
        XCTAssertFalse(notice.message.isEmpty)
    }

    func testUnsupportedFormatFailureGetsItsOwnNoticeTitle() {
        let error = ZynSignError.unsupportedProvisioningProfileContainer(
            diagnosticDetail: "synthetic"
        )
        let notice = ProvisioningProfilesModel.notice(for: error)
        XCTAssertEqual(notice.title, "Unsupported Profile")
        XCTAssertEqual(notice.message, error.userMessage)
    }

    func testGenericFailureNoticeKeepsTypedMessage() {
        let error = ZynSignError.emptyProvisioningProfile()
        let notice = ProvisioningProfilesModel.notice(for: error)
        XCTAssertEqual(notice.title, "Import Failed")
        XCTAssertEqual(notice.message, error.userMessage)
    }
}
