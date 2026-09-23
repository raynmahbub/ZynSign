import Foundation
import XCTest
@testable import ZynSign

/// The artifact half of the provisioning-profile integration: finding and reading
/// one `embedded.mobileprovision` entry, and feeding it to the pipeline.
///
/// These tests hold the boundary in place. The intake reads a container's entry
/// table and, at most, the content of one named entry; it never extracts, writes,
/// or parses anything; it never concludes that a profile is valid, authenticated,
/// or usable; and a package it cannot vouch for is reported as unreadable input
/// rather than opened anyway.
final class BundleProvisioningProfileIntakeTests: XCTestCase {

    private static let bundleName = "Example.app"
    private static let profileName = IPALayout.embeddedProvisioningProfileFileName
    private static let profilePath = "Payload/\(Self.bundleName)/\(Self.profileName)"

    // MARK: - Discovery and reading

    func testTheEmbeddedProfileEntryIsReadAndNothingElse() throws {
        let content = Data(repeating: 0x70, count: 1_024)
        let reader = SyntheticArchiveReader(
            entryTable: Self.table(withProfile: content),
            contentByPath: [Self.profilePath: content, "Payload/Example.app/Info.plist": Data(repeating: 1, count: 4_096)]
        )
        let entry = libraryEntry(artifact: content)
        let profile = BundleProvisioningProfileIntake(readerProvider: SyntheticArchiveReaderProvider.providing(reader))
            .profile(in: entry)

        XCTAssertEqual(profile, .bytes(content))
        XCTAssertEqual(reader.requestedPaths, [makePath(Self.profilePath)], "One entry's content, ever.")
        XCTAssertEqual(reader.closeCount, 1, "The reader is closed after exactly one look.")
    }

    func testABundleWithoutAProfileEntryReportsTheAbsenceNotADefect() throws {
        var table = Self.table(withProfile: nil)
        table.append(makeEntry("Payload/Example.app/Info.plist", uncompressedSize: 128))
        let reader = SyntheticArchiveReader(entryTable: table)
        let entry = libraryEntry(artifact: Data(repeating: 0x11, count: 256))

        let profile = BundleProvisioningProfileIntake(readerProvider: SyntheticArchiveReaderProvider.providing(reader))
            .profile(in: entry)

        XCTAssertEqual(profile, .notFound)
        XCTAssertTrue(reader.requestedPaths.isEmpty, "An absent entry is answered from the table, without a content read.")
        XCTAssertEqual(reader.closeCount, 1)
    }

    func testALinkOrDirectoryAtTheProfileLocationIsNotRead() throws {
        for kind in [ArchiveEntryKind.symbolicLink, .directory, .unsupported] {
            let table: [ArchiveEntry] = [
                makeEntry("Payload", kind: .directory),
                makeEntry("Payload/Example.app", kind: .directory),
                makeEntry(Self.profilePath, kind: kind),
            ]
            let reader = SyntheticArchiveReader(entryTable: table)
            let profile = BundleProvisioningProfileIntake(
                readerProvider: SyntheticArchiveReaderProvider.providing(reader)
            ).profile(in: libraryEntry(artifact: Data(repeating: 0x22, count: 64)))

            XCTAssertEqual(profile, .unusable(.entryNotRegularFile), "\(kind.rawValue) is not a file to read.")
            XCTAssertTrue(reader.requestedPaths.isEmpty)
        }
    }

    func testHugeDeclaredSizesCostNothingBeyondTheEntryTable() throws {
        let table: [ArchiveEntry] = [
            makeEntry("Payload", kind: .directory),
            makeEntry("Payload/Example.app", kind: .directory),
            makeEntry(Self.profilePath, uncompressedSize: 1_073_741_824, compressedSize: 8),
        ]
        let reader = SyntheticArchiveReader(
            entryTable: table,
            contentByPath: [Self.profilePath: Data(repeating: 0x33, count: 32)]
        )

        let profile = BundleProvisioningProfileIntake(
            readerProvider: SyntheticArchiveReaderProvider.providing(reader)
        ).profile(in: libraryEntry(artifact: Data(repeating: 0x33, count: 32)))

        XCTAssertEqual(profile, .bytes(Data(repeating: 0x33, count: 32)))
        XCTAssertEqual(reader.requestedPaths.count, 1, "A declared size is a declaration; the bound that matters is the reader's.")
    }

