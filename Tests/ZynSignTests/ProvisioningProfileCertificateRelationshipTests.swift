import XCTest
@testable import ZynSign

/// Certificate relationship analysis over synthetic certificates.
///
/// The analyzer is pure, so these tests call it directly with certificate
/// material from the test fixtures. Every assertion is about correspondence
/// between certificate encodings and about local identity metadata; none of
/// them is a trust, validity, or authorization claim.
final class ProvisioningProfileCertificateRelationshipTests: XCTestCase {

    private let analyzer = CertificateRelationshipAnalyzer()

    // MARK: - Signer to profile correspondence

    func testMatchingFingerprintsAreMatched() throws {
        let signer = try certificate(CMSFixtures.signerCertificateDER)
        let relationship = analyzer.analyze(
            signerCertificateStatus: .extracted,
            signerCertificate: signer,
            profileCertificates: [reference(CMSFixtures.signerCertificateDER)],
            localIdentities: .notRequested
        )

        XCTAssertEqual(relationship.match, .matched)
        XCTAssertTrue(relationship.isCertificateMatch)
        XCTAssertTrue(relationship.signerCertificatePresent)
        XCTAssertTrue(relationship.profileCertificateReferencePresent)
        XCTAssertEqual(relationship.profileCertificateCount, 1)
        XCTAssertEqual(relationship.profileReferenceWithoutMetadataCount, 0)
        XCTAssertEqual(relationship.duplicateProfileCertificateCount, 0)
        XCTAssertEqual(relationship.signerFingerprint?.hexDigest, CMSFixtures.signerCertificateFingerprint)
        XCTAssertEqual(relationship.trustEvaluation, .notPerformed)
    }

    func testDifferentCertificatesAreMismatched() throws {
        let signer = try certificate(CMSFixtures.signerCertificateDER)
        let relationship = analyzer.analyze(
            signerCertificateStatus: .extracted,
            signerCertificate: signer,
            profileCertificates: [reference(CMSFixtures.otherCertificateDER)],
            localIdentities: .notRequested
        )

        XCTAssertEqual(relationship.match, .mismatched)
        XCTAssertFalse(relationship.isCertificateMatch)
        XCTAssertEqual(
            relationship.profileCertificateFingerprints.map { $0.hexDigest },
            [CMSFixtures.otherCertificateFingerprint]
        )
    }

    func testMatchingUsesFingerprintsNotNames() throws {
        // The twin certificate shares the signer's exact subject distinguished
        // name and issuer while holding a different key, so a name or label
        // comparison would call the two the same certificate. The fingerprint
        // comparison does not.
        let signer = try certificate(CMSFixtures.signerCertificateDER)
        let twin = try certificate(CMSFixtures.sameSubjectSignerCertificateDER)
        XCTAssertEqual(signer.metadata.subject, twin.metadata.subject)
        XCTAssertEqual(signer.metadata.issuer, twin.metadata.issuer)
        XCTAssertNotEqual(signer.metadata.serialNumber, twin.metadata.serialNumber)
        XCTAssertNotEqual(signer.fingerprint, twin.fingerprint)

        let namedTwin = analyzer.analyze(
            signerCertificateStatus: .extracted,
            signerCertificate: signer,
            profileCertificates: [reference(CMSFixtures.sameSubjectSignerCertificateDER)],
            localIdentities: .notRequested
        )
        XCTAssertEqual(namedTwin.match, .mismatched)

        let namedSigner = analyzer.analyze(
            signerCertificateStatus: .extracted,
            signerCertificate: signer,
            profileCertificates: [reference(CMSFixtures.signerCertificateDER)],
            localIdentities: .notRequested
        )
        XCTAssertEqual(namedSigner.match, .matched)
    }

    func testAmbiguousSignerSelectionStaysAmbiguous() throws {
        let relationship = analyzer.analyze(
            signerCertificateStatus: .ambiguous,
            signerCertificate: nil,
            profileCertificates: [reference(CMSFixtures.signerCertificateDER)],
            localIdentities: .notRequested
        )

        XCTAssertEqual(relationship.match, .ambiguous)
        XCTAssertFalse(relationship.signerCertificatePresent)
        XCTAssertNil(relationship.signerFingerprint)
    }

