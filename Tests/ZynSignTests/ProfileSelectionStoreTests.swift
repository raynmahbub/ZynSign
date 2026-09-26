import XCTest
@testable import ZynSign

/// `UserDefaultsProfileSelectionStore`: the pinned "Use for Signing"
/// profile and per-application overrides, round-tripped through an
/// isolated defaults suite.
final class ProfileSelectionStoreTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!
    private var store: UserDefaultsProfileSelectionStore!

    override func setUp() {
        super.setUp()
        suiteName = "ProfileSelectionStoreTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        store = UserDefaultsProfileSelectionStore(defaults: defaults)
    }

    override func tearDown() {
        if let suiteName {
            defaults?.removePersistentDomain(forName: suiteName)
        }
        store = nil
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    private var applicationID: ApplicationRecordIdentifier {
        ApplicationRecordIdentifier()
    }

    func testPreferredProfileStartsNilAndRoundTrips() {
        XCTAssertNil(store.preferredProfileID())
        let id = ProvisioningProfileIdentifier(rawValue: "profile-1")
        store.setPreferredProfile(id)
        XCTAssertEqual(store.preferredProfileID(), id)
        store.setPreferredProfile(nil)
        XCTAssertNil(store.preferredProfileID())
    }

    func testApplicationOverrideRoundTripsAndStaysPerApp() {
        let appA = applicationID
        let appB = applicationID
        let profile = ProvisioningProfileIdentifier(rawValue: "profile-a")

        XCTAssertNil(store.selection(forApplication: appA))
        store.setSelection(profile, forApplication: appA)
        XCTAssertEqual(store.selection(forApplication: appA), profile)
        XCTAssertNil(store.selection(forApplication: appB))

        store.setSelection(nil, forApplication: appA)
        XCTAssertNil(store.selection(forApplication: appA))
    }

    func testSeparateStoreInstancesShareTheSameSuite() {
        let id = ProvisioningProfileIdentifier(rawValue: "profile-shared")
        store.setPreferredProfile(id)
        let second = UserDefaultsProfileSelectionStore(defaults: defaults)
        XCTAssertEqual(second.preferredProfileID(), id)
    }

    func testSelectionForRemovedProfileStillReadsBackAsIdentifier() {
        // The store is a preference, not a registry: a caller resolves the
        // identifier against the library and falls back when it is gone.
        let gone = ProvisioningProfileIdentifier(rawValue: "no-longer-in-library")
        store.setPreferredProfile(gone)
        XCTAssertEqual(store.preferredProfileID(), gone)
    }
}
