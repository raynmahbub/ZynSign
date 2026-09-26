import Foundation

// MARK: - Targets

/// One executable inside an application bundle that the inspector can open.
struct BinaryTarget: Equatable, Hashable, Identifiable {

    enum Kind: String, CaseIterable, Hashable {
        case mainExecutable
        case framework
        case dynamicLibrary
        case appExtension
        case nestedApplication

        var displayName: String {
            switch self {
            case .mainExecutable: return "Main Executable"
            case .framework: return "Framework"
            case .dynamicLibrary: return "Dynamic Library"
            case .appExtension: return "App Extension"
            case .nestedApplication: return "Nested App"
            }
        }

        var systemImage: String {
            switch self {
            case .mainExecutable: return "app.badge.checkmark"
            case .framework: return "shippingbox"
            case .dynamicLibrary: return "book.closed"
            case .appExtension: return "puzzlepiece.extension"
            case .nestedApplication: return "apps.iphone"
            }
        }

        /// Dashboard order: the main executable first.
        var sortRank: Int {
            switch self {
            case .mainExecutable: return 0
            case .framework: return 1
            case .dynamicLibrary: return 2
            case .appExtension: return 3
            case .nestedApplication: return 4
            }
        }
    }

    let kind: Kind
    /// The executable's file name.
    let name: String
    /// The executable's location, relative to the application bundle.
    let executablePath: BundlePath
    /// The bundle directory that contains the executable, relative to the
    /// application bundle: the root for the main executable, the framework or
    /// extension directory for nested bundles, and `nil` for a standalone
    /// library that has no bundle of its own.
    let containerPath: BundlePath?
    /// The size the archive declares for the executable.
    let declaredByteCount: Int?

    var id: String { executablePath.rawValue }

    /// The name of the bundle directory, for display beside the executable.
    var containerName: String? {
        guard let containerPath, !containerPath.isRoot else { return nil }
        return containerPath.name
    }
}

/// The executables the inspector found in one bundle.
struct BinaryBundleOverview: Equatable {
    let bundleName: String
    /// The targets in dashboard order, the main executable first.
    let targets: [BinaryTarget]
    /// Nested executables beyond the per-pass inspection bound. They remain
    /// visible in the bundle explorer but are not inspected.
    let omittedTargetCount: Int

    var mainTarget: BinaryTarget? {
        targets.first { $0.kind == .mainExecutable }
    }

    var nestedTargets: [BinaryTarget] {
        targets.filter { $0.kind != .mainExecutable }
    }
}

/// Why an executable could not be inspected. None of these is a statement
/// that a signature is invalid.
enum BinaryTargetLimitation: Equatable, Hashable {
    case missingExecutable
    case exceedsReadLimit(limit: Int, declared: Int)
    case unreadable
    case notMachO
    case malformedMachO
    case malformedSignature

    var title: String {
        switch self {
        case .missingExecutable: return "Executable missing"
        case .exceedsReadLimit: return "Too large to inspect"
        case .unreadable: return "Could not be read"
        case .notMachO: return "Not a Mach-O executable"
        case .malformedMachO: return "Malformed Mach-O"
        case .malformedSignature: return "Malformed signature"
        }
    }

    var explanation: String {
        switch self {
        case .missingExecutable:
            return "The executable the bundle declares is not a regular file in the package."
        case .exceedsReadLimit(let limit, let declared):
            let limitText = ByteCountFormatter.string(fromByteCount: Int64(limit), countStyle: .file)
            let declaredText = ByteCountFormatter.string(fromByteCount: Int64(declared), countStyle: .file)
            return "The executable declares \(declaredText), above the \(limitText) ZynSign reads for inspection. Nothing was read, so nothing is concluded about it."
        case .unreadable:
            return "The archive reader refused the executable within its inspection policy. Nothing is concluded about its signature."
        case .notMachO:
            return "The file at the executable's location is not a Mach-O image ZynSign recognises."
        case .malformedMachO:
            return "The Mach-O structure could not be parsed safely, so it was not inspected further."
        case .malformedSignature:
            return "The executable declares a code signature that the bounded parser could not read safely. The signature cannot be relied on."
        }
    }
}

// MARK: - Architecture reports

/// How the executable packages its architectures.
enum BinaryContainerKind: Equatable, Hashable {
    case thin
    case universal(architectureCount: Int)

