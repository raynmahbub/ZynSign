import Foundation

/// Where a search result leads in the inspector.
enum BinarySearchDestination: Hashable {
    case architecture(architectureIndex: Int)
    case loadCommand(architectureIndex: Int, commandIndex: Int)
    case library(architectureIndex: Int, installName: String)
    case section(architectureIndex: Int)
    case signature(architectureIndex: Int)
    case codeDirectory(architectureIndex: Int)
}

/// One searchable fact about an executable.
struct BinarySearchEntry: Equatable, Identifiable {

    enum Scope: String, CaseIterable, Hashable {
        case architecture
        case loadCommand
        case library
        case section
        case signature

        var displayName: String {
            switch self {
            case .architecture: return "Architecture"
            case .loadCommand: return "Load Commands"
            case .library: return "Libraries"
            case .section: return "Sections"
            case .signature: return "Signature"
            }
        }

        var systemImage: String {
            switch self {
            case .architecture: return "cpu"
            case .loadCommand: return "list.bullet.indent"
            case .library: return "books.vertical"
            case .section: return "square.stack.3d.up"
            case .signature: return "signature"
            }
        }
    }

    let id: String
    let scope: Scope
    let architectureName: String
    let title: String
    let detail: String
    let destination: BinarySearchDestination
    /// The folded text the query is matched against.
    let searchText: String
}

/// A search index over one report, built once and queried on every
/// keystroke.
///
/// Matching is case- and diacritic-insensitive and requires every word of the
/// query to appear, so "load swift" finds the Swift libraries a slice loads.
/// Only values the inspector already shows are indexed; nothing is read again.
struct BinarySearchIndex {

    let entries: [BinarySearchEntry]

    init(report: BinaryInspectionReport) {
        var entries: [BinarySearchEntry] = []
        let multiple = report.architectures.count > 1
        for architecture in report.architectures {
            let index = architecture.index
            let archName = architecture.name
            func add(_ scope: BinarySearchEntry.Scope, _ key: String, _ title: String, _ detail: String,
                     _ destination: BinarySearchDestination, keywords: [String] = []) {
                let text = ([title, detail, archName] + keywords).joined(separator: " ")
                entries.append(BinarySearchEntry(
                    id: "\(index):\(scope.rawValue):\(key)",
                    scope: scope,
                    architectureName: multiple ? archName : "",
                    title: title,
                    detail: detail,
                    destination: destination,
                    searchText: Self.fold(text)
                ))
            }

            // Architecture fields.
            let archDestination = BinarySearchDestination.architecture(architectureIndex: index)
            add(.architecture, "name", "Architecture", archName, archDestination, keywords: ["arch", "cpu"])
            add(.architecture, "cpu", "CPU Type", "\(architecture.architecture.cpuTypeName) (\(architecture.architecture.rawCPUType))", archDestination)
            add(.architecture, "subtype", "CPU Subtype", "\(architecture.architecture.cpuSubtypeName) (\(architecture.architecture.subtypeValue))", archDestination)
            add(.architecture, "filetype", "Executable Type", "\(architecture.fileKind.displayName) (\(architecture.fileKind.constantName))", archDestination, keywords: ["file type"])
            add(.architecture, "offset", "File Offset", "\(architecture.fileOffset) (\(MachOHexadecimal.text(UInt64(architecture.fileOffset))))", archDestination)
            add(.architecture, "size", "Binary Size", ByteCountFormatter.string(fromByteCount: Int64(architecture.size), countStyle: .file), archDestination)
            if let platform = architecture.platform {
                add(.architecture, "platform", "Platform", platform.displayName, archDestination)
            }
            if let minimum = architecture.minimumOS {
                add(.architecture, "minos", "Minimum OS", minimum.description, archDestination, keywords: ["deployment target"])
            }
            if let sdk = architecture.sdk {
                add(.architecture, "sdk", "SDK", sdk.description, archDestination)
            }
            if let uuid = architecture.uuid {
                add(.architecture, "uuid", "Build UUID", uuid, archDestination)
            }
            for flag in architecture.headerFlags.known {
                add(.architecture, "flag-\(flag.mask)", "Header Flag", flag.name, archDestination, keywords: [flag.explanation])
            }

            // Load commands.
            for command in architecture.loadCommands {
                let descriptor = command.descriptor
                add(.loadCommand, "cmd-\(command.index)", descriptor.title,
                    "\(descriptor.name) · \(command.size) bytes" + Self.payloadSummary(command.payload).map { " · \($0)" }.joined(),
                    .loadCommand(architectureIndex: index, commandIndex: command.index),
                    keywords: [descriptor.category.displayName, descriptor.purpose])
            }

            // Libraries.
            for library in architecture.libraries {
                let description = LinkedLibraryDescription(reference: library)
                add(.library, "lib-\(library.installName)", description.displayName,
                    "\(library.installName) · \(library.kind.displayName) · \(library.currentVersion.description)",
                    .library(architectureIndex: index, installName: library.installName),
                    keywords: [description.origin.displayName])
            }
            for command in architecture.loadCommands {
                guard case .runPath(let path) = command.payload else { continue }
                add(.library, "rpath-\(command.index)", "Search Path", path,
                    .loadCommand(architectureIndex: index, commandIndex: command.index),
                    keywords: ["rpath", "@rpath"])
            }

            // Sections.
            for segment in architecture.segments {
                for section in segment.sections {
                    add(.section, "sect-\(section.id)", "\(section.segmentName),\(section.name)",
                        "\(section.typeName) · \(ByteCountFormatter.string(fromByteCount: Int64(section.size), countStyle: .memory))",
                        .section(architectureIndex: index), keywords: ["section", segment.name])
                }
            }

            // Signature fields.
            if let signature = architecture.signature {
                let signatureDestination = BinarySearchDestination.signature(architectureIndex: index)
                let directoryDestination = BinarySearchDestination.codeDirectory(architectureIndex: index)
                add(.signature, "form", "Signature Form", signature.form.displayName, signatureDestination, keywords: ["code signature"])
                for directory in signature.codeDirectories {
                    let key = "cd-\(directory.slotNumber)"
                    add(.signature, key + "-id", "Identifier", directory.identifier, directoryDestination, keywords: ["codedirectory", "bundle"])
                    if let team = directory.teamIdentifier {
                        add(.signature, key + "-team", "Team ID", team, directoryDestination, keywords: ["team identifier"])
                    }
                    add(.signature, key + "-hash", "Hash Algorithm", directory.hashType.displayName, directoryDestination, keywords: ["codedirectory", directory.slotLabel])
                    add(.signature, key + "-version", "CodeDirectory Version", directory.versionText, directoryDestination)
                    add(.signature, key + "-pages", "Pages", "\(directory.pageCount.formatted()) pages", directoryDestination, keywords: ["page hashes"])
                    if let cdHash = directory.cdHashText {
                        add(.signature, key + "-cdhash", "CDHash", cdHash, directoryDestination)
                    }
                    for flag in directory.decodedFlags.known {
                        add(.signature, key + "-flag-\(flag.mask)", "Signature Flag", flag.name, directoryDestination, keywords: [flag.explanation])
                    }
                    for slot in directory.specialSlots where slot.isBound {
                        add(.signature, key + "-slot-\(slot.number)", "Special Slot", slot.title, directoryDestination, keywords: ["bound"])
                    }
                }
                for entitlement in signature.entitlements.keys {
                    add(.signature, "ent-\(entitlement)", "Entitlement", entitlement, signatureDestination, keywords: ["entitlements"])
                }
                for kind in signature.requirements.requirementKinds {
                    add(.signature, "req-\(kind)", "Requirement", kind, signatureDestination, keywords: ["requirements"])
                }
                for blob in signature.blobs {
                    add(.signature, "blob-\(blob.slotNumber)", "Signature Blob", blob.title, signatureDestination, keywords: ["superblob"])
                }
            }
        }
        if let evaluation = report.integrity?.architectures.lazy.compactMap(\.cms.evaluation).first,
           let signer = evaluation.signer {
            let destination = BinarySearchDestination.signature(architectureIndex: report.architectures.first?.index ?? 0)
            if let name = signer.commonName {
                entries.append(BinarySearchEntry(
                    id: "signer-cn", scope: .signature, architectureName: "",
                    title: "Signer", detail: name, destination: destination,
                    searchText: Self.fold("Signer certificate CMS \(name)")
                ))
            }
            if let team = signer.organizationalUnit {
                entries.append(BinarySearchEntry(
                    id: "signer-ou", scope: .signature, architectureName: "",
                    title: "Signer Team", detail: team, destination: destination,
                    searchText: Self.fold("Signer team organizational unit \(team)")
                ))
            }
        }
        self.entries = entries
    }

