import Foundation

/// One meaningful difference between two inspected states of an executable.
struct BinaryComparisonDifference: Equatable, Identifiable {

    enum Category: String, CaseIterable, Hashable {
        case size
        case architectures
        case signature
        case codeDirectory
        case entitlements
        case verification
        case libraries
        case build

        var displayName: String {
            switch self {
            case .size: return "Size"
            case .architectures: return "Architectures"
            case .signature: return "Signature"
            case .codeDirectory: return "CodeDirectory"
            case .entitlements: return "Entitlements"
            case .verification: return "Verification"
            case .libraries: return "Libraries"
            case .build: return "Build"
            }
        }

        var systemImage: String {
            switch self {
            case .size: return "externaldrive"
            case .architectures: return "cpu"
            case .signature: return "signature"
            case .codeDirectory: return "list.bullet.rectangle"
            case .entitlements: return "key"
            case .verification: return "checkmark.shield"
            case .libraries: return "books.vertical"
            case .build: return "hammer"
            }
        }
    }

    enum Change: String, Hashable {
        case changed
        case added
        case removed
    }

    let category: Category
    let field: String
    let before: String
    let after: String
    let change: Change

    var id: String { "\(category.rawValue):\(field):\(before):\(after)" }

    /// The difference as one sentence, for VoiceOver.
    var spokenDescription: String {
        switch change {
        case .changed: return "\(field) changed from \(before) to \(after)"
        case .added: return "\(field) added: \(after)"
        case .removed: return "\(field) removed: \(before)"
        }
    }
}

/// The comparison of two inspected states.
struct BinaryComparison: Equatable {
    let differences: [BinaryComparisonDifference]
    /// Architectures present in both states, compared field by field.
    let comparedArchitectureNames: [String]

    var hasDifferences: Bool { !differences.isEmpty }

    func differences(in category: BinaryComparisonDifference.Category) -> [BinaryComparisonDifference] {
        differences.filter { $0.category == category }
    }

    var categoriesWithDifferences: [BinaryComparisonDifference.Category] {
        BinaryComparisonDifference.Category.allCases.filter { category in
            differences.contains { $0.category == category }
        }
    }
}

/// Compares two inspection reports, keeping only differences a person would
/// act on: sizes, architectures, signature form and signer, CodeDirectory
/// identity and hashing, entitlement keys, libraries, build targets, and
/// verification results. Raw bytes and hash tables are never diffed; a changed
/// CDHash is reported as one line, because it identifies the signature.
enum BinaryComparator {

