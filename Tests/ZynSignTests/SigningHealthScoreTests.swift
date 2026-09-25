import XCTest
@testable import ZynSign

final class SigningHealthScoreTests: XCTestCase {

    func testEmptyScoreIsZero() {
        let score = SigningHealthScore.empty
        XCTAssertEqual(score.score, 0)
        XCTAssertEqual(score.band, .risky)
        XCTAssertEqual(score.findings.count, 1)
        XCTAssertTrue(score.findings[0].isRisk == false) // weight 0 is neutral
    }

    func testBandThresholds() {
        XCTAssertEqual(SigningHealthScore.Band.band(for: 100), .excellent)
        XCTAssertEqual(SigningHealthScore.Band.band(for: 90), .excellent)
        XCTAssertEqual(SigningHealthScore.Band.band(for: 89), .good)
        XCTAssertEqual(SigningHealthScore.Band.band(for: 70), .good)
        XCTAssertEqual(SigningHealthScore.Band.band(for: 69), .fair)
        XCTAssertEqual(SigningHealthScore.Band.band(for: 50), .fair)
        XCTAssertEqual(SigningHealthScore.Band.band(for: 49), .poor)
        XCTAssertEqual(SigningHealthScore.Band.band(for: 25), .poor)
        XCTAssertEqual(SigningHealthScore.Band.band(for: 24), .risky)
        XCTAssertEqual(SigningHealthScore.Band.band(for: 0), .risky)
    }

    func testScoreClampsToRange() {
        let veryHigh = SigningHealthScore(score: 1000, findings: [])
        XCTAssertEqual(veryHigh.score, 100)
        let veryLow = SigningHealthScore(score: -1000, findings: [])
        XCTAssertEqual(veryLow.score, 0)
    }

    func testFindingsOrderedByAbsoluteWeight() {
        let findings = [
            SigningHealthScore.Finding(id: "low", title: "low", detail: "", weight: 1),
            SigningHealthScore.Finding(id: "high", title: "high", detail: "", weight: -50),
            SigningHealthScore.Finding(id: "mid", title: "mid", detail: "", weight: -5),
        ]
        let score = SigningHealthScore(score: 50, findings: findings)
        XCTAssertEqual(score.findings.map(\.id), ["high", "mid", "low"])
    }

    func testRiskAndStrengthSums() {
        let findings = [
            SigningHealthScore.Finding(id: "a", title: "", detail: "", weight: 8),
            SigningHealthScore.Finding(id: "b", title: "", detail: "", weight: 5),
            SigningHealthScore.Finding(id: "c", title: "", detail: "", weight: -25),
            SigningHealthScore.Finding(id: "d", title: "", detail: "", weight: -8),
        ]
        let score = SigningHealthScore(score: 0, findings: findings)
        XCTAssertEqual(score.totalStrengthWeight, 13)
        XCTAssertEqual(score.totalRiskWeight, 33)
    }
}

final class SigningHealthAssessmentTests: XCTestCase {

    func testNoInputsProducesRiskyScore() async {
        let assessor = SigningHealthAssessment(
            certificate: nil,
            keyAvailability: .unknown,
            isKeyNonExportable: nil,
            profile: nil,
            bundleIdentifier: nil
        )
        let score = await assessor.assess()
        XCTAssertLessThanOrEqual(score.score, 30)
        XCTAssertEqual(score.band, .risky)
        XCTAssertTrue(score.findings.contains(where: { $0.id == "missing.certificate" }))
        XCTAssertTrue(score.findings.contains(where: { $0.id == "missing.profile" }))
        XCTAssertTrue(score.findings.contains(where: { $0.id == "missing.bundle" }))
    }

    func testCertificateExpiredProducesHeavyPenalty() async {
        let (certificate, _) = Self.makeCertificate(expirationOffsetDays: -10)
        let assessor = SigningHealthAssessment(
            certificate: certificate,
            keyAvailability: .available,
            isKeyNonExportable: true,
            profile: nil,
            bundleIdentifier: "com.example.app"
        )
        let score = await assessor.assess()
        XCTAssertTrue(score.findings.contains(where: { $0.id == "cert.expired" }))
        XCTAssertLessThan(score.score, 50)
    }