    func testAnEntryLargerThanTheReadBoundIsUnreadableNotTruncated() throws {
        let limits = ArchiveLimits(
            maximumEntryCount: 100,
            maximumEntryNameLength: 4_096,
            maximumPathDepth: 32,
            maximumEntryBytes: 1_024,
            maximumTotalUncompressedBytes: 4_096,
            maximumCompressionRatio: 1_000,
            maximumInspectionReadBytes: 64
        )
        let content = Data(repeating: 0x44, count: 65)
        let reader = SyntheticArchiveReader(
            entryTable: Self.table(withProfile: content),
            contentByPath: [Self.profilePath: content]
        )
        let intake = BundleProvisioningProfileIntake(
            readerProvider: SyntheticArchiveReaderProvider.providing(reader),
            limits: limits
        )

        XCTAssertEqual(intake.maximumReadBytes, 64)
        XCTAssertEqual(intake.profile(in: libraryEntry(artifact: content)), .unusable(.entryUnreadable))
    }

    // MARK: - Containers that will not answer

    func testAMissingArtifactIsNotOpenedAtAll() throws {
        let provider = CountingReaderProvider(entryTable: Self.table(withProfile: Data(repeating: 0x55, count: 8)))
        let profile = BundleProvisioningProfileIntake(readerProvider: provider)
            .profile(in: LibraryEntry(
                record: LibraryFixtures.record(),
                artifactAvailability: .missing
            ))

        XCTAssertEqual(profile, .unusable(.artifactUnavailable))
        XCTAssertEqual(provider.openCount, 0, "Nothing ZynSign cannot vouch for is opened.")
    }

    func testAnInconsistentArtifactIsNotOpenedEither() throws {
        let provider = CountingReaderProvider(entryTable: Self.table(withProfile: Data(repeating: 0x55, count: 8)))
        let profile = BundleProvisioningProfileIntake(readerProvider: provider)
            .profile(in: LibraryEntry(
                record: LibraryFixtures.record(),
                artifactAvailability: .inconsistent(recordedByteCount: 4_096, observedByteCount: 16)
            ))

        XCTAssertEqual(profile, .unusable(.artifactUnavailable))
        XCTAssertEqual(provider.openCount, 0)
    }

    func testAContainerThatCannotBeOpenedOrEnumeratedIsUnusableInput() throws {
        let failingOpen = BundleProvisioningProfileIntake(
            readerProvider: SyntheticArchiveReaderProvider.failing(with: ZynSignError.unreadableArtifact(diagnosticDetail: "synthetic"))
        ).profile(in: libraryEntry(artifact: Data(repeating: 0x66, count: 8)))
        XCTAssertEqual(failingOpen, .unusable(.containerUnreadable))

        let reader = SyntheticArchiveReader(
            entryTable: Self.table(withProfile: Data(repeating: 0x66, count: 8)),
            failure: .entryTableUnreadable
        )
        let failingTable = BundleProvisioningProfileIntake(
            readerProvider: SyntheticArchiveReaderProvider.providing(reader)
        ).profile(in: libraryEntry(artifact: Data(repeating: 0x66, count: 8)))
        XCTAssertEqual(failingTable, .unusable(.containerUnreadable))
        XCTAssertEqual(reader.closeCount, 1, "A reader is closed on a failed path too.")
    }

    func testContentThatCannotBeProducedIsUnreadableNotCorrupt() throws {
        let reader = SyntheticArchiveReader(
            entryTable: Self.table(withProfile: Data(repeating: 0x77, count: 8)),
            failure: .contentUnreadable
        )
        let profile = BundleProvisioningProfileIntake(
            readerProvider: SyntheticArchiveReaderProvider.providing(reader)
        ).profile(in: libraryEntry(artifact: Data(repeating: 0x77, count: 8)))

        XCTAssertEqual(profile, .unusable(.entryUnreadable))
        XCTAssertEqual(reader.closeCount, 1)
    }

