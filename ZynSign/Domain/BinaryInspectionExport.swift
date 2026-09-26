import Foundation

/// The formats an inspection report can be exported in.
enum BinaryInspectionExportFormat: String, CaseIterable, Identifiable, Hashable {
    case text
    case json

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .text: return "Text"
        case .json: return "JSON"
        }
    }

    var fileExtension: String {
        switch self {
        case .text: return "txt"
        case .json: return "json"
        }
    }
}

/// What the exported report says about where it came from.
struct BinaryInspectionExportContext: Equatable {
    let applicationName: String
    let bundleIdentifier: String?
    let generatedAt: Date
    /// For example "ZynSign 0.1.0 (4)".
    let generator: String
    /// The bundle-level nested-signature check, when the export covers the
    /// main executable.
    let nestedSignatures: BinaryVerificationCheck?
}

/// Renders inspection reports as a read-only document.
///
/// The document carries what the inspector established — executable summary,
/// architectures, signature summary, verification results, and timestamps —
/// and deliberately nothing sensitive: no certificate bytes, serial numbers,
/// fingerprints, or keys; no provisioning-profile contents; no entitlement
/// values (keys only); and no file-system locations outside the bundle. The
/// same statement is written into the document itself.
enum BinaryInspectionReportRenderer {

    static let exclusionStatement = "This is a read-only inspection report. It contains no certificate data, serial numbers, fingerprints, or key material; no provisioning-profile contents; no entitlement values (entitlements are listed by key only); and no file-system locations outside the application bundle."

    static let scopeStatement = "Verification means ZynSign re-computed the signature's hashes on the device and checked the CMS signature's mathematics. It does not evaluate certificate trust, revocation, provisioning, or whether iOS will install or launch the app."

    static func render(
        _ reports: [BinaryInspectionReport],
        context: BinaryInspectionExportContext,
        format: BinaryInspectionExportFormat
    ) -> Data {
        switch format {
        case .text:
            return Data(text(reports, context: context).utf8)
        case .json:
            let object = json(reports, context: context)
            let options: JSONSerialization.WritingOptions = [.prettyPrinted, .sortedKeys]
            return (try? JSONSerialization.data(withJSONObject: object, options: options)) ?? Data("{}".utf8)
        }
    }

    /// A file name derived from the application name, safe for any
    /// filesystem: letters, digits, dashes, and underscores only.
    static func suggestedFileName(
        applicationName: String,
        executableName: String?,
        format: BinaryInspectionExportFormat
    ) -> String {
        func safe(_ value: String) -> String {
            let mapped = value.unicodeScalars.map { scalar -> Character in
                CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "_" ? Character(scalar) : "-"
            }
            let collapsed = String(mapped).split(separator: "-", omittingEmptySubsequences: true).joined(separator: "-")
            return collapsed.isEmpty ? "App" : String(collapsed.prefix(48))
        }
        var name = safe(applicationName)
        if let executableName, executableName != applicationName {
            name += "-" + safe(executableName)
        }
        return "\(name)-binary-inspection.\(format.fileExtension)"
    }

    // MARK: - Text

