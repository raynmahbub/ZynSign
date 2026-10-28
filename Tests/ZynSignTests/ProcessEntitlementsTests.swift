import Foundation
import XCTest
@testable import ZynSign

/// Tests for the measurement that replaced a hardcoded "no".
///
/// The point of `ProcessEntitlements` is that three states are distinct — the
/// entitlement is granted, it was measured and is absent, or the signature could
/// not be read — so most of these tests are about keeping `nil` from collapsing
/// into `false`. A screen that confuses the last two tells a person their build
/// is incapable when it merely could not be inspected.
final class ProcessEntitlementsTests: XCTestCase {

    private func measured(_ keys: String...) -> ProcessEntitlements {
        ProcessEntitlements(isMeasured: true, grantedKeys: Set(keys))
    }

    // MARK: - Measurement states

    /// An unread signature answers `nil` to everything. It never answers
    /// `false`, because "not read" is not "not granted".
    func testAnUnmeasuredBuildAnswersNothing() {
        let entitlements = ProcessEntitlements.unmeasured
        XCTAssertFalse(entitlements.isMeasured)
        XCTAssertNil(entitlements.carriesLocalTunnelEntitlement)
        XCTAssertNil(entitlements.carriesGetTaskAllow)
        XCTAssertTrue(entitlements.summary.contains("could not be read"))
    }

    /// A read signature with no tunnel key is a real "absent": measured, and
    /// said so.
    func testAMeasuredBuildWithoutTheTunnelKeyReportsAbsence() {
        let entitlements = measured(ProcessEntitlements.applicationIdentifierKey)
        XCTAssertEqual(entitlements.carriesLocalTunnelEntitlement, false)
        XCTAssertTrue(entitlements.summary.contains("carries no Network Extension entitlement"))
    }

    /// A build whose profile carries the entitlement reads as granted — this is
    /// the case the hardcoded constant could never express.
    func testAMeasuredBuildWithTheTunnelKeyReportsTheGrant() {
        let entitlements = measured(
            ProcessEntitlements.applicationIdentifierKey,
            ProcessEntitlements.localTunnelKey
        )
        XCTAssertEqual(entitlements.carriesLocalTunnelEntitlement, true)
        XCTAssertTrue(entitlements.summary.contains("carries a Network Extension entitlement"))
        XCTAssertTrue(entitlements.summary.contains("still the device's answer"))
    }

    /// An unrelated entitlement does not accidentally satisfy the tunnel key.
    func testAnotherEntitlementIsNotTheTunnelKey() {
        let entitlements = measured("aps-environment", "get-task-allow")
        XCTAssertEqual(entitlements.carriesLocalTunnelEntitlement, false)
        XCTAssertEqual(entitlements.carriesGetTaskAllow, true)
    }

    /// The probed list is the one the reader asks for, so a key cannot be added
    /// to one side and forgotten on the other.
    func testEveryProbedKeyIsDistinctAndNamed() {
        let keys = ProcessEntitlements.probedKeys
        XCTAssertEqual(Set(keys).count, keys.count)
        XCTAssertTrue(keys.contains(ProcessEntitlements.localTunnelKey))
        XCTAssertTrue(keys.contains(ProcessEntitlements.applicationIdentifierKey))
        XCTAssertTrue(keys.contains(ProcessEntitlements.teamIdentifierKey))
        XCTAssertTrue(keys.contains(ProcessEntitlements.getTaskAllowKey))
    }

    // MARK: - Evidence mapping

    /// The mapping carries the measurement through and leaves the facts this
    /// type does not measure at the values it was given.
    func testTheEvidenceCarriesTheMeasurementNotAConstant() {
        let granted = measured(ProcessEntitlements.localTunnelKey)
            .sideloadingEvidence(hasPairingRecord: true)
        XCTAssertEqual(granted.buildCarriesLocalTunnelEntitlement, true)
        XCTAssertEqual(granted.hasPairingRecord, true)

        let absent = measured(ProcessEntitlements.applicationIdentifierKey)
            .sideloadingEvidence(hasPairingRecord: true)
        XCTAssertEqual(absent.buildCarriesLocalTunnelEntitlement, false)

        let unknown = ProcessEntitlements.unmeasured
            .sideloadingEvidence(hasPairingRecord: true)
        XCTAssertNil(unknown.buildCarriesLocalTunnelEntitlement)
    }

    /// An unmeasured build is still unsupported — the safe reading — but it is
    /// unsupported for a reason the screen can state.
    func testAnUnmeasuredBuildStaysUnsupportedRatherThanOptimistic() {
        let evidence = ProcessEntitlements.unmeasured.sideloadingEvidence(hasPairingRecord: true)
        let assessment = SideloadingCapability.assess(.deviceSession, evidence: evidence)
        XCTAssertFalse(assessment.isSupported)
        XCTAssertTrue(assessment.unmetRequirements.contains(.localTunnelEntitlement))
    }

    /// With the entitlement granted, a pairing record, and a composed transport,
    /// the session row stops reporting the entitlement as missing. It does not
    /// claim a device accepted anything — only that this build may try.
    func testAnEntitledBuildStopsReportingTheEntitlementAsMissing() {
        let evidence = measured(ProcessEntitlements.localTunnelKey)
            .sideloadingEvidence(hasPairingRecord: true, transportComposed: true)
        let assessment = SideloadingCapability.assess(.deviceSession, evidence: evidence)
        XCTAssertFalse(assessment.unmetRequirements.contains(.localTunnelEntitlement))
        XCTAssertTrue(assessment.isSupported)
    }

    /// The entitled path still needs the record and the transport: nothing here
    /// shortens the list of real requirements.
    func testAnEntitledBuildStillNeedsTheRecordAndTheTransport() {
        let evidence = measured(ProcessEntitlements.localTunnelKey)
            .sideloadingEvidence(hasPairingRecord: false, transportComposed: false)
        let assessment = SideloadingCapability.assess(.deviceSession, evidence: evidence)
        XCTAssertEqual(assessment.unmetRequirements, [.pairingRecord, .deviceTransport])
        XCTAssertFalse(assessment.isSupported)
    }

    /// Pairing needs the entitlement *and* the entitled build; granting the
    /// entitlement alone does not make the record readable.
    func testPairingReportsBothEntitlementRequirementsWhenUnentitled() {
        let evidence = measured(ProcessEntitlements.applicationIdentifierKey)
            .sideloadingEvidence(hasPairingRecord: false)
        let assessment = SideloadingCapability.assess(.devicePairing, evidence: evidence)
        XCTAssertEqual(
            assessment.unmetRequirements,
            [.pairingRecord, .localTunnelEntitlement, .entitledBuild]
        )
    }

    // MARK: - The reader port

    /// The fixed reader is the seam tests and previews use; it reports exactly
    /// what it was given and never a default.
    func testTheFixedReaderReturnsTheGivenMeasurement() {
        let entitlements = measured(ProcessEntitlements.localTunnelKey)
        XCTAssertEqual(FixedProcessEntitlementReader(entitlements).read(), entitlements)
        XCTAssertEqual(
            FixedProcessEntitlementReader(.unmeasured).read(),
            ProcessEntitlements.unmeasured
        )
    }
}
