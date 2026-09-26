import SwiftUI

// MARK: - Architecture inspector

/// One architecture, presented visually: what it is, where it sits in the
/// file, and what it was built for. Offsets and type codes in hexadecimal are
/// kept in the collapsed advanced details.
struct ArchitectureInspectorCard: View {
    let report: BinaryInspectionReport
    let architecture: BinaryArchitectureReport

    var body: some View {
        ZCard {
            VStack(alignment: .leading, spacing: ZSpacing.sm) {
                HStack(alignment: .firstTextBaseline) {
                    Text(architecture.name)
                        .font(.title2.weight(.bold).monospaced())
                        .accessibilityLabel("Architecture \(architecture.name)")
                    Spacer(minLength: ZSpacing.xs)
                    if architecture.architecture.isARM64E {
                        ZStatusBadge("Pointer authentication", systemImage: "lock.shield", kind: .info)
                    } else if !architecture.architecture.isAppleDeviceArchitecture {
                        ZStatusBadge("Not for iPhone or iPad", systemImage: "exclamationmark.triangle", kind: .warning)
                    }
                }
                Text(architecture.architecture.explanation)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                ArchitecturePlacementBar(
                    fileSize: report.fileSize,
                    offset: architecture.fileOffset,
                    size: architecture.size,
                    label: architecture.name
                )

                BinaryFieldRow(label: "CPU type", value: cpuTypeText,
                               explanation: "The processor family the code is compiled for.")
                BinaryFieldRow(label: "CPU subtype", value: architecture.architecture.name,
                               explanation: "The processor variant within the family.")
                BinaryFieldRow(label: "Executable type", value: architecture.fileKind.displayName,
                               explanation: architecture.fileKind.explanation)
                BinaryFieldRow(label: "File offset", value: offsetText,
                               explanation: "Where this architecture's code begins in the file.")
                BinaryFieldRow(label: "Binary size", value: BinaryFormat.bytesDetailed(architecture.size),
                               explanation: "How much of the file this architecture occupies.")
                if let platform = architecture.platform {
                    BinaryFieldRow(label: "Built for", value: platformText(platform),
                                   explanation: "The platform, minimum OS version, and SDK the build declares.")
                }
                if let uuid = architecture.uuid {
                    BinaryFieldRow(label: "Build UUID", value: uuid, monospaced: true)
                }
                BinaryFieldRow(label: "Encryption", value: encryptionText,
                               explanation: encryptionExplanation)

                if !architecture.segments.isEmpty {
                    SegmentLayoutView(segments: architecture.segments)
                }

                BinaryAdvancedDetails {
                    BinaryFieldRow(label: "CPU type code", value: "\(architecture.architecture.cpuTypeName) · \(MachOHexadecimal.text(UInt64(UInt32(bitPattern: architecture.architecture.rawCPUType))))", monospaced: true)
                    BinaryFieldRow(label: "CPU subtype code", value: "\(architecture.architecture.cpuSubtypeName) · \(MachOHexadecimal.text(UInt64(UInt32(bitPattern: architecture.architecture.cpuSubtype))))", monospaced: true)
                    if let version = architecture.architecture.pointerAuthenticationABIVersion {
                        BinaryFieldRow(label: "Pointer authentication ABI", value: "Version \(version)")
                    }
                    BinaryFieldRow(label: "File type code", value: "\(architecture.fileKind.constantName) · \(architecture.fileKind.rawValue)", monospaced: true)
                    BinaryFieldRow(label: "File offset", value: MachOHexadecimal.text(UInt64(architecture.fileOffset)), monospaced: true)
                    if let alignment = architecture.alignmentExponent {
                        BinaryFieldRow(label: "Alignment", value: "2^\(alignment) (\(BinaryFormat.memory(1 << Int(min(alignment, 30)))))")
                    }
                    BinaryFieldRow(label: "Header flags", value: architecture.headerFlags.summary)
                    ForEach(architecture.headerFlags.known) { flag in
                        BinaryFieldRow(label: flag.name, value: MachOHexadecimal.text(flag.mask), explanation: flag.explanation, monospaced: true)
                    }
                    if let entry = architecture.entryPointOffset {
                        BinaryFieldRow(label: "Entry point offset", value: MachOHexadecimal.text(entry), monospaced: true)
                    }
                    if let linker = architecture.dynamicLinker {
                        BinaryFieldRow(label: "Dynamic linker", value: linker, monospaced: true)
                    }
                }
            }
        }
    }