    var displayName: String {
        switch self {
        case .thin: return "Single architecture"
        case .universal(let count): return "Universal (\(count) architectures)"
        }
    }
}

/// One architecture slice, inspected.
struct BinaryArchitectureReport: Equatable, Identifiable {
    let index: Int
    let architecture: MachOArchitectureName
    /// Where the slice begins in the file.
    let fileOffset: Int
    /// The slice's length in bytes.
    let size: Int
    /// The universal container's alignment exponent for this slice.
    let alignmentExponent: UInt32?
    let fileKind: MachOFileKind
    let headerFlags: MachODecodedFlags
    let loadCommands: [MachODecodedLoadCommand]
    let signature: CodeSignatureSummary?

    var id: Int { index }
    var name: String { architecture.name }
    var isSigned: Bool { signature != nil }

    /// The libraries this slice loads, in load-command order. Its own
    /// identity (`LC_ID_DYLIB`) is excluded.
    var libraries: [MachODylibReference] {
        loadCommands.compactMap { command in
            if case .dylib(let reference) = command.payload, reference.kind != .identity {
                return reference
            }
            return nil
        }
    }

    /// The slice's own install name, when it is a library.
    var libraryIdentity: MachODylibReference? {
        for command in loadCommands {
            if case .dylib(let reference) = command.payload, reference.kind == .identity {
                return reference
            }
        }
        return nil
    }

    var runPaths: [String] {
        loadCommands.compactMap { command in
            if case .runPath(let path) = command.payload { return path }
            return nil
        }
    }

    var segments: [MachOSegmentSummary] {
        loadCommands.compactMap { command in
            if case .segment(let segment) = command.payload { return segment }
            return nil
        }
    }

    var encryption: MachOEncryptionInfo? {
        for command in loadCommands {
            if case .encryption(let info) = command.payload { return info }
        }
        return nil
    }

    var buildVersion: MachOBuildVersion? {
        for command in loadCommands {
            if case .buildVersion(let version) = command.payload { return version }
        }
        return nil
    }

    var minimumVersion: MachOMinimumVersion? {
        for command in loadCommands {
            if case .minimumVersion(let version) = command.payload { return version }
        }
        return nil
    }

    var uuid: String? {
        for command in loadCommands {
            if case .uuid(let value) = command.payload { return value }
        }
        return nil
    }

    var dynamicLinker: String? {
        for command in loadCommands {
            if case .dynamicLinker(let path) = command.payload { return path }
        }
        return nil
    }

    var entryPointOffset: UInt64? {
        for command in loadCommands {
            if case .entryPoint(let offset, _) = command.payload { return offset }
        }
        return nil
    }

    var isEncrypted: Bool { encryption?.isEncrypted ?? false }

    var platform: MachOPlatform? {
        buildVersion?.platform ?? minimumVersion?.platform
    }

    var minimumOS: MachOPackedVersion? {
        buildVersion?.minimumOS ?? minimumVersion?.version
    }

    var sdk: MachOPackedVersion? {
        buildVersion?.sdk ?? minimumVersion?.sdk
    }

    var malformedCommandCount: Int {
        loadCommands.filter { command in
            if case .malformed = command.payload { return true }
            return false
        }.count
    }
}

// MARK: - Report

/// Whether the executable is signed, across its architectures.
enum BinarySignaturePresence: Equatable, Hashable {
    case present
    case partial(signed: Int, total: Int)
    case absent

    var displayName: String {
        switch self {
        case .present: return "Present"
        case .partial(let signed, let total): return "Partial (\(signed) of \(total))"
        case .absent: return "Absent"
        }
    }
}

/// Whether the executable declares App Store encryption.
enum BinaryEncryptionState: Equatable, Hashable {
    /// At least one architecture declares its protected range encrypted.
    case encrypted
    /// Encryption records exist and none declares encryption.
    case notEncrypted
    /// No architecture carries an encryption record.
    case notDeclared

    var displayName: String {
        switch self {
        case .encrypted: return "Encrypted"
        case .notEncrypted, .notDeclared: return "Not Encrypted"
        }
    }