    func testAPackageWithNoSingleBundleIsNotResolvedByChoosingOne() throws {
        let noBundle = BundleProvisioningProfileIntake(
            readerProvider: SyntheticArchiveReaderProvider.providing(
                SyntheticArchiveReader(entryTable: [makeEntry("Payload", kind: .directory)])
            )
        ).profile(in: libraryEntry(artifact: Data(repeating: 0x01, count: 8)))
        XCTAssertEqual(noBundle, .unusable(.applicationBundleAbsent))

        let twoBundles = BundleProvisioningProfileIntake(
            readerProvider: SyntheticArchiveReaderProvider.providing(
                SyntheticArchiveReader(entryTable: [
                    makeEntry("Payload", kind: .directory),
                    makeEntry("Payload/Example.app", kind: .directory),
                    makeEntry("Payload/Other.app", kind: .directory),
                    makeEntry("Payload/Example.app/\(Self.profileName)"),
                    makeEntry("Payload/Other.app/\(Self.profileName)"),
                ])
            )
        ).profile(in: libraryEntry(artifact: Data(repeating: 0x01, count: 8)))
        XCTAssertEqual(twoBundles, .unusable(.applicationBundleAmbiguous))
    }

    // MARK: - Into the pipeline

    func testBytesReadFromABundleDriveTheWholePipeline() throws {
        let container = CMSFixtures.validRSASignedAttributes
        let reader = SyntheticArchiveReader(
            entryTable: Self.table(withProfile: container),
            contentByPath: [Self.profilePath: container]
        )
        let profile = BundleProvisioningProfileIntake(
            readerProvider: SyntheticArchiveReaderProvider.providing(reader)
        ).profile(in: libraryEntry(artifact: container))
        guard case .bytes(let bytes) = profile else {
            return XCTFail("Expected the fixture container to be read back exactly, got \(profile).")
        }
        XCTAssertEqual(bytes, container, "The intake neither re-encodes nor shortens what it reads.")

        let request = ValidateProvisioningProfileRequest(
            profile: profile,
            profileOrigin: .embeddedBundleEntry,
            applicationMetadata: ProvisioningPolicyFixtures.applicationMetadata(),
            signingIdentityID: ProvisioningPolicyFixtures.identityID,
            signingConfiguration: ProvisioningPolicyFixtures.configuration(),
            deviceContext: .identified(ProvisioningPolicyFixtures.deviceA)
        )
        let identityMetadata = ProvisioningPolicyFixtures.identityMetadata(
            fingerprint: ProvisioningPolicyFixtures.fingerprint(CMSFixtures.signerCertificateFingerprint)
        )
        let store = TestIdentityStore()
        store.identities = [
            SigningIdentity(
                id: identityMetadata.id,
                certificate: identityMetadata.certificate,
                keyAvailability: identityMetadata.keyAvailability,
                association: identityMetadata.association,
                capabilityState: identityMetadata.capabilityState
            ),
        ]
        let result = try ValidateProvisioningProfileUseCase(
            profileVerification: ProvisioningProfileVerificationUseCase(
                cmsVerifier: ProvisioningProfileCMSVerifier(
                    certificateParser: AppleCertificateParser(),
                    signatureVerifier: RecordingCMSSignatureVerifier()
                ),
                inspection: ProvisioningProfileInspectionUseCase(
                    payloadDecoder: UnusedPayloadDecoder(),
                    parser: PropertyListProvisioningProfileParser(certificateParser: AppleCertificateParser()),
                    clock: FixedEvaluationClock(instant: Date(timeIntervalSince1970: 1_800_000_000))
                ),
                identityStore: store
            ),
            configurationValidation: ValidateProvisioningConfigurationUseCase(
                policyValidator: ProvisioningPolicyValidator(clock: FixedEvaluationClock(instant: Date(timeIntervalSince1970: 1_800_000_000))),
                identityStore: store
            )
        ).validate(request)

        XCTAssertEqual(result.input.origin, .embeddedBundleEntry)
        XCTAssertTrue(result.isProfileDiscovered)
        XCTAssertTrue(result.isProfileAuthenticated)
        XCTAssertEqual(result.overallStatus, .valid)
        XCTAssertTrue(store.capabilityRequests.isEmpty)
    }