    private static func text(_ reports: [BinaryInspectionReport], context: BinaryInspectionExportContext) -> String {
        var lines: [String] = []
        lines.append("ZynSign — Binary & Signature Inspection Report")
        lines.append(String(repeating: "=", count: 46))
        lines.append("Generated: \(timestamp(context.generatedAt)) by \(context.generator)")
        var application = "Application: \(context.applicationName)"
        if let identifier = context.bundleIdentifier { application += " (\(identifier))" }
        lines.append(application)
        lines.append("Report schema: \(BinaryInspectionReport.schemaVersion)")
        lines.append("")
        lines.append(scopeStatement)
        if let nested = context.nestedSignatures {
            lines.append("")
            lines.append("Nested signatures: \(nested.status.displayName) — \(nested.summary)")
        }

        for report in reports {
            lines.append("")
            lines.append("## \(report.target.name) — \(report.target.kind.displayName)")
            lines.append("Location in bundle: \(report.target.executablePath.rawValue)")
            lines.append("File size: \(bytes(report.fileSize))")
            lines.append("Container: \(report.container.displayName)")
            lines.append("Architectures: \(report.architectureSummary)")
            lines.append("Signature: \(report.signaturePresence.displayName)")
            lines.append("Encryption: \(report.encryptionState.displayName)")
            lines.append("Verification: \(report.verdict.displayName) — \(report.verdict.explanation)")
            lines.append("Inspected: \(timestamp(report.inspectedAt))")
            let health = BinaryHealthEvaluator.evaluate(report)
            lines.append("Health: \(health.headline)")
            for finding in health.findings {
                lines.append("  • [\(finding.severity.displayName)] \(finding.title): \(finding.detail)")
            }

            for architecture in report.architectures {
                lines.append("")
                lines.append("### Architecture \(architecture.name)")
                lines.append("CPU type: \(architecture.architecture.cpuTypeName) (\(architecture.architecture.rawCPUType))")
                lines.append("CPU subtype: \(architecture.architecture.cpuSubtypeName) (\(architecture.architecture.subtypeValue))")
                lines.append("Executable type: \(architecture.fileKind.displayName) (\(architecture.fileKind.constantName))")
                lines.append("File offset: \(architecture.fileOffset.formatted()) (\(MachOHexadecimal.text(UInt64(architecture.fileOffset))))")
                lines.append("Binary size: \(bytes(architecture.size))")
                if let platform = architecture.platform {
                    lines.append("Platform: \(platform.displayName), minimum \(architecture.minimumOS?.description ?? "not declared"), SDK \(architecture.sdk?.description ?? "not declared")")
                }
                if let uuid = architecture.uuid { lines.append("Build UUID: \(uuid)") }
                lines.append("Encryption: \(encryptionText(architecture.encryption))")
                lines.append("Header flags: \(architecture.headerFlags.summary)")
                lines.append("Load commands: \(architecture.loadCommands.count) — " + categoryCounts(architecture).map { "\($0.0) \($0.1)" }.joined(separator: ", "))
                let libraries = architecture.libraries.map { LinkedLibraryDescription(reference: $0) }
                lines.append("Linked libraries (\(libraries.count)): " + (libraries.isEmpty ? "none" : libraries.map { "\($0.displayName) (\($0.reference.kind.displayName.lowercased()))" }.joined(separator: ", ")))

                if let signature = architecture.signature {
                    lines.append("Signature form: \(signature.form.displayName)")
                    for directory in signature.codeDirectories {
                        lines.append("CodeDirectory (\(directory.slotLabel)): version \(directory.versionText), \(directory.hashType.displayName), \(pageText(directory)), identifier \(directory.identifier), team \(directory.teamIdentifier ?? "none")")
                        if let cdHash = directory.cdHashText { lines.append("  CDHash: \(cdHash)") }
                        lines.append("  Flags: \(directory.decodedFlags.summary)")
                        let bound = directory.specialSlots.filter(\.isBound).map(\.title)
                        lines.append("  Bound special slots: \(bound.isEmpty ? "none" : bound.joined(separator: ", "))")
                    }
                    lines.append("Requirements: \(requirementsText(signature.requirements))")
                    let keys = signature.entitlements.keys
                    lines.append("Entitlement keys (\(keys.count)): \(keys.isEmpty ? "none" : keys.joined(separator: ", "))")
                    lines.append("DER entitlements: \(signature.hasDEREntitlements ? "present" : "absent")")
                } else {
                    lines.append("Signature: none")
                }

                if let result = report.integrity?.architectures.first(where: { $0.architectureIndex == architecture.index }) {
                    lines.append("CMS: \(cmsText(result.cms))")
                }
            }

            if let integrity = report.integrity {
                lines.append("")
                lines.append("### Verification Details (performed \(timestamp(integrity.verifiedAt)))")
                for check in integrity.checks {
                    lines.append("\(check.kind.title): \(check.status.displayName) — \(check.summary)")
                    lines.append("    \(check.detail)")
                }
                lines.append("Resource integrity: \(integrity.resourceIntegrity.status.displayName) — \(integrity.resourceIntegrity.summary)")
            } else {
                lines.append("")
                lines.append("Verification: not completed when this report was generated.")
            }
        }

        lines.append("")
        lines.append("Excluded content: \(exclusionStatement)")
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - JSON

    private static func json(_ reports: [BinaryInspectionReport], context: BinaryInspectionExportContext) -> [String: Any] {
        var root: [String: Any] = [
            "schemaVersion": BinaryInspectionReport.schemaVersion,
            "generatedAt": timestamp(context.generatedAt),
            "generator": context.generator,
            "application": [
                "name": context.applicationName,
                "bundleIdentifier": nullable(context.bundleIdentifier),
            ] as [String: Any],
            "scope": scopeStatement,
            "excludedContent": exclusionStatement,
            "executables": reports.map(executableJSON),
        ]
        if let nested = context.nestedSignatures {
            root["nestedSignatures"] = checkJSON(nested)
        }
        return root
    }

    private static func executableJSON(_ report: BinaryInspectionReport) -> [String: Any] {
        let health = BinaryHealthEvaluator.evaluate(report)
        var object: [String: Any] = [
            "name": report.target.name,
            "kind": report.target.kind.rawValue,
            "location": report.target.executablePath.rawValue,
            "fileSize": report.fileSize,
            "container": report.container.displayName,
            "signature": report.signaturePresence.displayName,
            "encryption": report.encryptionState.displayName,
            "verdict": report.verdict.rawValue,
            "inspectedAt": timestamp(report.inspectedAt),
            "health": [
                "headline": health.headline,
                "findings": health.findings.map {
                    ["severity": $0.severity.displayName, "title": $0.title, "detail": $0.detail]
                },
            ] as [String: Any],
            "architectures": report.architectures.map { architectureJSON($0, integrity: report.integrity) },
        ]
        if let integrity = report.integrity {
            object["verification"] = [
                "verifiedAt": timestamp(integrity.verifiedAt),
                "checks": integrity.checks.map(checkJSON),
                "resourceIntegrity": [
                    "status": integrity.resourceIntegrity.status.rawValue,
                    "summary": integrity.resourceIntegrity.summary,
                    "detail": integrity.resourceIntegrity.detail,
                ],
                "pages": [
                    "total": integrity.totalPageCount,
                    "checked": integrity.checkedPageCount,
                    "mismatched": integrity.mismatchedPageCount,
                ],
            ] as [String: Any]
        }
        return object
    }

    private static func architectureJSON(_ architecture: BinaryArchitectureReport, integrity: BinaryIntegrityReport?) -> [String: Any] {
        var object: [String: Any] = [
            "name": architecture.name,
            "cpuType": architecture.architecture.cpuTypeName,
            "cpuTypeValue": Int(architecture.architecture.rawCPUType),
            "cpuSubtype": architecture.architecture.cpuSubtypeName,
            "cpuSubtypeValue": Int(architecture.architecture.subtypeValue),
            "fileType": architecture.fileKind.displayName,
            "fileOffset": architecture.fileOffset,
            "size": architecture.size,
            "encryption": encryptionText(architecture.encryption),
            "headerFlags": architecture.headerFlags.known.map(\.name),
            "loadCommandCount": architecture.loadCommands.count,
            "loadCommandsByCategory": Dictionary(uniqueKeysWithValues: categoryCounts(architecture)),
            "libraries": architecture.libraries.map { reference -> [String: Any] in
                let description = LinkedLibraryDescription(reference: reference)
                return [
                    "name": description.displayName,
                    "installName": reference.installName,
                    "loadKind": reference.kind.rawValue,
                    "origin": description.origin.rawValue,
                    "currentVersion": reference.currentVersion.description,
                    "compatibilityVersion": reference.compatibilityVersion.description,
                ]
            },
        ]
        if let platform = architecture.platform { object["platform"] = platform.displayName }
        if let minimum = architecture.minimumOS { object["minimumOS"] = minimum.description }
        if let sdk = architecture.sdk { object["sdk"] = sdk.description }
        if let uuid = architecture.uuid { object["uuid"] = uuid }
        if let signature = architecture.signature {
            object["codeSignature"] = [
                "form": signature.form.rawValue,
                "codeDirectories": signature.codeDirectories.map { directory -> [String: Any] in
                    var value: [String: Any] = [
                        "slot": directory.slotLabel,
                        "version": directory.versionText,
                        "hashAlgorithm": directory.hashType.displayName,
                        "pages": directory.pageCount,
                        "identifier": directory.identifier,
                        "flags": directory.decodedFlags.known.map(\.name),
                        "boundSpecialSlots": directory.specialSlots.filter(\.isBound).map(\.title),
                    ]
                    value["pageSize"] = directory.pageSize ?? 0
                    value["teamIdentifier"] = nullable(directory.teamIdentifier)
                    value["cdHash"] = nullable(directory.cdHashText)
                    return value
                },
                "requirements": requirementsText(signature.requirements),
                "entitlementKeys": signature.entitlements.keys,
                "derEntitlements": signature.hasDEREntitlements,
            ] as [String: Any]
        }
        if let result = integrity?.architectures.first(where: { $0.architectureIndex == architecture.index }) {
            object["cms"] = cmsText(result.cms)
            if let signer = result.cms.evaluation?.signer {
                object["signer"] = [
                    "commonName": nullable(signer.commonName),
                    "organizationalUnit": nullable(signer.organizationalUnit),
                    "issuer": nullable(signer.issuerCommonName),
                    "validFrom": timestamp(signer.notValidBefore),
                    "validUntil": timestamp(signer.notValidAfter),
                    "key": signer.keyDescription,
                ] as [String: Any]
            }
            if let declared = result.cms.evaluation?.declaredSigningTime {
                object["declaredSigningTime"] = timestamp(declared)
            }
        }
        return object
    }

    private static func checkJSON(_ check: BinaryVerificationCheck) -> [String: Any] {
        [
            "check": check.kind.rawValue,
            "title": check.kind.title,
            "status": check.status.rawValue,
            "summary": check.summary,
            "detail": check.detail,
        ]
    }

    // MARK: - Shared text

    /// An optional string as a JSON value: the string, or JSON `null`.
    private static func nullable(_ value: String?) -> Any {
        guard let value else { return NSNull() }
        return value
    }

    private static func timestamp(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private static func bytes(_ count: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file) + " (\(count.formatted()) bytes)"
    }

    private static func encryptionText(_ encryption: MachOEncryptionInfo?) -> String {
        guard let encryption else { return "No encryption record" }
        return encryption.isEncrypted ? "Encrypted (cryptid \(encryption.cryptID))" : "Not encrypted (cryptid 0)"
    }

    private static func pageText(_ directory: CodeDirectorySummary) -> String {
        guard let size = directory.pageSize else { return "unpaged" }
        return "\(directory.pageCount.formatted()) pages of \(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .memory))"
    }

    private static func requirementsText(_ requirements: RequirementsSummary) -> String {
        switch requirements.state {
        case .absent: return "none"
        case .malformed: return "malformed"
        case .parsed, .unsupported:
            return requirements.count == 0 ? "empty set" : requirements.requirementKinds.joined(separator: ", ")
        }
    }

    private static func categoryCounts(_ architecture: BinaryArchitectureReport) -> [(String, Int)] {
        MachOLoadCommandCategory.allCases.compactMap { category -> (String, Int)? in
            let count = architecture.loadCommands.filter { $0.descriptor.category == category }.count
            return count == 0 ? nil : (category.displayName, count)
        }
    }

    private static func cmsText(_ assessment: CodeSignatureCMSAssessment) -> String {
        switch assessment {
        case .absent: return "No CMS signature (ad-hoc)"
        case .empty: return "Empty CMS signature (ad-hoc)"
        case .unreadable(let reason): return "Not evaluated — \(reason)"
        case .evaluated(let evaluation):
            var parts: [String] = []
            if let signer = evaluation.signer?.commonName { parts.append("signer \(signer)") }
            switch evaluation.binding {
            case .matches: parts.append("message digest matches the CodeDirectory")
            case .mismatch: parts.append("message digest does not match")
            case .notCompared(let reason): parts.append("message digest not compared (\(reason))")
            }
            switch evaluation.signature {
            case .verified: parts.append("signature verifies with the embedded certificate")
            case .invalid: parts.append("signature does not verify")
            case .notPerformed(let reason): parts.append("signature not checked (\(reason))")
            }
            parts.append("certificate trust not evaluated")
            return parts.joined(separator: "; ")
        }
    }
}
