import XCTest
@testable import ZynSign

/// Tests for the checks that run before anything is copied.
///
/// Preflight is deliberately shallow, so these tests are about the two things
/// it must get right: refusing what cannot possibly be imported — cheaply, and
/// with a reason that names what was observed — and *not* refusing what it
/// merely could not observe, because a provider that cannot describe its item
/// is not evidence that the item is unusable.
@MainActor
final class ImportPreflightTests: XCTestCase {

    private let source = ImportFixtures.sourceURL()

    private func describe(
        byteCount: Int? = 1_024,
        kind: ImportSourceDescription.Kind = .regularFile,
        signature: Bool? = true
    ) -> ImportSourceDescription {
        ImportSourceDescription(
            fileName: "Example.ipa",
            byteCount: byteCount,
            kind: kind,
            beginsWithArchiveSignature: signature
        )
    }

    private func refusal(
        _ description: ImportSourceDescription,
        from url: URL? = nil
    ) -> ZynSignError? {
        do {
            try ImportPreflight.validate(url ?? source, describedBy: description)
            return nil
        } catch let error as ZynSignError {
            return error
        } catch {
            XCTFail("Expected a typed refusal, got \(error)")
            return nil
        }
    }

    // MARK: - Accepting

    func testAFileThatLooksLikeAPackagePassesAndIsStillUntrusted() throws {
        XCTAssertNil(refusal(describe()))
        // Passing preflight says only that the file is worth copying: it is
        // not a statement about the archive, its content, or its origins.
        XCTAssertNoThrow(try ImportPreflight.validate(source, describedBy: describe()))
    }

    func testAnUnobservableSignatureIsNotARefusal() throws {
        XCTAssertNil(refusal(describe(signature: nil)))
    }

    func testAnUnobservableSizeIsNotARefusal() throws {
        XCTAssertNil(refusal(describe(byteCount: nil)))
    }

    func testAnUnknownKindIsNotARefusal() throws {
        // A provider that cannot describe its item — a placeholder, a link, a
        // package directory — is not evidence that the item is unusable.
        XCTAssertNil(refusal(describe(kind: .unknown)))
    }

    // MARK: - Refusing

    func testADirectoryIsRefusedAsUnsupportedInput() throws {
        let error = refusal(describe(kind: .directory))
        XCTAssertEqual(error?.category, .unsupportedInput)
    }

    func testAFileWithoutThePackageExtensionIsRefused() throws {
        let error = refusal(describe(), from: ImportFixtures.sourceURL(name: "Example.txt"))
        XCTAssertEqual(error?.category, .unsupportedInput)
    }

    func testAnEmptyFileIsRefusedAsInvalidInput() throws {
        let error = try XCTUnwrap(refusal(describe(byteCount: 0)))
        XCTAssertEqual(error.category, .invalidInput)
        // The refusal reaches the interface as a refusal, not as a failure:
        // nothing went wrong, the file simply is not a package.
        let settlement = ImportSettlement.from(error: error)
        XCTAssertEqual(settlement.kind, .rejected)
        XCTAssertEqual(settlement.isRetryable, false)
    }

    func testAFileBeyondTheCeilingIsRefusedBeforeAnythingIsCopied() throws {
        let oversized = describe(byteCount: ImportPreflight.maximumCandidateByteCount + 1)
        let error = refusal(oversized)
        XCTAssertEqual(error?.category, .unsupportedInput)

        // The ceiling itself is acceptable: the limit is a ceiling, not an
        // exclusive bound.
        XCTAssertNil(refusal(describe(byteCount: ImportPreflight.maximumCandidateByteCount)))
    }

    func testAFileThatDoesNotBeginLikeAnArchiveIsRefused() throws {
        let error = refusal(describe(signature: false))
        XCTAssertEqual(error?.category, .invalidInput)
    }

    func testTheCeilingIsFourGibibytes() {
        XCTAssertEqual(ImportPreflight.maximumCandidateByteCount, 4 * 1_024 * 1_024 * 1_024)
    }
}