    var explanation: String {
        switch self {
        case .encrypted:
            return "The App Store encryption record is active (cryptid is not zero). Encrypted code only runs when it is installed through the App Store."
        case .notEncrypted:
            return "An App Store encryption record exists, and it declares the range unencrypted (cryptid 0)."
        case .notDeclared:
            return "The executable carries no App Store encryption record."
        }
    }
}

/// Everything ZynSign established about one executable.
struct BinaryInspectionReport: Equatable, Identifiable {

    /// The version of this report's shape, carried into exports so that
    /// later readers can tell which fields to expect.
    static let schemaVersion = 1

    let target: BinaryTarget
    let fileSize: Int
    let container: BinaryContainerKind
    let architectures: [BinaryArchitectureReport]
    let inspectedAt: Date
    /// Verification, once it has run. `nil` while it is still running.
    let integrity: BinaryIntegrityReport?

    var id: String { target.id }

    func withIntegrity(_ integrity: BinaryIntegrityReport) -> BinaryInspectionReport {
        BinaryInspectionReport(
            target: target,
            fileSize: fileSize,
            container: container,
            architectures: architectures,
            inspectedAt: inspectedAt,
            integrity: integrity
        )
    }

    func withArchitectures(_ architectures: [BinaryArchitectureReport]) -> BinaryInspectionReport {
        BinaryInspectionReport(
            target: target,
            fileSize: fileSize,
            container: container,
            architectures: architectures,
            inspectedAt: inspectedAt,
            integrity: integrity
        )
    }

    var architectureSummary: String {
        architectures.map(\.name).joined(separator: ", ")
    }

    var signaturePresence: BinarySignaturePresence {
        let signed = architectures.filter(\.isSigned).count
        if signed == 0 { return .absent }
        if signed == architectures.count { return .present }
        return .partial(signed: signed, total: architectures.count)
    }

    var encryptionState: BinaryEncryptionState {
        let records = architectures.compactMap(\.encryption)
        if records.contains(where: \.isEncrypted) { return .encrypted }
        return records.isEmpty ? .notDeclared : .notEncrypted
    }

    var verdict: BinaryVerificationVerdict {
        guard let integrity else { return .pending }
        return integrity.verdict
    }

    /// The first architecture's signature, which the dashboard summarises.
    var primarySignature: CodeSignatureSummary? {
        architectures.first(where: \.isSigned)?.signature
    }

    var hasDeviceArchitecture: Bool {
        architectures.contains { $0.architecture.isAppleDeviceArchitecture }
    }

    func architecture(at index: Int) -> BinaryArchitectureReport? {
        architectures.first { $0.index == index }
    }
}

// MARK: - Progress

/// Where the inspection of one target stands.
enum BinaryTargetProgress: Equatable {
    case pending
    case inspecting
    /// Structure is known; verification is still running.
    case structureReady(BinaryInspectionReport)
    case completed(BinaryInspectionReport)
    case unavailable(BinaryTargetLimitation)

    var report: BinaryInspectionReport? {
        switch self {
        case .structureReady(let report), .completed(let report): return report
        case .pending, .inspecting, .unavailable: return nil
        }
    }

    var isFinished: Bool {
        switch self {
        case .completed, .unavailable: return true
        case .pending, .inspecting, .structureReady: return false
        }
    }
}

// MARK: - Health

/// One finding in an executable's health summary.
struct BinaryHealthFinding: Equatable, Hashable, Identifiable {
    enum Severity: Int, Comparable, Hashable {
        case positive = 0
        case information = 1
        case warning = 2
        case critical = 3

        static func < (lhs: Severity, rhs: Severity) -> Bool { lhs.rawValue < rhs.rawValue }

        var displayName: String {
            switch self {
            case .positive: return "Good"
            case .information: return "Note"
            case .warning: return "Warning"
            case .critical: return "Problem"
            }
        }
    }

    let severity: Severity
    let title: String
    let detail: String

    var id: String { title }
}

/// A short, plain-language health summary for one executable.
struct BinaryHealthSummary: Equatable {
    let headline: String
    let findings: [BinaryHealthFinding]

    var worstSeverity: BinaryHealthFinding.Severity {
        findings.map(\.severity).max() ?? .information
    }
}

/// Derives the health summary from a report. Pure, so the rules are pinned by
/// tests and the dashboard and the export always agree.
enum BinaryHealthEvaluator {