    private var cpuTypeText: String {
        switch architecture.architecture.cpu {
        case .arm64: return "ARM64"
        case .arm: return "ARM (32-bit)"
        case .x86_64: return "x86-64"
        case .x86: return "x86 (32-bit)"
        case .other(let value): return "Unrecognized (\(value))"
        }
    }

    private var offsetText: String {
        architecture.fileOffset == 0 ? "Start of file" : BinaryFormat.bytesDetailed(architecture.fileOffset) + " from the start"
    }

    private func platformText(_ platform: MachOPlatform) -> String {
        var text = platform.displayName
        if let minimum = architecture.minimumOS { text += " \(minimum) or later" }
        if let sdk = architecture.sdk { text += " · SDK \(sdk)" }
        return text
    }

    private var encryptionText: String {
        guard let encryption = architecture.encryption else { return "Not Encrypted" }
        return encryption.isEncrypted ? "Encrypted" : "Not Encrypted"
    }

    private var encryptionExplanation: String {
        guard let encryption = architecture.encryption else { return BinaryEncryptionState.notDeclared.explanation }
        return encryption.isEncrypted ? BinaryEncryptionState.encrypted.explanation : BinaryEncryptionState.notEncrypted.explanation
    }
}

/// A bar showing where one architecture sits within the whole file.
struct ArchitecturePlacementBar: View {
    let fileSize: Int
    let offset: Int
    let size: Int
    let label: String

    var body: some View {
        let total = Double(max(fileSize, 1))
        let start = min(1, Double(max(offset, 0)) / total)
        let width = max(0.01, min(1 - start, Double(max(size, 0)) / total))
        return VStack(alignment: .leading, spacing: 4) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color(.tertiarySystemFill))
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: proxy.size.width * CGFloat(width))
                        .offset(x: proxy.size.width * CGFloat(start))
                }
            }
            .frame(height: 10)
            Text("\(label) occupies \(BinaryFormat.percent(Double(size) / total)) of the file")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label) occupies \(BinaryFormat.percent(Double(size) / total)) of the file, starting \(offset == 0 ? "at the beginning" : BinaryFormat.bytes(offset) + " in").")
    }
}

/// The file-backed segments of one architecture, as proportional rows.
struct SegmentLayoutView: View {
    let segments: [MachOSegmentSummary]

