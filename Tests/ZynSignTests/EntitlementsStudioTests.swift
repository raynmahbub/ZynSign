import Foundation
import XCTest
@testable import ZynSign

final class EntitlementsStudioTests: XCTestCase {
    private let bundleID = BundleIdentifier(rawValue: "com.example.app")!
    private let push = "aps-environment"

    private func profile(_ values: [String: ProvisioningProfileValue], identifier: String = "PREFIX.com.example.*") throws -> ProvisioningProfile {
        ProvisioningProfile(
            applicationIdentifier: try ProvisioningApplicationIdentifier(fullValue: identifier, applicationIdentifierPrefix: "PREFIX"),
            applicationIdentifierPrefixes: ["PREFIX"], teamIdentifiers: ["TEAM"],
            entitlementTeamIdentifier: "TEAM", entitlements: .init(values: values)
        )
    }
    private func analyze(_ values: [String: ProvisioningProfileValue]?, profile: ProvisioningProfile? = nil,
                         team: String? = "TEAM", der: Bool = false) throws -> EntitlementStudioAnalysis {
        EntitlementsStudioAnalyzer.analyze(app: try values.map { try CodeSigningEntitlements(values: $0) },
                                          profile: profile, bundleID: bundleID, certificateTeam: team,
                                          emitDER: der, sourceNote: "Synthetic main executable")
    }

    func testMappingsAndUnknownPreservation() throws {
        let keys = [push, "com.apple.security.application-groups", "keychain-access-groups",
                    "com.apple.developer.associated-domains", "com.apple.developer.icloud-services",
                    "com.apple.developer.siri", "com.apple.developer.healthkit", "com.apple.developer.homekit",
                    "com.apple.developer.pass-type-identifiers", "future.example.key"]
        let booleans: Set<String> = ["com.apple.developer.siri", "com.apple.developer.healthkit", "com.apple.developer.homekit", "future.example.key"]
        let values = Dictionary(uniqueKeysWithValues: keys.map { key -> (String, ProvisioningProfileValue) in
            if key == push { return (key, .string("development")) }
            if booleans.contains(key) { return (key, .boolean(true)) }
            return (key, .array([.string("synthetic")]))
        })
        let result = try analyze(values, profile: profile(values))
        XCTAssertEqual(result.rows.count, keys.count)
        XCTAssertEqual(result.rows.first(where: { $0.key == push })?.capability.name, "Push Notifications")
        XCTAssertEqual(result.rows.last(where: { $0.key == "future.example.key" })?.capability.name, "future.example.key")
        XCTAssertEqual(result.count(.unknown), 1)
        XCTAssertEqual(result.count(.compatible), 9)
        XCTAssertEqual(result.status, .warning, "Parsed declarations must not imply authenticated authorization.")
    }

    func testMissingAppIsNotAnEmptyVerifiedSet() throws {
        let absent = try analyze(nil)
        let empty = try analyze([:], profile: profile([:]))
        XCTAssertEqual(absent.checks.first?.status, .unknown)
        XCTAssertEqual(empty.checks.first?.status, .compatible)
        XCTAssertEqual(absent.status, .warning)
        XCTAssertEqual(empty.status, .warning)
    }

    func testNoProfileIsUnknownAndMissingClaimIsBlocked() throws {
        XCTAssertEqual(try analyze([push: .string("development")]).rows.first?.finding.status, .unknown)
        let missing = try analyze([push: .string("development")], profile: profile([:]))
        XCTAssertEqual(missing.count(.blocked), 1)
        XCTAssertEqual(missing.status, .blocked)
        XCTAssertTrue(missing.rows[0].finding.message.contains("Choose a profile"))
    }

    func testScalarTypesDoNotCoerceAndDifferencesAreVisible() throws {
        let result = try analyze([push: .boolean(true)], profile: profile([push: .integer(1)]))
        XCTAssertEqual(result.rows[0].finding.status, .blocked)
        XCTAssertEqual(result.rows[0].value, .boolean(true))
        XCTAssertEqual(result.rows[0].profileValue, .integer(1))
    }

    func testMatchingButUnsupportedCapabilityShapeIsNotSupported() throws {
        let result = try analyze([push: .boolean(true)], profile: profile([push: .boolean(true)]))
        XCTAssertEqual(result.rows[0].finding.status, .unknown)
    }

    func testTeamAndBundleChecksUseDeclaredBoundaries() throws {
        let matching = try analyze([:], profile: profile([:]))
        XCTAssertEqual(matching.checks.first { $0.id == "team" }?.status, .compatible)
        XCTAssertEqual(matching.checks.first { $0.id == "bundle" }?.status, .compatible)
        let wrong = try analyze([:], profile: profile([:], identifier: "PREFIX.net.other.app"), team: "OTHER")
        XCTAssertEqual(wrong.checks.first { $0.id == "team" }?.status, .blocked)
        XCTAssertEqual(wrong.checks.first { $0.id == "bundle" }?.status, .blocked)
        XCTAssertEqual(wrong.status, .blocked)
    }