    func testNoSignerCertificateIsNotEvaluated() throws {
        let relationship = analyzer.analyze(
            signerCertificateStatus: .absentFromMessage,
            signerCertificate: nil,
            profileCertificates: [reference(CMSFixtures.signerCertificateDER)],
            localIdentities: .notRequested
        )

        XCTAssertEqual(relationship.match, .notEvaluated)
        XCTAssertEqual(relationship.signerCertificateStatus, .absentFromMessage)
    }

    func testProfileWithoutParsedCertificatesIsIncomparable() throws {
        let signer = try certificate(CMSFixtures.signerCertificateDER)

        let absent = analyzer.analyze(
            signerCertificateStatus: .extracted,
            signerCertificate: signer,
            profileCertificates: nil,
            localIdentities: .notRequested
        )
        XCTAssertEqual(absent.match, .incomparable)
        XCTAssertEqual(absent.profileCertificateCount, 0)
        XCTAssertFalse(absent.profileCertificateReferencePresent)

        let withoutMetadata = analyzer.analyze(
            signerCertificateStatus: .extracted,
            signerCertificate: signer,
            profileCertificates: [ProvisioningProfileCertificateReference(certificateData: CMSFixtures.signerCertificateDER)],
            localIdentities: .notRequested
        )
        XCTAssertEqual(withoutMetadata.match, .incomparable)
        XCTAssertEqual(withoutMetadata.profileCertificateCount, 1)
        XCTAssertEqual(withoutMetadata.profileReferenceWithoutMetadataCount, 1)
        XCTAssertTrue(withoutMetadata.profileCertificateFingerprints.isEmpty)
    }

    func testDuplicateProfileCertificatesAreCountedAndStillMatched() throws {
        let signer = try certificate(CMSFixtures.signerCertificateDER)
        let relationship = analyzer.analyze(
            signerCertificateStatus: .extracted,
            signerCertificate: signer,
            profileCertificates: [
                reference(CMSFixtures.signerCertificateDER),
                reference(CMSFixtures.otherCertificateDER),
                reference(CMSFixtures.signerCertificateDER),
            ],
            localIdentities: .notRequested
        )

        XCTAssertEqual(relationship.profileCertificateCount, 3)
        XCTAssertEqual(relationship.profileCertificateFingerprints.count, 3)
        XCTAssertEqual(relationship.duplicateProfileCertificateCount, 1)
        XCTAssertEqual(relationship.match, .matched)
    }

    // MARK: - Local signing identities

    func testLocalIdentityLookupStatesAreKeptApart() throws {
        let signer = try certificate(CMSFixtures.signerCertificateDER)
        let references = [reference(CMSFixtures.signerCertificateDER)]

        let notRequested = analyzer.analyze(
            signerCertificateStatus: .extracted,
            signerCertificate: signer,
            profileCertificates: references,
            localIdentities: .notRequested
        )
        XCTAssertEqual(notRequested.localSigningIdentity, .notEvaluated)
        XCTAssertNil(notRequested.localSigningIdentityKeyAvailability)
        XCTAssertFalse(notRequested.hasLocalSigningIdentityForProfileCertificate)

        let failed = analyzer.analyze(
            signerCertificateStatus: .extracted,
            signerCertificate: signer,
            profileCertificates: references,
            localIdentities: .failed
        )
        XCTAssertEqual(failed.localSigningIdentity, .lookupFailed)
        XCTAssertNil(failed.localSigningIdentityKeyAvailability)
        XCTAssertNotEqual(failed.localSigningIdentity, .notEvaluated)
    }

    func testSingleLocalIdentityMatchReportsItsKeyAvailabilitySeparately() throws {
        let signer = try certificate(CMSFixtures.signerCertificateDER)
        let identity = SigningIdentity(certificate: signer.metadata, keyAvailability: .available)

        let relationship = analyzer.analyze(
            signerCertificateStatus: .extracted,
            signerCertificate: signer,
            profileCertificates: [reference(CMSFixtures.signerCertificateDER)],
            localIdentities: .identities([identity])
        )

        XCTAssertEqual(relationship.localSigningIdentity, .matched(identity.id))
        XCTAssertEqual(relationship.localSigningIdentityKeyAvailability, .available)
        XCTAssertTrue(relationship.hasLocalSigningIdentityForProfileCertificate)
        XCTAssertEqual(relationship.trustEvaluation, .notPerformed)
    }