    static func compare(before: BinaryInspectionReport, after: BinaryInspectionReport) -> BinaryComparison {
        var differences: [BinaryComparisonDifference] = []
        func note(_ category: BinaryComparisonDifference.Category, _ field: String, _ old: String, _ new: String) {
            guard old != new else { return }
            differences.append(BinaryComparisonDifference(category: category, field: field, before: old, after: new, change: .changed))
        }

        note(.size, "File size", bytes(before.fileSize), bytes(after.fileSize))

        let beforeNames = before.architectures.map(\.name)
        let afterNames = after.architectures.map(\.name)
        for name in afterNames where !beforeNames.contains(name) {
            differences.append(BinaryComparisonDifference(category: .architectures, field: "Architecture", before: "", after: name, change: .added))
        }
        for name in beforeNames where !afterNames.contains(name) {
            differences.append(BinaryComparisonDifference(category: .architectures, field: "Architecture", before: name, after: "", change: .removed))
        }

        let shared = beforeNames.filter { afterNames.contains($0) }
        let prefixNames = shared.count > 1
        for name in shared {
            guard let old = before.architectures.first(where: { $0.name == name }),
                  let new = after.architectures.first(where: { $0.name == name }) else { continue }
            let label: (String) -> String = { prefixNames ? "\(name) · \($0)" : $0 }

            note(.size, label("Architecture size"), bytes(old.size), bytes(new.size))
            note(.signature, label("Signature"), old.isSigned ? "Present" : "Absent", new.isSigned ? "Present" : "Absent")
            note(.signature, label("Signature form"), old.signature?.form.displayName ?? "None", new.signature?.form.displayName ?? "None")
            note(.signature, label("Signer"), signerName(before, index: old.index), signerName(after, index: new.index))
            note(.signature, label("Encryption"), encryptionText(old), encryptionText(new))

            let oldCD = old.signature?.primaryCodeDirectory
            let newCD = new.signature?.primaryCodeDirectory
            note(.codeDirectory, label("Identifier"), oldCD?.identifier ?? "None", newCD?.identifier ?? "None")
            note(.codeDirectory, label("Team identifier"), oldCD?.teamIdentifier ?? "None", newCD?.teamIdentifier ?? "None")
            note(.codeDirectory, label("Hash algorithms"), hashNames(old.signature), hashNames(new.signature))
            note(.codeDirectory, label("Version"), oldCD?.versionText ?? "None", newCD?.versionText ?? "None")
            note(.codeDirectory, label("Page size"), pageSizeText(oldCD), pageSizeText(newCD))
            note(.codeDirectory, label("Pages"), oldCD.map { $0.pageCount.formatted() } ?? "None", newCD.map { $0.pageCount.formatted() } ?? "None")
            note(.codeDirectory, label("Flags"), oldCD?.decodedFlags.summary ?? "None", newCD?.decodedFlags.summary ?? "None")
            note(.codeDirectory, label("Bound special slots"), boundSlots(oldCD), boundSlots(newCD))
            note(.codeDirectory, label("CDHash"), oldCD?.cdHash.map { MachOHexadecimal.bytes($0, limit: 8) } ?? "None",
                 newCD?.cdHash.map { MachOHexadecimal.bytes($0, limit: 8) } ?? "None")

            let oldKeys = Set(old.signature?.entitlements.keys ?? [])
            let newKeys = Set(new.signature?.entitlements.keys ?? [])
            for key in newKeys.subtracting(oldKeys).sorted() {
                differences.append(BinaryComparisonDifference(category: .entitlements, field: label("Entitlement"), before: "", after: key, change: .added))
            }
            for key in oldKeys.subtracting(newKeys).sorted() {
                differences.append(BinaryComparisonDifference(category: .entitlements, field: label("Entitlement"), before: key, after: "", change: .removed))
            }
            note(.signature, label("Requirements"), requirementsText(old.signature), requirementsText(new.signature))

            let oldLibraries = Set(old.libraries.map(\.installName))
            let newLibraries = Set(new.libraries.map(\.installName))
            for library in newLibraries.subtracting(oldLibraries).sorted() {
                differences.append(BinaryComparisonDifference(category: .libraries, field: label("Library"), before: "", after: library, change: .added))
            }
            for library in oldLibraries.subtracting(newLibraries).sorted() {
                differences.append(BinaryComparisonDifference(category: .libraries, field: label("Library"), before: library, after: "", change: .removed))
            }

            note(.build, label("Platform"), old.platform?.displayName ?? "Not declared", new.platform?.displayName ?? "Not declared")
            note(.build, label("Minimum OS"), old.minimumOS?.description ?? "Not declared", new.minimumOS?.description ?? "Not declared")
            note(.build, label("SDK"), old.sdk?.description ?? "Not declared", new.sdk?.description ?? "Not declared")
            note(.build, label("Build UUID"), old.uuid ?? "None", new.uuid ?? "None")
        }

        note(.verification, "Verdict", before.verdict.displayName, after.verdict.displayName)
        for kind in BinaryVerificationCheckKind.allCases {
            guard let old = before.integrity?.check(kind), let new = after.integrity?.check(kind) else { continue }
            note(.verification, kind.title, old.status.displayName, new.status.displayName)
        }

        return BinaryComparison(differences: differences, comparedArchitectureNames: shared)
    }

    // MARK: - Field text

    private static func bytes(_ count: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file) + " (\(count.formatted()) bytes)"
    }

    private static func signerName(_ report: BinaryInspectionReport, index: Int) -> String {
        guard let result = report.integrity?.architectures.first(where: { $0.architectureIndex == index }) else {
            return "Not verified"
        }
        switch result.cms {
        case .absent, .empty: return "None (ad-hoc)"
        case .unreadable: return "Unreadable"
        case .evaluated(let evaluation): return evaluation.signer?.commonName ?? "Unknown"
        }
    }

    private static func encryptionText(_ architecture: BinaryArchitectureReport) -> String {
        guard let encryption = architecture.encryption else { return "No record" }
        return encryption.isEncrypted ? "Encrypted (cryptid \(encryption.cryptID))" : "Not encrypted"
    }

    private static func hashNames(_ signature: CodeSignatureSummary?) -> String {
        guard let signature, !signature.codeDirectories.isEmpty else { return "None" }
        return signature.codeDirectories.map(\.hashType.displayName).joined(separator: " + ")
    }

    private static func pageSizeText(_ directory: CodeDirectorySummary?) -> String {
        guard let directory else { return "None" }
        guard let size = directory.pageSize else { return "Unpaged" }
        return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .memory)
    }

    private static func boundSlots(_ directory: CodeDirectorySummary?) -> String {
        guard let directory else { return "None" }
        let titles = directory.specialSlots.filter(\.isBound).map(\.title)
        return titles.isEmpty ? "None" : titles.joined(separator: ", ")
    }

    private static func requirementsText(_ signature: CodeSignatureSummary?) -> String {
        guard let signature else { return "None" }
        switch signature.requirements.state {
        case .absent: return "None"
        case .malformed: return "Malformed"
        case .parsed, .unsupported:
            return signature.requirements.count == 0
                ? "Empty set"
                : signature.requirements.requirementKinds.joined(separator: ", ")
        }
    }
}