    func testAnApplicationBundleWithoutAProfileNeverBecomesAnInvalidApplication() throws {
        let reader = SyntheticArchiveReader(entryTable: [
            makeEntry("Payload", kind: .directory),
            makeEntry("Payload/Example.app", kind: .directory),
            makeEntry("Payload/Example.app/Info.plist", uncompressedSize: 128),
        ])
        let profile = BundleProvisioningProfileIntake(
            readerProvider: SyntheticArchiveReaderProvider.providing(reader)
        ).profile(in: libraryEntry(artifact: Data(repeating: 0x02, count: 8)))
        XCTAssertEqual(profile, .notFound)

        let result = try ValidateProvisioningProfileUseCase(
            profileVerification: ProvisioningProfileVerificationUseCase(
                cmsVerifier: ProvisioningProfileCMSVerifier(
                    certificateParser: AppleCertificateParser(),
                    signatureVerifier: RecordingCMSSignatureVerifier()
                ),
                inspection: ProvisioningProfileInspectionUseCase(
                    payloadDecoder: UnusedPayloadDecoder(),
                    parser: PropertyListProvisioningProfileParser(),
                    clock: FixedEvaluationClock(instant: Date(timeIntervalSince1970: 1_800_000_000))
                )
            ),
            configurationValidation: ValidateProvisioningConfigurationUseCase(
                policyValidator: ProvisioningPolicyValidator(clock: FixedEvaluationClock(instant: Date(timeIntervalSince1970: 1_800_000_000)))
            )
        ).validate(.embedded(in: libraryEntry(artifact: Data(repeating: 0x02, count: 8)), intake: BundleProvisioningProfileIntake(
            readerProvider: SyntheticArchiveReaderProvider.providing(reader)
        )))

        XCTAssertEqual(result.overallStatus, .indeterminate)
        XCTAssertEqual(result.findings.first?.code, ProvisioningProfilePipelineFindingCode.profileNotFound)
        XCTAssertNil(result.policy)
    }

    // MARK: - Support

    private static func table(withProfile content: Data?) -> [ArchiveEntry] {
        var table: [ArchiveEntry] = [
            makeEntry("Payload", kind: .directory),
            makeEntry("Payload/\(Self.bundleName)", kind: .directory),
            makeEntry("Payload/\(Self.bundleName)/Info.plist", uncompressedSize: 128, compressedSize: 96),
            makeEntry("Payload/\(Self.bundleName)/Example", uncompressedSize: 4_096, compressedSize: 2_048),
        ]
        if let content {
            table.append(makeEntry(Self.profilePath, uncompressedSize: content.count, compressedSize: content.count / 2 + 1))
        }
        return table
    }

    private func libraryEntry(artifact: Data) -> LibraryEntry {
        LibraryEntry(
            record: LibraryFixtures.record(
                artifact: LibraryFixtures.reference(to: artifact, artifactID: ArtifactIdentifier())
            ),
            artifactAvailability: .available
        )
    }

    /// A provider that counts opens, so a test can prove the intake refuses to
    /// reach a package the library cannot vouch for.
    private final class CountingReaderProvider: ArtifactArchiveReaderProvider {

        private let entryTable: [ArchiveEntry]
        private(set) var openCount = 0

        init(entryTable: [ArchiveEntry]) {
            self.entryTable = entryTable
        }

        func archiveReader(for artifact: ArtifactIdentifier) throws -> any ArchiveReader {
            openCount += 1
            return SyntheticArchiveReader(entryTable: entryTable)
        }
    }
}