    var body: some View {
        let fileBacked = segments.filter { $0.fileSize > 0 }
        let total = Double(max(1, fileBacked.reduce(UInt64(0)) { $0 + $1.fileSize }))
        return VStack(alignment: .leading, spacing: ZSpacing.xs) {
            Text("Segments")
                .font(.subheadline.weight(.semibold))
            ForEach(segments) { segment in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(segment.name)
                            .font(.system(.subheadline, design: .monospaced))
                        Spacer(minLength: ZSpacing.xs)
                        Text(segment.fileSize == 0 ? "Not in file" : BinaryFormat.bytes(Int(clamping: segment.fileSize)))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if segment.fileSize > 0 {
                        let fraction = CGFloat(Double(segment.fileSize) / total)
                        GeometryReader { proxy in
                            Capsule()
                                .fill(Color.accentColor.opacity(0.7))
                                .frame(width: max(4, proxy.size.width * fraction))
                        }
                        .frame(height: 6)
                    }
                    Text("\(segment.explanation) Memory protection: \(segment.initialProtection.spokenDescription).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}

// MARK: - Load command explorer

/// Every load command of one architecture, grouped for reading. Each row
/// shows the command's name, purpose, size, and important values; technical
/// values stay in collapsed advanced details.
struct LoadCommandExplorerView: View {
    let architecture: BinaryArchitectureReport

    var body: some View {
        List {
            Section {
                Text("Load commands tell the system how to load \(architecture.name): its memory layout, the libraries it needs, its signature, and its build identity. They are listed exactly as the binary declares them.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ForEach(MachOLoadCommandCategory.allCases, id: \.self) { category in
                let commands = architecture.loadCommands.filter { $0.descriptor.category == category }
                if !commands.isEmpty {
                    Section {
                        ForEach(commands) { command in
                            LoadCommandRow(content: LoadCommandRowContent(command: command))
                        }
                    } header: {
                        Label("\(category.displayName) (\(commands.count))", systemImage: category.systemImage)
                    } footer: {
                        Text(category.explanation)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Load Commands")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// The display values for one load command.
struct LoadCommandRowContent: Equatable {
    let title: String
    let name: String
    let purpose: String
    let sizeText: String
    let values: [String]
    let isMalformed: Bool
    let advanced: [(String, String)]

    static func == (lhs: LoadCommandRowContent, rhs: LoadCommandRowContent) -> Bool {
        lhs.title == rhs.title && lhs.name == rhs.name && lhs.values == rhs.values
            && lhs.sizeText == rhs.sizeText && lhs.isMalformed == rhs.isMalformed
            && lhs.advanced.map { $0.0 + "=" + $0.1 } == rhs.advanced.map { $0.0 + "=" + $0.1 }
    }

    init(command: MachODecodedLoadCommand) {
        let descriptor = command.descriptor
        self.title = descriptor.title
        self.name = descriptor.name
        self.purpose = descriptor.purpose
        self.sizeText = command.size == 1 ? "1 byte" : "\(command.size.formatted()) bytes"
        var values: [String] = []
        var advanced: [(String, String)] = [
            ("Type code", descriptor.typeCodeText),
            ("Position", "Command \(command.index + 1)"),
            ("File offset", MachOHexadecimal.text(UInt64(command.fileRange.lowerBound))),
            ("Requires dynamic linker", descriptor.requiresDynamicLinker ? "Yes" : "No"),
        ]
        var malformed = false
        switch command.payload {
        case .segment(let segment):
            values.append("\(segment.name) · \(BinaryFormat.bytes(Int(clamping: segment.fileSize))) in file · \(segment.initialProtection.spokenDescription)")
            if !segment.sections.isEmpty {
                values.append("Sections: " + segment.sections.map(\.name).joined(separator: ", "))
            }
            advanced.append(("Virtual address", MachOHexadecimal.text(segment.virtualAddress)))
            advanced.append(("Virtual size", BinaryFormat.bytes(Int(clamping: segment.virtualSize))))
            advanced.append(("Segment file offset", MachOHexadecimal.text(segment.fileOffset)))
            advanced.append(("Protection", "\(segment.initialProtection) (maximum \(segment.maximumProtection))"))
        case .dylib(let reference):
            let description = LinkedLibraryDescription(reference: reference)
            values.append("\(description.displayName) · \(reference.kind.displayName)")
            values.append(reference.installName)
            advanced.append(("Current version", reference.currentVersion.description))
            advanced.append(("Compatibility version", reference.compatibilityVersion.description))
        case .dynamicLinker(let path):
            values.append(path)
        case .runPath(let path):
            values.append(path)
        case .environment(let setting):
            values.append(setting)
        case .uuid(let value):
            values.append(value)
        case .buildVersion(let version):
            values.append("\(version.platform.displayName) \(version.minimumOS) or later")
            values.append("Built with SDK \(version.sdk)")
            for tool in version.tools {
                advanced.append(("Tool: \(tool.name)", tool.version.description))
            }
        case .minimumVersion(let version):
            values.append("\(version.platform.displayName) \(version.version) or later")
            values.append("Built with SDK \(version.sdk)")
        case .sourceVersion(let version):
            values.append(version.isSet ? version.description : "Not set by the project")
        case .entryPoint(let offset, let stackSize):
            values.append("Starts \(BinaryFormat.bytes(Int(clamping: offset))) into the file")
            advanced.append(("Entry offset", MachOHexadecimal.text(offset)))
            advanced.append(("Stack size", stackSize == 0 ? "Default" : BinaryFormat.bytes(Int(clamping: stackSize))))
        case .encryption(let info):
            values.append(info.isEncrypted ? "Encrypted (cryptid \(info.cryptID))" : "Not encrypted (cryptid 0)")
            values.append("Protected range: \(BinaryFormat.bytes(Int(info.cryptSize)))")
            advanced.append(("Range offset", MachOHexadecimal.text(UInt64(info.cryptOffset))))
        case .linkEditData(let reference):
            values.append("\(BinaryFormat.bytes(Int(reference.dataSize))) of data in __LINKEDIT")
            advanced.append(("Data offset", MachOHexadecimal.text(UInt64(reference.dataOffset))))
        case .dyldInfo(let info):
            values.append("Rebase \(BinaryFormat.bytes(Int(info.rebaseSize))) · Bind \(BinaryFormat.bytes(Int(info.bindSize))) · Export \(BinaryFormat.bytes(Int(info.exportSize)))")
            advanced.append(("Weak binding", BinaryFormat.bytes(Int(info.weakBindSize))))
            advanced.append(("Lazy binding", BinaryFormat.bytes(Int(info.lazyBindSize))))
        case .symbolTable(let info):
            values.append("\(info.symbolCount.formatted()) symbols")
            advanced.append(("String table", BinaryFormat.bytes(Int(info.stringTableSize))))
        case .dynamicSymbolTable(let info):
            values.append("\(info.localSymbolCount.formatted()) local · \(info.externalSymbolCount.formatted()) exported · \(info.undefinedSymbolCount.formatted()) imported")
            advanced.append(("Indirect symbols", info.indirectSymbolCount.formatted()))
        case .linkerOptions(let count):
            values.append("\(count) option(s)")
        case .note(let owner, let offset, let size):
            values.append("Owner: \(owner)")
            advanced.append(("Note offset", MachOHexadecimal.text(offset)))
            advanced.append(("Note size", BinaryFormat.bytes(Int(clamping: size))))
        case .opaque:
            values.append(descriptor.isRecognized ? "Listed without decoding its values." : "Unrecognized command type.")
        case .malformed(let issue):
            values.append("Could not be decoded: \(issue.explanation)")
            malformed = true
        }
        self.values = values
        self.isMalformed = malformed
        self.advanced = advanced
    }
}

/// One load command in the explorer.
struct LoadCommandRow: View {
    let content: LoadCommandRowContent

    var body: some View {
        VStack(alignment: .leading, spacing: ZSpacing.xs) {
            HStack(alignment: .firstTextBaseline) {
                Text(content.title)
                    .font(.headline)
                Spacer(minLength: ZSpacing.xs)
                Text(content.sizeText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Text(content.name)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
            Text(content.purpose)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if content.isMalformed {
                ZStatusBadge("Could not be decoded", systemImage: "exclamationmark.triangle", kind: .warning)
            }
            ForEach(content.values, id: \.self) { value in
                Text(value)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            BinaryAdvancedDetails {
                ForEach(content.advanced.indices, id: \.self) { index in
                    BinaryFieldRow(label: content.advanced[index].0, value: content.advanced[index].1, monospaced: true)
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(content.title), \(content.name), \(content.sizeText). \(content.values.joined(separator: ". "))")
    }
}

// MARK: - Library dependencies

/// The libraries one architecture loads, drawn as a tree under the
/// executable. Embedded libraries open their own inspection page.
struct LibraryDependencyView: View {
    @ObservedObject var model: BinaryInspectorModel
    let report: BinaryInspectionReport
    let architecture: BinaryArchitectureReport

    var body: some View {
        let libraries = architecture.libraries.map { LinkedLibraryDescription(reference: $0) }
        return List {
            Section {
                HStack(spacing: ZSpacing.sm) {
                    Image(systemName: report.target.kind.systemImage)
                        .foregroundStyle(Color.accentColor)
                        .accessibilityHidden(true)
                    Text(report.target.name)
                        .font(.headline)
                    Spacer(minLength: 0)
                    Text(architecture.name)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(report.target.name), \(architecture.name), loads \(libraries.count) libraries")
                ForEach(Array(libraries.enumerated()), id: \.offset) { position, library in
                    NavigationLink {
                        LibraryDetailView(
                            model: model,
                            library: library,
                            resolvedTarget: library.resolvedTarget(in: model.targets)
                        )
                    } label: {
                        LibraryTreeRow(library: library, isLast: position == libraries.count - 1)
                    }
                }
            } header: {
                Text("Dependency Tree")
            } footer: {
                Text("Libraries are listed in the order the executable declares them. System libraries are part of iOS and are not in this package; embedded libraries ship inside the app and can be inspected.")
            }

            if !architecture.runPaths.isEmpty {
                Section {
                    ForEach(architecture.runPaths, id: \.self) { path in
                        Text(path)
                            .font(.system(.subheadline, design: .monospaced))
                            .textSelection(.enabled)
                    }
                } header: {
                    Text("Library Search Paths")
                } footer: {
                    Text("Folders the loader searches when a library path begins with @rpath.")
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Library Dependencies")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// One library in the tree: a connector, its name, where it comes from, and
/// how it is loaded.
struct LibraryTreeRow: View {
    let library: LinkedLibraryDescription
    let isLast: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: ZSpacing.xs) {
            Text(isLast ? "└──" : "├──")
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(library.displayName)
                    .font(.body.weight(.medium))
                HStack(spacing: 4) {
                    Image(systemName: library.origin.systemImage)
                        .accessibilityHidden(true)
                    Text(library.origin.displayName)
                    if library.reference.kind != .required {
                        Text("· \(library.reference.kind.displayName)")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .frame(minHeight: 44, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(library.displayName), \(library.origin.displayName), \(library.reference.kind.displayName)")
    }
}

/// One linked library's own page. When the library ships inside the app, it
/// leads to that executable's inspection page.
struct LibraryDetailView: View {
    @ObservedObject var model: BinaryInspectorModel
    let library: LinkedLibraryDescription
    let resolvedTarget: BinaryTarget?

    var body: some View {
        List {
            Section {
                BinaryFieldRow(label: "Name", value: library.displayName)
                BinaryFieldRow(label: "Install name", value: library.reference.installName, monospaced: true)
                BinaryFieldRow(label: "Origin", value: library.origin.displayName, explanation: library.origin.explanation)
                BinaryFieldRow(label: "Load", value: library.reference.kind.displayName, explanation: library.reference.kind.explanation)
                BinaryFieldRow(label: "Current version", value: library.reference.currentVersion.description)
                BinaryFieldRow(label: "Compatible with", value: "\(library.reference.compatibilityVersion.description) and later",
                               explanation: "The oldest version of the library this executable was linked to be compatible with.")
            }
            Section {
                if let target = resolvedTarget {
                    NavigationLink {
                        BinaryExecutableView(model: model, target: target)
                    } label: {
                        Label("Inspect \(target.name)", systemImage: "magnifyingglass")
                            .frame(minHeight: 44, alignment: .leading)
                    }
                    .accessibilityHint("Opens the inspection page for this embedded library.")
                } else if library.origin == .embedded {
                    Text("No executable in this bundle matches this install name, so it cannot be inspected here. It may be resolved through a search path ZynSign does not evaluate.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Text("This library is provided by the system, not by the app, so there is nothing in this package to inspect.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Inspection")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(library.displayName)
        .navigationBarTitleDisplayMode(.inline)
    }
}