    func testApplicationPrefixIsNotAssumedToEqualTeam() throws {
        let key = "application-identifier"
        let good = try analyze([key: .string("PREFIX.com.example.app")], profile: profile([key: .string("PREFIX.com.example.*")]))
        XCTAssertEqual(good.rows[0].finding.status, .compatible)
        let bad = try analyze([key: .string("PREFIX.com.example.other")], profile: profile([key: .string("PREFIX.com.example.*")]))
        XCTAssertEqual(bad.rows[0].finding.status, .blocked)
    }

    func testWildcardsSubsetsAndUnsupportedValuesStayUncertain() throws {
        let key = "keychain-access-groups"
        let wildcard = try analyze([key: .array([.string("PREFIX.com.example.app")])], profile: profile([key: .array([.string("PREFIX.*")])]))
        XCTAssertEqual(wildcard.rows[0].finding.status, .warning)
        let subset = try analyze([key: .array([.string("a")])], profile: profile([key: .array([.string("a"), .string("b")])]))
        XCTAssertEqual(subset.rows[0].finding.status, .warning)
        let unsupported = try analyze([push: .data(Data([1]))], profile: profile([push: .data(Data([1]))]))
        XCTAssertEqual(unsupported.rows[0].finding.status, .unknown)
    }

    func testDebuggingFalseIsNotAssumedEquivalentToAbsence() throws {
        let key = "get-task-allow"
        XCTAssertEqual(try analyze([key: .boolean(false)], profile: profile([:])).rows[0].finding.status, .warning)
        XCTAssertEqual(try analyze([key: .boolean(true)], profile: profile([:])).rows[0].finding.status, .blocked)
        XCTAssertEqual(try analyze([key: .boolean(false)], profile: profile([key: .boolean(true)])).rows[0].finding.status, .warning)
        XCTAssertEqual(try analyze([key: .boolean(false)], profile: profile([key: .boolean(false)])).rows[0].finding.status, .compatible)
    }

    func testSearchAllFieldsAndStatusIntersection() throws {
        let result = try analyze([push: .string("development"), "future.key": .integer(42)], profile: profile([push: .string("development"), "future.key": .integer(42)]))
        for query in [" push ", "APS-ENVIRONMENT", "notifications", "compatible"] {
            XCTAssertEqual(result.filtered(query: query, status: nil).map(\.key), [push])
        }
        XCTAssertTrue(result.filtered(query: "push", status: .blocked).isEmpty)
        XCTAssertEqual(result.filtered(query: "", status: .unknown).map(\.key), ["future.key"])
        XCTAssertTrue(result.filtered(query: "no match", status: nil).isEmpty)
    }

    func testConfigurationChangesDoNotRewriteAppClaims() throws {
        let values: [String: ProvisioningProfileValue] = [push: .string("production")]
        let xml = try analyze(values, profile: profile(values))
        let der = try analyze(values, profile: profile(values), der: true)
        XCTAssertEqual(xml.rows, der.rows)
        XCTAssertNotEqual(xml.checks.first { $0.id == "encoding" }, der.checks.first { $0.id == "encoding" })
        XCTAssertEqual(xml.rows[0].finding.diagnosticCategory, nil)
    }

    func testExportIsTimestampedCompleteAndExcludesUnknownValuesAndBinaryContent() throws {
        let values: [String: ProvisioningProfileValue] = [push: .string("development"), "future.secret": .string("do-not-export-this"), "future.bytes": .data(Data("opaque-payload".utf8))]
        let result = try analyze(values, profile: profile(values))
        let report = EntitlementsStudioReport(name: "Synthetic", bundleID: bundleID.rawValue, target: "Architecture 1", analysis: result, date: Date(timeIntervalSince1970: 0))
        let data = try report.data()
        let text = String(decoding: data, as: UTF8.self)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["generatedAt"] as? String, "1970-01-01T00:00:00Z")
        XCTAssertEqual(json["totalEntitlements"] as? Int, 3)
        XCTAssertEqual((json["entitlements"] as? [[String: Any]])?.count, 3)
        XCTAssertFalse(text.contains("do-not-export-this"))
        XCTAssertFalse(text.contains("opaque-payload"))
        XCTAssertTrue(text.contains("aps-environment"))
        XCTAssertTrue(text.contains("development"))
        XCTAssertNil(json["profileData"])
        XCTAssertNil(json["certificate"])
    }

    func testTenThousandUnknownKeysRemainSearchable() throws {
        let values = Dictionary(uniqueKeysWithValues: (0..<10_000).map { ("future.key.\($0)", ProvisioningProfileValue.boolean(true)) })
        let result = try analyze(values, profile: profile(values))
        XCTAssertEqual(result.rows.count, 10_000)
        XCTAssertEqual(result.count(.unknown), 10_000)
        XCTAssertEqual(result.filtered(query: "future.key.9999", status: .unknown).count, 1)
    }
}
