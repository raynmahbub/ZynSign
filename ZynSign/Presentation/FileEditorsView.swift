import SwiftUI

/// Visual & Raw XML Property List Editor for `.plist`, `.entitlements`, `.strings`,
/// and `.mobileconfig` files inside `FilesView`.
struct FilePlistEditorSheet: View {
    let fileURL: URL
    let onSaved: () -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var originalRoot: [String: PlistCustomValue] = [:]
    @State private var workingRoot: [String: PlistCustomValue] = [:]
    @State private var rawXML = ""
    @State private var outputFormat: PlistDocumentCodec.Format = .xml
    @State private var isRawXMLMode = false
    @State private var newKey = ""
    @State private var newKind: PlistCustomValue.ValueKind = .string
    @State private var newString = ""
    @State private var newBool = true
    @State private var newInt = "0"
    @State private var statusMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("View Mode", selection: $isRawXMLMode) {
                        Text("Visual Dictionary").tag(false)
                        Text("Raw XML").tag(true)
                    }
                    .pickerStyle(.segmented)
                    Picker("Save Format", selection: $outputFormat) {
                        ForEach(PlistDocumentCodec.Format.allCases, id: \.self) { fmt in
                            Text(fmt.rawValue).tag(fmt)
                        }
                    }
                }

                if let statusMessage {
                    Section {
                        Text(statusMessage).font(ZTypography.caption).foregroundStyle(.orange)
                    }
                }

                if isRawXMLMode {
                    Section("XML Property List") {
                        TextEditor(text: $rawXML)
                            .font(ZTypography.codeCaption)
                            .frame(minHeight: 280)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                    }
                } else {
                    Section("Add or Update Key") {
                        TextField("Key", text: $newKey)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                        Picker("Type", selection: $newKind) {
                            ForEach([PlistCustomValue.ValueKind.string, .boolean, .integer], id: \.self) { kind in
                                Text(kind.rawValue).tag(kind)
                            }
                        }
                        switch newKind {
                        case .string:
                            TextField("Value", text: $newString)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                        case .boolean:
                            Toggle("Boolean Value", isOn: $newBool)
                        case .integer:
                            TextField("Integer", text: $newInt).keyboardType(.numbersAndPunctuation)
                        default:
                            EmptyView()
                        }
                        Button {
                            applyKeyUpdate()
                        } label: {
                            Label("Set Key", systemImage: "plus.circle.fill")
                                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        }
                        .disabled(newKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }

                    Section("Entries (\(workingRoot.count))") {
                        ForEach(workingRoot.keys.sorted(), id: \.self) { key in
                            if let value = workingRoot[key] {
                                plistEntryRow(key: key, value: value)
                            }
                        }
                    }

                    let changes = PlistDocumentCodec.diffSummary(before: originalRoot, after: workingRoot)
                    if !changes.isEmpty {
                        Section("Pending Changes (\(changes.count))") {
                            ForEach(changes, id: \.self) { line in
                                Text(line).font(ZTypography.codeCaption)
                            }
                        }
                    }
                }
            }
            .navigationTitle(fileURL.lastPathComponent)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { saveDocument() }
                }
            }
            .task { loadDocument() }
            .onChange(of: isRawXMLMode) { _, nowRaw in
                if nowRaw {
                    rawXML = (try? PlistDocumentCodec.renderXML(workingRoot)) ?? rawXML
                } else if let parsed = try? PlistDocumentCodec.parseXML(rawXML) {
                    workingRoot = parsed
                }
            }
        }
    }

    @ViewBuilder
    private func plistEntryRow(key: String, value: PlistCustomValue) -> some View {
        HStack(spacing: ZSpacing.sm) {
            VStack(alignment: .leading, spacing: ZSpacing.xxs) {
                Text(key).font(ZTypography.codeCaption)
                Text("\(value.kindLabel): \(value.summaryText)")
                    .font(ZTypography.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            if case .boolean(let flag) = value {
                Toggle("", isOn: Binding(
                    get: { flag },
                    set: { workingRoot[key] = .boolean($0) }
                ))
                .labelsHidden()
            }
            Button(role: .destructive) {
                workingRoot.removeValue(forKey: key)
            } label: {
                Image(systemName: "trash").frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
        }
    }

    private func loadDocument() {
        do {
            let data = try Data(contentsOf: fileURL)
            let decoded = try PlistDocumentCodec.decode(data)
            originalRoot = decoded.root
            workingRoot = decoded.root
            outputFormat = decoded.detectedFormat
            rawXML = decoded.rawXML
            statusMessage = nil
        } catch let err as PlistDocumentCodec.CodecError {
            statusMessage = err.message
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func applyKeyUpdate() {
        let key = newKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        switch newKind {
        case .string:
            workingRoot[key] = .string(newString)
        case .boolean:
            workingRoot[key] = .boolean(newBool)
        case .integer:
            workingRoot[key] = .integer(Int(newInt) ?? 0)
        default:
            break
        }
        newKey = ""
        newString = ""
    }

    private func saveDocument() {
        do {
            let rootToSave: [String: PlistCustomValue]
            if isRawXMLMode {
                rootToSave = try PlistDocumentCodec.parseXML(rawXML)
            } else {
                rootToSave = workingRoot
            }
            let out = try PlistDocumentCodec.encode(rootToSave, format: outputFormat)
            try out.write(to: fileURL, options: .atomic)
            ZHaptics.success()
            onSaved()
            dismiss()
        } catch let err as PlistDocumentCodec.CodecError {
            statusMessage = err.message
        } catch {
            statusMessage = error.localizedDescription
        }
    }
}

/// In-app UTF-8 Text Editor for text, JSON, XML, markdown, and log files.
struct FileTextEditorSheet: View {
    let fileURL: URL
    let onSaved: () -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var content = ""
    @State private var statusMessage: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: ZSpacing.xs) {
                if let statusMessage {
                    Text(statusMessage)
                        .font(ZTypography.caption)
                        .foregroundStyle(.orange)
                        .padding(.horizontal, ZSpacing.md)
                }
                TextEditor(text: $content)
                    .font(ZTypography.codeCaption)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .padding(.horizontal, ZSpacing.sm)
                HStack {
                    Text("\(content.components(separatedBy: .newlines).count) line(s)")
                    Spacer()
                    Text("\(content.utf8.count) bytes")
                }
                .font(ZTypography.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, ZSpacing.md)
                .padding(.bottom, ZSpacing.sm)
            }
            .navigationTitle(fileURL.lastPathComponent)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        do {
                            try Data(content.utf8).write(to: fileURL, options: .atomic)
                            ZHaptics.success()
                            onSaved()
                            dismiss()
                        } catch {
                            statusMessage = error.localizedDescription
                        }
                    }
                }
            }
            .task {
                if let data = try? Data(contentsOf: fileURL),
                   data.count <= 4 * 1_024 * 1_024,
                   let text = String(data: data, encoding: .utf8) {
                    content = text
                } else {
                    statusMessage = "File is binary or exceeds the 4 MiB text editor bound. Use Hex Inspector."
                }
            }
        }
    }
}

