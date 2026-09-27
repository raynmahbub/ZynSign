import Foundation
import XCTest
@testable import ZynSign

final class ReleaseReadinessTests: XCTestCase {
    private func check(_ category: ReleaseReadinessCategory, _ state: ReleaseCheckState,
                       id: String? = nil) -> ReleaseReadinessCheck {
        ReleaseReadinessCheck(id: id ?? category.rawValue, category: category, state: state,
            title: category.title, explanation: "Fixed explanation", technicalDetails: "Fixed scope", nextAction: "Rescan")
    }
    private func report(_ checks: [ReleaseReadinessCheck], recordID: String = "opaque-app") -> ReleaseReadinessReport {
        ReleaseReadinessReport(id: UUID(), recordID: recordID, exportID: nil,
            validatedAt: Date(timeIntervalSince1970: 1_700_000_000), checks: checks)
    }
    func testWeightsTotalOneHundredAndFullyVerifiedIsReady() {
        XCTAssertEqual(ReleaseReadinessCategory.allCases.reduce(0) { $0 + $1.weight }, 100)
        let value = report(ReleaseReadinessCategory.allCases.map { check($0, .verified) })
        XCTAssertEqual(value.score, 100)
        XCTAssertEqual(value.status, "Ready")
        XCTAssertEqual(value.successfulCount, 6)
    }
    func testNoEvidenceNeverReceivesPoints() {
        let value = report([])
        XCTAssertEqual(value.score, 0)
        XCTAssertEqual(value.status, "Attention")
        XCTAssertEqual(value.state(for: .signature), .notChecked)
    }
    func testBlockerAlwaysWinsAndDeductionUsesCategoryWeight() {
        var checks = ReleaseReadinessCategory.allCases.map { check($0, .verified) }
        checks.append(check(.identity, .blocked, id: "expired"))
        let value = report(checks)
        XCTAssertEqual(value.status, "Blocked")
        XCTAssertEqual(value.score, 85)
        XCTAssertEqual(value.blockers.count, 1)
        XCTAssertTrue(value.plainText.contains("Identity: Blocked, 0/15 points; deduction 15."))
    }
    func testWarningsAreSeparateAndDoNotBlock() {
        var checks = ReleaseReadinessCategory.allCases.map { check($0, .verified) }
        checks.append(check(.profile, .warning, id: "expiring"))
        let value = report(checks)
        XCTAssertEqual(value.status, "Attention")
        XCTAssertEqual(value.score, 92) // floor(15 / 2), deduction 8
        XCTAssertEqual(value.warnings.count, 1)
        XCTAssertTrue(value.blockers.isEmpty)
    }
    func testUnsupportedAndUncheckedAreNeverPassesAndOutrankWarning() {
        let value = report([check(.signature, .verified),
                            check(.signature, .warning, id: "warning"),
                            check(.signature, .unsupported, id: "cmsUnsupported"),
                            check(.package, .notChecked)])
        XCTAssertEqual(value.state(for: .signature), .unsupported)
        XCTAssertEqual(value.score, 0)
        XCTAssertEqual(value.information.count, 2)
        XCTAssertEqual(value.status, "Attention")
    }
    func testHistoricalReportRoundTripRetainsEvidenceAndExportIsExplicitlyScoped() throws {
        let value = report([check(.structure, .verified), check(.signature, .unsupported)])
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(ReleaseReadinessReport.self, from: data)
        XCTAssertEqual(decoded.id, value.id)
        XCTAssertEqual(decoded.checks, value.checks)
        XCTAssertEqual(decoded.plainText, value.plainText)
        XCTAssertTrue(decoded.plainText.contains("Historical observation"))
        XCTAssertTrue(decoded.plainText.contains("App record: opaque-app"))
        XCTAssertTrue(decoded.plainText.contains("None selected"))
        XCTAssertTrue(decoded.plainText.contains("revocation"))
    }
    func testInputAdapterDoesNotPromoteOldSignatureStructureIntoVerification() {
        let source = SigningDiagnosticsReport(recordID: ApplicationRecordIdentifier(), analyzedAt: Date(),
            checks: [.init(area: .existingSignature, state: .passed),
                     .init(area: .certificate, state: .blocked),
                     .init(area: .profile, state: .unsupported),
                     .init(area: .entitlements, state: .notChecked)], issues: [])
        let checks = ReleaseReadinessService.inputChecks(source)
        XCTAssertFalse(checks.contains { $0.category == .signature })
        XCTAssertEqual(checks.first { $0.category == .identity }?.state, .blocked)
        XCTAssertEqual(checks.first { $0.category == .profile }?.state, .unsupported)
        XCTAssertEqual(checks.first { $0.category == .entitlements }?.state, .notChecked)
    }
    func testHistoryRetainsTenPerAppAndReopensCompleteReports() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let location = directory.appendingPathComponent("reports.json")
        let store = ReleaseReadinessHistory(location: location)
        for _ in 0..<12 { try await store.append(report([check(.structure, .verified)])) }
        let latest = report([check(.identity, .blocked)], recordID: "other-app")
        try await store.append(latest)
        let reopened = ReleaseReadinessHistory(location: location)
        let saved = try await reopened.reports()
        XCTAssertEqual(saved.count, 11)
        XCTAssertEqual(saved.first?.id, latest.id)
        XCTAssertEqual(saved.first?.checks, latest.checks)
        XCTAssertEqual(saved.filter { $0.recordID == "opaque-app" }.count, 10)
    }
    func testCorruptHistoryIsNotSilentlyOverwritten() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let location = directory.appendingPathComponent("reports.json")
        let corrupt = Data("not a report".utf8)
        try corrupt.write(to: location)
        let store = ReleaseReadinessHistory(location: location)
        do {
            try await store.append(report([]))
            XCTFail("Corrupt history must not be reset")
        } catch { }
        XCTAssertEqual(try Data(contentsOf: location), corrupt)
    }
    func testHistoryGlobalCapacity() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ReleaseReadinessHistory(location: directory.appendingPathComponent("reports.json"))
        for index in 0..<52 { try await store.append(report([], recordID: "app-\(index)")) }
        let saved = try await store.reports()
        XCTAssertEqual(saved.count, 50)
        XCTAssertEqual(saved.first?.recordID, "app-51")
    }
}