    static func evaluate(_ report: BinaryInspectionReport) -> BinaryHealthSummary {
        var findings: [BinaryHealthFinding] = []

        switch report.signaturePresence {
        case .absent:
            findings.append(BinaryHealthFinding(
                severity: .critical,
                title: "No code signature",
                detail: "No architecture carries a code signature. iOS does not run unsigned code, so the app must be signed before it can be installed."
            ))
        case .partial(let signed, let total):
            findings.append(BinaryHealthFinding(
                severity: .warning,
                title: "Partially signed",
                detail: "\(signed) of \(total) architectures carry a signature. An unsigned architecture cannot run on a device that needs it."
            ))
        case .present:
            break
        }

        if let signature = report.primarySignature {
            switch signature.form {
            case .adHoc, .linkerSigned:
                findings.append(BinaryHealthFinding(
                    severity: .warning,
                    title: "No signing certificate",
                    detail: signature.form.explanation
                ))
            case .incomplete:
                findings.append(BinaryHealthFinding(
                    severity: .warning,
                    title: "Signature without signer data",
                    detail: signature.form.explanation
                ))
            case .certificate:
                break
            }
            if let primary = signature.primaryCodeDirectory,
               primary.hashType.isLegacy,
               signature.codeDirectories.count == 1 {
                findings.append(BinaryHealthFinding(
                    severity: .information,
                    title: "SHA-1 only",
                    detail: "The only CodeDirectory uses SHA-1. Current signing tools add a SHA-256 CodeDirectory."
                ))
            }
        }

        if report.encryptionState == .encrypted {
            findings.append(BinaryHealthFinding(
                severity: .warning,
                title: "App Store encryption active",
                detail: BinaryEncryptionState.encrypted.explanation
            ))
        }

        if report.architectures.contains(where: { $0.platform?.isSimulator == true }) {
            findings.append(BinaryHealthFinding(
                severity: .warning,
                title: "Built for a simulator",
                detail: "The build version names a simulator platform. Simulator builds do not run on iPhone or iPad."
            ))
        }

        if !report.hasDeviceArchitecture {
            findings.append(BinaryHealthFinding(
                severity: .warning,
                title: "No iPhone or iPad architecture",
                detail: "No arm64 slice was found. Current iPhone and iPad hardware runs arm64 code only."
            ))
        }

        let malformed = report.architectures.reduce(0) { $0 + $1.malformedCommandCount }
        if malformed > 0 {
            findings.append(BinaryHealthFinding(
                severity: .warning,
                title: "Undecodable load commands",
                detail: "\(malformed) load command(s) could not be decoded safely. They are listed with their type and size."
            ))
        }

        if let integrity = report.integrity {
            findings.append(contentsOf: integrityFindings(integrity))
        }

        let worst = findings.map(\.severity).max() ?? .information
        let headline: String
        if worst >= .warning, let first = findings.first(where: { $0.severity == worst }) {
            headline = first.title
        } else if report.integrity == nil {
            headline = "Structure inspected — verifying"
        } else if report.verdict == .valid {
            headline = "Signature intact and verified"
        } else {
            headline = "Inspected"
        }
        let ordered = findings.sorted { $0.severity > $1.severity }
        return BinaryHealthSummary(headline: headline, findings: ordered)
    }

    private static func integrityFindings(_ integrity: BinaryIntegrityReport) -> [BinaryHealthFinding] {
        var findings: [BinaryHealthFinding] = []
        if integrity.mismatchedPageCount > 0 {
            findings.append(BinaryHealthFinding(
                severity: .critical,
                title: "Code changed after signing",
                detail: "\(integrity.mismatchedPageCount.formatted()) page(s) no longer match the hashes the signature recorded, for example because the code was decrypted or patched. Re-signing records new hashes."
            ))
        }
        if integrity.check(.specialSlots)?.status == .failed {
            findings.append(BinaryHealthFinding(
                severity: .critical,
                title: "Signed content changed",
                detail: "Content the signature binds — such as the Info.plist, the resource seal, or the entitlements — no longer matches what was signed."
            ))
        }
        if integrity.check(.cmsSignature)?.status == .failed {
            findings.append(BinaryHealthFinding(
                severity: .critical,
                title: "CMS signature does not verify",
                detail: integrity.check(.cmsSignature)?.detail ?? "The CMS signature does not verify."
            ))
        }
        if integrity.check(.cmsSignature)?.status == .notPerformed {
            findings.append(BinaryHealthFinding(
                severity: .information,
                title: "CMS signature not checked",
                detail: integrity.check(.cmsSignature)?.detail ?? "The CMS signature could not be checked."
            ))
        }
        if integrity.verdict == .valid {
            findings.append(BinaryHealthFinding(
                severity: .positive,
                title: "Signature intact",
                detail: "Every page and every bound resource matched the signature when ZynSign re-hashed them on this device."
            ))
        }
        return findings
    }
}

