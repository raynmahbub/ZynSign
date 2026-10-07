import Foundation
import UniformTypeIdentifiers
import XCTest
@testable import ZynSign

/// Tests for the route a dropped file is read through — the decision that
/// decides whether a drag from Files becomes an import or vanishes without a
/// word.
///
/// Only the *choice* is tested here; carrying bytes out of a live
/// `NSItemProvider` needs a running app and a real drag, which the documented
/// private test gate covers.
final class DropInboxFileReceiverTests: XCTestCase {

    func testTheMostSpecificRegisteredFileTypeIsRequested() {
        XCTAssertEqual(
            DropInboxFileReceiver.loadPlan(
                registeredTypes: [UTType.fileURL.identifier, UTType.zip.identifier],
                hasFileURL: true,
                hasData: true
            ),
            .representation(typeIdentifier: UTType.zip.identifier),
            "a provider that names the file's own type is asked for that type"
        )
    }

    func testAProviderThatCarriesOnlyAFileURLIsReadThroughThatURL() {
        // A file dragged out of Files very often registers nothing that
        // conforms to `public.data` — a file URL conforms to `public.item`.
        // A data-only filter reported the drop as unusable and the hub never
        // saw the package, which is what made the drop zone look dead.
        XCTAssertEqual(
            DropInboxFileReceiver.loadPlan(
                registeredTypes: [UTType.fileURL.identifier],
                hasFileURL: true,
                hasData: false
            ),
            .referencedFile
        )
    }

    func testAProviderOfferingNothingButPlainDataIsAskedForData() {
        XCTAssertEqual(
            DropInboxFileReceiver.loadPlan(
                registeredTypes: [],
                hasFileURL: false,
                hasData: true
            ),
            .representation(typeIdentifier: UTType.data.identifier)
        )
    }

    func testAProviderWithNothingUsableIsReportedRatherThanIgnored() {
        XCTAssertNil(
            DropInboxFileReceiver.loadPlan(
                registeredTypes: ["com.example.unknown-payload"],
                hasFileURL: false,
                hasData: false
            ),
            "nothing to read is a refusal the hub can account for, not a silent drop"
        )
    }

    func testTheInboxKeepsTheDroppedFileNameAndMakesItOnePathComponent() {
        XCTAssertEqual(
            DropInboxFileReceiver.fileName(
                for: URL(fileURLWithPath: "/tmp/App 2.ipa"),
                suggestedName: nil,
                typeIdentifier: UTType.data.identifier
            ),
            "App 2.ipa"
        )
        XCTAssertEqual(
            DropInboxFileReceiver.fileName(
                for: URL(fileURLWithPath: "/tmp/Weird:Name.ipa"),
                suggestedName: nil,
                typeIdentifier: UTType.data.identifier
            ),
            "Weird_Name.ipa",
            "a name gets to say what the file is called, not where it lands"
        )
    }

    func testANameWithoutAnExtensionTakesThePreferredOneOfItsType() {
        XCTAssertEqual(
            DropInboxFileReceiver.fileName(
                for: URL(fileURLWithPath: "/tmp/package"),
                suggestedName: nil,
                typeIdentifier: UTType.zip.identifier
            ),
            "package.zip"
        )
        XCTAssertEqual(
            DropInboxFileReceiver.fileName(
                for: URL(fileURLWithPath: "/tmp/package"),
                suggestedName: nil,
                typeIdentifier: "com.example.unknown-payload"
            ),
            "package",
            "a type that has no extension invents none"
        )
    }

    // MARK: - What the receiver is allowed to delete

    func testADropCopyIsDeletedWithTheFolderThatHoldsIt() throws {
        let root = try makeScratchRoot()
        let inbox = root.appendingPathComponent("DropInbox", isDirectory: true)
        let receiver = DropInboxFileReceiver(directory: inbox, sharedInboxDirectory: nil)
        let folder = inbox.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let copy = folder.appendingPathComponent("App.ipa")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("ipa".utf8).write(to: copy)

        receiver.release(copy)

        XCTAssertFalse(FileManager.default.fileExists(atPath: copy.path))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: folder.path),
            "an empty per-file folder is not left behind to be swept later"
        )
    }

    func testAHandOffCopyInSharedInboxIsReleasedWhenTheImportIsDone() throws {
        let root = try makeScratchRoot()
        let shared = root.appendingPathComponent("SharedInbox", isDirectory: true)
        let receiver = DropInboxFileReceiver(
            directory: root.appendingPathComponent("DropInbox", isDirectory: true),
            sharedInboxDirectory: shared
        )
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
        let handedOver = shared.appendingPathComponent("App.ipa")
        try Data("ipa".utf8).write(to: handedOver)
        XCTAssertTrue(FileManager.default.fileExists(atPath: handedOver.path))

        receiver.release(handedOver)

        XCTAssertFalse(FileManager.default.fileExists(atPath: handedOver.path))
    }

    func testSweepNeverTouchesTheSharedInboxAHandOffMayStillBeReadFrom() throws {
        // The system places the copy in `Documents/Inbox` and only then launches
        // ZynSign to read it — so a sweep that cleared that folder at launch
        // could delete the file the app was started for, or the one a running
        // staging copy is still reading.
        let root = try makeScratchRoot()
        let inbox = root.appendingPathComponent("DropInbox", isDirectory: true)
        let shared = root.appendingPathComponent("SharedInbox", isDirectory: true)
        let receiver = DropInboxFileReceiver(directory: inbox, sharedInboxDirectory: shared)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: inbox.appendingPathComponent("gone.ipa"))
        let awaiting = shared.appendingPathComponent("App.ipa")
        try Data("ipa".utf8).write(to: awaiting)

        receiver.sweep()

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: inbox.appendingPathComponent("gone.ipa").path),
            "a drop copy no import claims is swept away"
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: awaiting.path))
    }

    func testNothingZynSignDidNotParkIsEverReleased() throws {
        let root = try makeScratchRoot()
        let inbox = root.appendingPathComponent("DropInbox", isDirectory: true)
        let shared = root.appendingPathComponent("SharedInbox", isDirectory: true)
        let receiver = DropInboxFileReceiver(directory: inbox, sharedInboxDirectory: shared)
        let usersFile = root.appendingPathComponent("App.ipa")
        try Data("mine".utf8).write(to: usersFile)
        // Inside the shared inbox's tree, but not a hand-off's own copy.
        let nestedFolder = shared.appendingPathComponent("Nested", isDirectory: true)
        let nested = nestedFolder.appendingPathComponent("App.ipa")
        try FileManager.default.createDirectory(at: nestedFolder, withIntermediateDirectories: true)
        try Data("nested".utf8).write(to: nested)

        receiver.release(usersFile)
        receiver.release(nested)

        XCTAssertTrue(FileManager.default.fileExists(atPath: usersFile.path), "a file the user chose is never the receiver's to delete")
        XCTAssertTrue(FileManager.default.fileExists(atPath: nested.path))
    }

    /// A scratch folder removed with the test.
    private func makeScratchRoot() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("ZynSign.DropInboxTests." + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
}