    func testKeyAvailabilityIsReportedAsObservedNotAsCapability() throws {
        let signer = try certificate(CMSFixtures.signerCertificateDER)
        let identity = SigningIdentity(certificate: signer.metadata, keyAvailability: .unavailable)

        let relationship = analyzer.analyze(
            signerCertificateStatus: .extracted,
            signerCertificate: signer,
            profileCertificates: [reference(CMSFixtures.signerCertificateDER)],
            localIdentities: .identities([identity])
        )

        XCTAssertEqual(relationship.localSigningIdentity, .matched(identity.id))
        XCTAssertEqual(relationship.localSigningIdentityKeyAvailability, .unavailable)
        XCTAssertFalse(identity.isUsableForSigning)
    }

    func testNoLocalIdentityForProfileCertificatesIsNoMatch() throws {
        let signer = try certificate(CMSFixtures.signerCertificateDER)
        let other = try certificate(CMSFixtures.otherCertificateDER)

        let relationship = analyzer.analyze(
            signerCertificateStatus: .extracted,
            signerCertificate: signer,
            profileCertificates: [reference(CMSFixtures.signerCertificateDER)],
            localIdentities: .identities([SigningIdentity(certificate: other.metadata, keyAvailability: .available)])
        )

        XCTAssertEqual(relationship.localSigningIdentity, .noMatch)
        XCTAssertNil(relationship.localSigningIdentityKeyAvailability)
    }

    func testEmptyIdentityListIsAnAnswerNotAFailure() throws {
        let signer = try certificate(CMSFixtures.signerCertificateDER)

        let relationship = analyzer.analyze(
            signerCertificateStatus: .extracted,
            signerCertificate: signer,
            profileCertificates: [reference(CMSFixtures.signerCertificateDER)],
            localIdentities: .identities([])
        )

        XCTAssertEqual(relationship.localSigningIdentity, .noMatch)
    }

    func testMultipleLocalMatchesAreNotResolved() throws {
        let signer = try certificate(CMSFixtures.signerCertificateDER)
        let first = SigningIdentity(certificate: signer.metadata, keyAvailability: .available)
        let second = SigningIdentity(certificate: signer.metadata, keyAvailability: .unavailable)

        let relationship = analyzer.analyze(
            signerCertificateStatus: .extracted,
            signerCertificate: signer,
            profileCertificates: [reference(CMSFixtures.signerCertificateDER)],
            localIdentities: .identities([first, second])
        )

        XCTAssertEqual(relationship.localSigningIdentity, .multipleMatches(2))
        XCTAssertNil(relationship.localSigningIdentityKeyAvailability)
        XCTAssertFalse(relationship.hasLocalSigningIdentityForProfileCertificate)
    }

    // MARK: - Diagnostics

    func testDiagnosticRenderingCarriesOnlyStatesCountsAndFingerprints() throws {
        let signer = try certificate(CMSFixtures.signerCertificateDER)
        let identity = SigningIdentity(certificate: signer.metadata, keyAvailability: .available)
        let relationship = analyzer.analyze(
            signerCertificateStatus: .extracted,
            signerCertificate: signer,
            profileCertificates: [reference(CMSFixtures.signerCertificateDER)],
            localIdentities: .identities([identity])
        )
        let diagnostic = relationship.diagnosticDescription

        XCTAssertTrue(diagnostic.contains("relationship.match(matched)"))
        XCTAssertTrue(diagnostic.contains("relationship.trust(notPerformed)"))
        XCTAssertTrue(diagnostic.contains(CMSFixtures.signerCertificateFingerprint))
        XCTAssertTrue(diagnostic.contains(identity.id.rawValue))
        XCTAssertFalse(diagnostic.contains(signer.metadata.subject.commonName ?? ""))
        XCTAssertFalse(diagnostic.contains(String(describing: Array(CMSFixtures.signerCertificateDER.prefix(8)))))
    }

    // MARK: - Support

    private func certificate(_ der: Data) throws -> Certificate {
        try CMSVerificationTestSupport.certificate(der)
    }

    private func reference(_ der: Data) throws -> ProvisioningProfileCertificateReference {
        ProvisioningProfileCertificateReference(
            certificateData: der,
            metadata: try AppleCertificateParser().parseCertificate(derData: der)
        )
    }
}