    /// The entries matching `query`, in scope order, at most `limit`.
    /// An empty query matches nothing.
    func search(_ query: String, limit: Int = 300) -> [BinarySearchEntry] {
        let tokens = Self.fold(query).split(separator: " ").map(String.init).filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return [] }
        var matches: [BinarySearchEntry] = []
        for scope in BinarySearchEntry.Scope.allCases {
            for entry in entries where entry.scope == scope {
                if tokens.allSatisfy({ entry.searchText.contains($0) }) {
                    matches.append(entry)
                    if matches.count >= limit { return matches }
                }
            }
        }
        return matches
    }

    /// Case- and diacritic-folded text.
    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).lowercased()
    }

    /// A short value summary for a payload, shown and searched beside the
    /// command's name.
    static func payloadSummary(_ payload: MachOLoadCommandPayload) -> [String] {
        switch payload {
        case .segment(let segment): return [segment.name, "\(segment.sections.count) sections"]
        case .dylib(let reference): return [reference.installName]
        case .dynamicLinker(let path), .runPath(let path), .environment(let path): return [path]
        case .uuid(let value): return [value]
        case .buildVersion(let version): return ["\(version.platform.displayName) \(version.minimumOS)", "SDK \(version.sdk)"]
        case .minimumVersion(let version): return ["\(version.platform.displayName) \(version.version)", "SDK \(version.sdk)"]
        case .sourceVersion(let version): return version.isSet ? [version.description] : []
        case .entryPoint(let offset, _): return ["offset \(MachOHexadecimal.text(offset))"]
        case .encryption(let info): return [info.isEncrypted ? "encrypted (cryptid \(info.cryptID))" : "not encrypted"]
        case .linkEditData(let reference): return ["\(reference.dataSize) bytes of data"]
        case .dyldInfo: return []
        case .symbolTable(let info): return ["\(info.symbolCount) symbols"]
        case .dynamicSymbolTable(let info): return ["\(info.undefinedSymbolCount) imported symbols"]
        case .linkerOptions(let count): return ["\(count) options"]
        case .note(let owner, _, _): return [owner]
        case .opaque: return []
        case .malformed(let issue): return ["could not be decoded: \(issue.explanation)"]
        }
    }
}