// MARK: - Nested signatures

/// Evaluates the bundle-level Nested Signatures check from the progress of
/// every nested target. A target still being inspected is reported as such;
/// nothing is assumed about it.
enum NestedSignatureEvaluation {

    static func check(
        nestedTargets: [BinaryTarget],
        progress: [String: BinaryTargetProgress],
        omittedTargetCount: Int = 0
    ) -> BinaryVerificationCheck {
        let kind = BinaryVerificationCheckKind.nestedSignatures
        guard !nestedTargets.isEmpty else {
            if omittedTargetCount > 0 {
                return BinaryVerificationCheck(
                    kind: kind,
                    status: .notPerformed,
                    summary: "\(omittedTargetCount) nested executable(s) not inspected",
                    detail: "The bundle holds more nested executables than ZynSign inspects in one pass."
                )
            }
            return BinaryVerificationCheck(
                kind: kind,
                status: .notApplicable,
                summary: "No nested code",
                detail: "The bundle contains no frameworks, libraries, or extensions with executables."
            )
        }

        var valid = 0
        var warnings = 0
        var failed: [String] = []
        var unsigned: [String] = []
        var unavailable: [String] = []
        var running = 0
        for target in nestedTargets {
            switch progress[target.id] ?? .pending {
            case .pending, .inspecting, .structureReady:
                running += 1
            case .unavailable:
                unavailable.append(target.name)
            case .completed(let report):
                switch report.verdict {
                case .valid: valid += 1
                case .warning: warnings += 1
                case .failed: failed.append(target.name)
                case .unsigned: unsigned.append(target.name)
                case .pending, .notVerified: unavailable.append(target.name)
                }
            }
        }

        let total = nestedTargets.count
        if running > 0 {
            return BinaryVerificationCheck(
                kind: kind,
                status: .notPerformed,
                summary: "Verifying nested code — \(total - running) of \(total) done",
                detail: "ZynSign is still inspecting the remaining nested executables. Nothing is concluded about them until they finish."
            )
        }
        if !failed.isEmpty || !unsigned.isEmpty {
            var parts: [String] = []
            if !failed.isEmpty { parts.append("failed: " + failed.joined(separator: ", ")) }
            if !unsigned.isEmpty { parts.append("unsigned: " + unsigned.joined(separator: ", ")) }
            return BinaryVerificationCheck(
                kind: kind,
                status: .failed,
                summary: "\(failed.count + unsigned.count) of \(total) nested executables have problems",
                detail: "Nested code must be signed and intact for the app to run. " + parts.joined(separator: "; ") + "."
            )
        }
        if !unavailable.isEmpty || omittedTargetCount > 0 {
            var detail = "Some nested executables could not be verified"
            if !unavailable.isEmpty { detail += ": " + unavailable.joined(separator: ", ") }
            if omittedTargetCount > 0 { detail += ". \(omittedTargetCount) more were beyond the per-pass bound" }
            return BinaryVerificationCheck(
                kind: kind,
                status: .notPerformed,
                summary: "\(valid + warnings) of \(total + omittedTargetCount) nested executables verified",
                detail: detail + ". Open each one for the reason."
            )
        }
        if warnings > 0 {
            return BinaryVerificationCheck(
                kind: kind,
                status: .warning,
                summary: "\(total) nested executables verified — \(warnings) with warnings",
                detail: "No nested executable failed, but \(warnings) need attention. Open each one for details."
            )
        }
        return BinaryVerificationCheck(
            kind: kind,
            status: .passed,
            summary: "All \(total) nested executables verified",
            detail: "Every framework, library, and extension executable was inspected and verified on this device."
        )
    }
}
