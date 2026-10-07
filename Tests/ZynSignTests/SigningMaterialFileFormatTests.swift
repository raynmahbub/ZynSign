import XCTest
@testable import ZynSign

/// Tests for the file-type policy that routes signing material to
/// Certificates & Profiles instead of the Import Hub: which extensions are
/// identities, which are profiles, and what is neither.
final class SigningMaterialFileFormatTests: XCTestCase {

    func testPKCS12ExtensionsNameAnIdentity() {
        XCTAssertEqual(SigningMaterialFileFormat.kind(forPathExtension: "p12"), .identity)
        XCTAssertEqual(SigningMaterialFileFormat.kind(forPathExtension: "pfx"), .identity)
        XCTAssertEqual(SigningMaterialFileFormat.kind(forPathExtension: "P12"), .identity)
        XCTAssertEqual(SigningMaterialFileFormat.kind(forPathExtension: "PFX"), .identity)
    }

    func testProvisioningProfileExtensionsNameAProfile() {
        XCTAssertEqual(SigningMaterialFileFormat.kind(forPathExtension: "mobileprovision"), .profile)
        XCTAssertEqual(SigningMaterialFileFormat.kind(forPathExtension: "provisionprofile"), .profile)
        XCTAssertEqual(SigningMaterialFileFormat.kind(forPathExtension: "MobileProvision"), .profile)
    }

    func testPackagesAndArbitraryFilesAreNotSigningMaterial() {
        XCTAssertNil(SigningMaterialFileFormat.kind(forPathExtension: "ipa"))
        XCTAssertNil(SigningMaterialFileFormat.kind(forPathExtension: "tipa"))
        XCTAssertNil(SigningMaterialFileFormat.kind(forPathExtension: "zip"))
        XCTAssertNil(SigningMaterialFileFormat.kind(forPathExtension: "cer"))
        XCTAssertNil(SigningMaterialFileFormat.kind(forPathExtension: ""))
    }

    func testADocumentURLIsJudgedByItsNameAlone() {
        XCTAssertEqual(
            SigningMaterialFileFormat.kind(for: URL(fileURLWithPath: "/drop/Signer.p12")),
            .identity
        )
        XCTAssertEqual(
            SigningMaterialFileFormat.kind(for: URL(fileURLWithPath: "/drop/Credentials.PFX")),
            .identity
        )
        XCTAssertEqual(
            SigningMaterialFileFormat.kind(for: URL(fileURLWithPath: "/drop/Distribution.mobileprovision")),
            .profile
        )
        XCTAssertNil(SigningMaterialFileFormat.kind(for: URL(fileURLWithPath: "/drop/App.tipa")))
    }

    func testTheAcceptedExtensionsAreTheTwoKindsCombined() {
        XCTAssertEqual(
            SigningMaterialFileFormat.acceptedPathExtensions,
            SigningMaterialFileFormat.identityPathExtensions + SigningMaterialFileFormat.profilePathExtensions
        )
        for ext in SigningMaterialFileFormat.acceptedPathExtensions {
            XCTAssertNotNil(SigningMaterialFileFormat.kind(forPathExtension: ext), ext)
        }
    }
}
