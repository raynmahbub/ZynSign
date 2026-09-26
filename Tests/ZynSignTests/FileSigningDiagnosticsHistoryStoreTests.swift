import Foundation
import XCTest
@testable import ZynSign

final class FileSigningDiagnosticsHistoryStoreTests: XCTestCase {
    private var directory: URL!
    private var location: URL { directory.appendingPathComponent("SigningDiagnostics.json") }

    override func setUpWithError() throws {
        directory = try LibraryFixtures.makeTemporaryDirectory()
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
    }

    func testRepeatedObservationUpdatesTimeButPreservesPreviousDifferentResult() async throws {
        let id = LibraryFixtures.record().id
        let store = FileSigningDiagnosticsHistoryStore(location: location, capacityPerApp: 3)
        let blocked = SigningDiagnosticSnapshot(report: report(id: id, second: 0, code: .profileMissing))
        let firstReady = SigningDiagnosticSnapshot(report: report(id: id, second: 1))
        let newerReady = SigningDiagnosticSnapshot(report: report(id: id, second: 2))
        try await store.append(blocked)
        try await store.append(firstReady)
        try await store.append(newerReady)

        let scans = try await store.recent(for: id)
        XCTAssertEqual(scans.count, 2)
        XCTAssertEqual(scans.first?.analyzedAt, newerReady.analyzedAt)
        XCTAssertEqual(scans.first?.id, newerReady.id)
        XCTAssertEqual(scans.last?.issueCodes, [.profileMissing])
        XCTAssertEqual(newerReady.changes(since: firstReady)?.isEmpty, true)
        XCTAssertEqual(firstReady.changes(since: blocked)?.resolved, [.profileMissing])

        let reopened = FileSigningDiagnosticsHistoryStore(location: location)
        let persisted = try await reopened.recent(for: id)
        XCTAssertEqual(persisted, scans)
    }

    func testPerAppAndTotalCapacitiesPruneOldestSnapshots() async throws {
        let firstID = LibraryFixtures.record().id
        let secondID = LibraryFixtures.record().id
        let store = FileSigningDiagnosticsHistoryStore(
            location: location, capacityPerApp: 3, totalCapacity: 4
        )
        let codes: [SigningDiagnosticCode] = [
            .packageMissing, .packageChanged, .profileMissing, .certificateMissing, .entitlementsInvalid
        ]
        for (index, code) in codes.enumerated() {
            try await store.append(SigningDiagnosticSnapshot(report: report(
                id: firstID, second: index, code: code
            )))
        }
        var first = try await store.recent(for: firstID)
        XCTAssertEqual(first.count, 3)
        XCTAssertEqual(first.compactMap { $0.issueCodes.first }, Array(codes.suffix(3).reversed()))

        for index in 0..<2 {
            try await store.append(SigningDiagnosticSnapshot(report: report(
                id: secondID, second: 10 + index, code: index == 0 ? .teamMismatch : .bundleMismatch
            )))
        }
        first = try await store.recent(for: firstID)
        let second = try await store.recent(for: secondID)
        XCTAssertEqual(first.count + second.count, 4)
        XCTAssertEqual(second.count, 2)
    }

    func testHistoryStoresOnlyCodesAndRemovingUnknownAppCreatesNoFile() async throws {
        let store = FileSigningDiagnosticsHistoryStore(location: location)
        try await store.remove(for: LibraryFixtures.record().id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: location.path))

        let record = LibraryFixtures.record()
        try await store.append(SigningDiagnosticSnapshot(report: report(
            id: record.id, second: 0, code: .bundleMismatch
        )))
        let document = try String(contentsOf: location, encoding: .utf8)
        XCTAssertTrue(document.contains(SigningDiagnosticCode.bundleMismatch.rawValue))
        XCTAssertFalse(document.contains("private profile bytes"))
        XCTAssertFalse(document.contains("private entitlement claim"))
        try await store.remove(for: record.id)
        // An older in-flight scan cannot reinsert this deleted app's history.
        try await store.append(SigningDiagnosticSnapshot(report: report(
            id: record.id, second: 1, code: .certificateMissing
        )))
        let remaining = try await store.recent(for: record.id)
        XCTAssertTrue(remaining.isEmpty)
    }

    func testCorruptedHistoryIsNotSilentlyDiscarded() async throws {
        try Data("not json".utf8).write(to: location)
        let store = FileSigningDiagnosticsHistoryStore(location: location)
        do {
            _ = try await store.recent(for: LibraryFixtures.record().id)
            XCTFail("A damaged journal must not masquerade as an empty history.")
        } catch is SigningDiagnosticHistoryError {
            // Current analysis can still be displayed; history is marked unavailable.
        }
    }

    private func report(
        id: ApplicationRecordIdentifier, second: Int,
        code: SigningDiagnosticCode? = nil
    ) -> SigningDiagnosticsReport {
        let issue = code.map { code in
            SigningDiagnostic(id: code, area: .package, severity: .error,
                              title: "Private profile bytes", explanation: "private entitlement claim",
                              technicalDetails: "private profile bytes", suggestedAction: "none")
        }
        return SigningDiagnosticsReport(
            recordID: id,
            analyzedAt: Date(timeIntervalSince1970: 1_800_000_000 + Double(second)),
            checks: [SigningDiagnosticCheck(area: .package, state: code == nil ? .passed : .blocked)],
            issues: issue.map { [$0] } ?? []
        )
    }
}