    func testProfileCoveringBundleIsPositive() async {
        let (_, profile) = Self.makeProfile(
            patterns: ["com.example.*"],
            expirationOffsetDays: 365
        )
        let assessor = SigningHealthAssessment(
            certificate: nil,
            keyAvailability: .unknown,
            isKeyNonExportable: nil,
            profile: profile,
            bundleIdentifier: "com.example.app"
        )
        let score = await assessor.assess()
        XCTAssertTrue(score.findings.contains(where: { $0.id == "compat.covers" }))
    }

    func testProfileMismatchPenalises() async {
        let (_, profile) = Self.makeProfile(
            patterns: ["com.other.*"],
            expirationOffsetDays: 365
        )
        let assessor = SigningHealthAssessment(
            certificate: nil,
            keyAvailability: .unknown,
            isKeyNonExportable: nil,
            profile: profile,
            bundleIdentifier: "com.example.app"
        )
        let score = await assessor.assess()
        XCTAssertTrue(score.findings.contains(where: { $0.id == "compat.mismatch" }))
    }

    func testExpiringSoonProfileShowsWarning() async {
        let (_, profile) = Self.makeProfile(
            patterns: ["com.example.*"],
            expirationOffsetDays: 5
        )
        let assessor = SigningHealthAssessment(
            certificate: nil,
            keyAvailability: .unknown,
            isKeyNonExportable: nil,
            profile: profile,
            bundleIdentifier: "com.example.app"
        )
        let score = await assessor.assess()
        XCTAssertTrue(score.findings.contains(where: { $0.id == "profile.expiringSoon" }))
    }

    func testNonExportableKeyIsPositive() async {
        let (certificate, _) = Self.makeCertificate(expirationOffsetDays: 365)
        let assessor = SigningHealthAssessment(
            certificate: certificate,
            keyAvailability: .available,
            isKeyNonExportable: true,
            profile: nil,
            bundleIdentifier: nil
        )
        let score = await assessor.assess()
        XCTAssertTrue(score.findings.contains(where: { $0.id == "key.nonExportable" }))
    }

    // MARK: - Fixtures

    private static func makeCertificate(expirationOffsetDays: Int)
        -> (CertificateMetadata, Void) {
        let now = Date()
        let expiration = now.addingTimeInterval(TimeInterval(expirationOffsetDays * 86400))
        let fingerprint = CertificateFingerprint(algorithm: .sha256, hexDigest:
            String(repeating: "a", count: 64))!
        let subject = CertificateDistinguishedName(commonName: "Test", rawRepresentation: "CN=Test")
        let issuer = CertificateDistinguishedName(commonName: "Test", rawRepresentation: "CN=Test")
        let serial = CertificateSerialNumber(contentBytes: [0x01, 0x02, 0x03])!
        let publicKey = PublicKeyInfo(
            algorithm: .rsa,
            keySizeInBits: 2048
        )
        let signature = SignatureAlgorithm.sha256WithRSAEncryption
        let metadata = CertificateMetadata(
            subject: subject,
            issuer: issuer,
            serialNumber: serial,
            notValidBefore: now.addingTimeInterval(-86400),
            notValidAfter: expiration,
            publicKeyInfo: publicKey,
            signatureAlgorithm: signature,
            sha256Fingerprint: fingerprint
        )
        return (metadata, ())
    }

    private static func makeProfile(patterns: [String], expirationOffsetDays: Int)
        -> (Void, ProvisioningProfileSummary) {
        let now = Date()
        let expiration = now.addingTimeInterval(TimeInterval(expirationOffsetDays * 86400))
        let summary = ProvisioningProfileSummary(
            name: "Test Profile",
            teamIdentifier: "TEAM12345",
            bundleIdentifierPatterns: patterns,
            expirationDate: expiration,
            entitlementsKeys: ["com.apple.developer.team-identifier"],
            allowsDebug: false,
            sourceFileName: "test.mobileprovision",
            importedAt: now
        )
        return ((), summary)
    }
}