/// Paginated Hex + ASCII Inspector & Byte Editor for files inside `FilesView`.
struct FileHexInspectorSheet: View {
    let fileURL: URL
    let onSaved: () -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var data = Data()
    @State private var pageOffset = 0
    @State private var isEditingHex = false
    @State private var editableHexText = ""
    @State private var errorMessage: String?

    private let pageByteSize = 16 * 128
    private let maxEditableBytes = 256 * 1_024

    var body: some View {
        NavigationStack {
            List {
                Section("Summary") {
                    LabeledContent("File", value: fileURL.lastPathComponent)
                    LabeledContent("Total Size", value: ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file))
                    if data.count <= maxEditableBytes {
                        Toggle("Edit Raw Hex Bytes", isOn: $isEditingHex)
                    }
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage).font(ZTypography.caption).foregroundStyle(.orange)
                    }
                }

                if isEditingHex {
                    Section("Hex Byte Editor") {
                        TextEditor(text: $editableHexText)
                            .font(ZTypography.codeCaption)
                            .frame(minHeight: 240)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                        Button {
                            saveEditedHex()
                        } label: {
                            Label("Write Bytes to File", systemImage: "externaldrive.badge.checkmark")
                                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        }
                    }
                } else {
                    Section {
                        HStack(spacing: ZSpacing.sm) {
                            Button {
                                pageOffset = max(0, pageOffset - pageByteSize)
                            } label: {
                                Label("Prev", systemImage: "chevron.left")
                                    .frame(minHeight: 44)
                            }
                            .disabled(pageOffset == 0)
                            Spacer()
                            Text(String(format: "0x%08X", pageOffset))
                                .font(ZTypography.codeCaption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button {
                                if pageOffset + pageByteSize < data.count {
                                    pageOffset += pageByteSize
                                }
                            } label: {
                                Label("Next", systemImage: "chevron.right")
                                    .frame(minHeight: 44)
                            }
                            .disabled(pageOffset + pageByteSize >= data.count)
                        }
                    }

                    Section("Hex + ASCII") {
                        let rows = HexDumpFormatter.formatWindow(data: data, startOffset: pageOffset)
                        ForEach(rows) { row in
                            VStack(alignment: .leading, spacing: ZSpacing.xxs) {
                                Text("\(row.offsetHex)  \(row.asciiPreview)")
                                    .font(ZTypography.codeCaption)
                                    .foregroundStyle(.secondary)
                                Text(row.bytesHex)
                                    .font(ZTypography.codeCaption)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Hex Inspector")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { loadBytes() }
            .onChange(of: isEditingHex) { _, editing in
                if editing {
                    editableHexText = HexDumpFormatter.encodeHexString(data)
                }
            }
        }
    }

    private func loadBytes() {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else {
            errorMessage = "Could not open file."
            return
        }
        defer { try? handle.close() }
        data = (try? handle.read(upToCount: 8 * 1_024 * 1_024)) ?? Data()
    }

    private func saveEditedHex() {
        do {
            let parsed = try HexDumpFormatter.parseHexBytes(editableHexText)
            try parsed.write(to: fileURL, options: .atomic)
            data = parsed
            isEditingHex = false
            ZHaptics.success()
            onSaved()
        } catch let err as HexDumpFormatter.HexParseError {
            errorMessage = err.message
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
