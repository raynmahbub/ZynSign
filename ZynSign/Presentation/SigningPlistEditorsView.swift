import SwiftUI

/// Pre-signing Visual & Raw XML `Info.plist` Overrides Editor,
/// including `UIBackgroundModes` quick toggles, typed key overrides, key removals,
/// and Raw XML Plist validation.
struct SigningInfoPlistOverridesSheet: View {
    @Binding var draft: SideloadOptionsDraft
    @Environment(\.dismiss) private var dismiss

    @State private var mode: EditorMode = .visual
    @State private var newKey = ""
    @State private var newKind: PlistCustomValue.ValueKind = .string
    @State private var newStringValue = ""
    @State private var newBoolValue = true
    @State private var newIntValue = "0"
    @State private var newRealValue = "0.0"
    @State private var removalKey = ""
    @State private var xmlValidationMessage: String?

    enum EditorMode: String, CaseIterable {
        case visual = "Visual Keys"
        case rawXML = "Raw XML"
    }

    private static let backgroundModes: [(id: String, label: String)] = [
        ("audio", "Audio / AirPlay / PiP"),
        ("fetch", "Background Fetch"),
        ("processing", "Background Processing"),
        ("remote-notification", "Remote Notifications"),
        ("location", "Location Updates"),
        ("voip", "Voice over IP")
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Mode", selection: $mode) {
                        ForEach(EditorMode.allCases, id: \.self) { item in
                            Text(item.rawValue).tag(item)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                switch mode {
                case .visual:
                    backgroundModesSection
                    addCustomKeySection
                    activeOverridesSection
                    removedKeysSection
                case .rawXML:
                    rawXMLSection
                }
            }
            .navigationTitle("Info.plist Editor")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var backgroundModesSection: some View {
        Section {
            ForEach(Self.backgroundModes, id: \.id) { modeItem in
                Toggle(modeItem.label, isOn: Binding(
                    get: { activeBackgroundModes.contains(modeItem.id) },
                    set: { toggleBackgroundMode(modeItem.id, enabled: $0) }
                ))
            }
        } header: {
            Text("UIBackgroundModes")
        } footer: {
            Text("Writes the selected background execution modes into Info.plist before signing.")
        }
    }

    private var addCustomKeySection: some View {
        Section("Add or Override Info.plist Key") {
            TextField("Key (e.g. ITSAppUsesNonExemptEncryption)", text: $newKey)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            Picker("Type", selection: $newKind) {
                ForEach([PlistCustomValue.ValueKind.string, .boolean, .integer, .real], id: \.self) { kind in
                    Text(kind.rawValue).tag(kind)
                }
            }
            switch newKind {
            case .string:
                TextField("String value", text: $newStringValue)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            case .boolean:
                Toggle("Boolean value", isOn: $newBoolValue)
            case .integer:
                TextField("Integer value", text: $newIntValue)
                    .keyboardType(.numbersAndPunctuation)
            case .real:
                TextField("Decimal value", text: $newRealValue)
                    .keyboardType(.decimalPad)
            case .array, .dictionary:
                EmptyView()
            }
            Button {
                commitNewEntry()
            } label: {
                Label("Set Key Override", systemImage: "plus.circle.fill")
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            }
            .disabled(newKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private var activeOverridesSection: some View {
        Section("Configured Key Overrides (\(draft.customInfoPlistEntries.count))") {
            if draft.customInfoPlistEntries.isEmpty {
                Text("No custom Info.plist key overrides set.")
                    .font(ZTypography.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(draft.customInfoPlistEntries.keys.sorted(), id: \.self) { key in
                    if let val = draft.customInfoPlistEntries[key] {
                        HStack(spacing: ZSpacing.sm) {
                            VStack(alignment: .leading, spacing: ZSpacing.xxs) {
                                Text(key).font(ZTypography.codeCaption)
                                Text("\(val.kindLabel): \(val.summaryText)")
                                    .font(ZTypography.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button(role: .destructive) {
                                draft.customInfoPlistEntries.removeValue(forKey: key)
                            } label: {
                                Image(systemName: "trash")
                                    .frame(width: 44, height: 44)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    private var removedKeysSection: some View {
        Section("Keys to Remove (\(draft.customInfoPlistRemovals.count))") {
            HStack(spacing: ZSpacing.sm) {
                TextField("Key to strip (e.g. UIRequiredDeviceCapabilities)", text: $removalKey)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                Button("Add") {
                    let trimmed = removalKey.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty, !draft.customInfoPlistRemovals.contains(trimmed) {
                        draft.customInfoPlistRemovals.append(trimmed)
                        removalKey = ""
                    }
                }
                .frame(minHeight: 44)
            }
            ForEach(draft.customInfoPlistRemovals, id: \.self) { key in
                HStack {
                    Text(key).font(ZTypography.codeCaption)
                    Spacer()
                    Button(role: .destructive) {
                        draft.customInfoPlistRemovals.removeAll { $0 == key }
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var rawXMLSection: some View {
        Section {
            TextEditor(text: $draft.rawInfoPlistXMLOverride)
                .font(ZTypography.codeCaption)
                .frame(minHeight: 240)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            Button {
                validateRawXML()
            } label: {
                Label("Validate XML Property List", systemImage: "checkmark.seal")
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            }
            if !draft.rawInfoPlistXMLOverride.isEmpty {
                Button(role: .destructive) {
                    draft.rawInfoPlistXMLOverride = ""
                    xmlValidationMessage = nil
                } label: {
                    Label("Clear Raw XML Override", systemImage: "xmark.circle")
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                }
            }
            if let xmlValidationMessage {
                Text(xmlValidationMessage)
                    .font(ZTypography.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Full Raw Info.plist XML Override")
        } footer: {
            Text("Leave empty to merge visual overrides into the package's existing Info.plist. Providing raw XML replaces the entire dictionary.")
        }
    }

    private var activeBackgroundModes: [String] {
        guard case .array(let items)? = draft.customInfoPlistEntries["UIBackgroundModes"] else {
            return []
        }
        return items.compactMap {
            if case .string(let s) = $0 { return s }
            return nil
        }
    }

    private func toggleBackgroundMode(_ id: String, enabled: Bool) {
        var current = activeBackgroundModes
        current.removeAll { $0 == id }
        if enabled { current.append(id) }
        if current.isEmpty {
            draft.customInfoPlistEntries.removeValue(forKey: "UIBackgroundModes")
        } else {
            draft.customInfoPlistEntries["UIBackgroundModes"] = .array(current.map(PlistCustomValue.string))
        }
    }

    private func commitNewEntry() {
        let key = newKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        switch newKind {
        case .string:
            draft.customInfoPlistEntries[key] = .string(newStringValue)
        case .boolean:
            draft.customInfoPlistEntries[key] = .boolean(newBoolValue)
        case .integer:
            draft.customInfoPlistEntries[key] = .integer(Int(newIntValue) ?? 0)
        case .real:
            draft.customInfoPlistEntries[key] = .real(Double(newRealValue) ?? 0.0)
        case .array, .dictionary:
            break
        }
        newKey = ""
        newStringValue = ""
    }

    private func validateRawXML() {
        do {
            let parsed = try PlistDocumentCodec.parseXML(draft.rawInfoPlistXMLOverride)
            xmlValidationMessage = "Valid XML dictionary (\(parsed.count) top-level key(s))."
        } catch let error as PlistDocumentCodec.CodecError {
            xmlValidationMessage = error.message
        } catch {
            xmlValidationMessage = error.localizedDescription
        }
    }
}

/// Pre-signing Visual & Raw XML Entitlements Overrides Editor.
struct SigningEntitlementsOverridesSheet: View {
    @Binding var draft: SideloadOptionsDraft
    @Environment(\.dismiss) private var dismiss

    @State private var mode: SigningInfoPlistOverridesSheet.EditorMode = .visual
    @State private var newKey = ""
    @State private var isBoolValue = true
    @State private var boolFlag = true
    @State private var stringValue = ""
    @State private var removedKey = ""
    @State private var validationStatus: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Mode", selection: $mode) {
                        ForEach(SigningInfoPlistOverridesSheet.EditorMode.allCases, id: \.self) { item in
                            Text(item.rawValue).tag(item)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                if mode == .visual {
                    Section("Merge & Isolation") {
                        Toggle("Merge Original Binary Entitlements", isOn: $draft.mergesBinaryEntitlements)
                        Toggle("Isolate Keychain Group (<TeamID>.<BundleID>)", isOn: $draft.isolatesKeychainGroup)
                    }
                    Section("Add Entitlement Key Override") {
                        TextField("Key (e.g. get-task-allow)", text: $newKey)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                        Toggle("Boolean Entitlement", isOn: $isBoolValue)
                        if isBoolValue {
                            Toggle("Value", isOn: $boolFlag)
                        } else {
                            TextField("String value", text: $stringValue)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                        }
                        Button {
                            let key = newKey.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !key.isEmpty else { return }
                            draft.entitlementOverrides[key] = isBoolValue ? .boolean(boolFlag) : .string(stringValue)
                            newKey = ""
                            stringValue = ""
                        } label: {
                            Label("Add Entitlement Override", systemImage: "plus.circle.fill")
                                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        }
                        .disabled(newKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    Section("Configured Entitlement Overrides (\(draft.entitlementOverrides.count))") {
                        ForEach(draft.entitlementOverrides.keys.sorted(), id: \.self) { key in
                            HStack {
                                Text(key).font(ZTypography.codeCaption)
                                Spacer()
                                Button(role: .destructive) {
                                    draft.entitlementOverrides.removeValue(forKey: key)
                                } label: {
                                    Image(systemName: "trash").frame(width: 44, height: 44)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    Section("Strip Entitlement Keys (\(draft.removedEntitlementKeys.count))") {
                        HStack(spacing: ZSpacing.sm) {
                            TextField("Key (e.g. com.apple.developer.associated-domains)", text: $removedKey)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                            Button("Strip") {
                                let k = removedKey.trimmingCharacters(in: .whitespacesAndNewlines)
                                if !k.isEmpty, !draft.removedEntitlementKeys.contains(k) {
                                    draft.removedEntitlementKeys.append(k)
                                    removedKey = ""
                                }
                            }
                            .frame(minHeight: 44)
                        }
                        ForEach(draft.removedEntitlementKeys, id: \.self) { key in
                            HStack {
                                Text(key).font(ZTypography.codeCaption)
                                Spacer()
                                Button(role: .destructive) {
                                    draft.removedEntitlementKeys.removeAll { $0 == key }
                                } label: {
                                    Image(systemName: "minus.circle.fill").frame(width: 44, height: 44)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                } else {
                    Section {
                        TextEditor(text: $draft.rawEntitlementsXMLOverride)
                            .font(ZTypography.codeCaption)
                            .frame(minHeight: 240)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                        Button {
                            do {
                                let dict = try PlistDocumentCodec.parseXML(draft.rawEntitlementsXMLOverride)
                                validationStatus = "Valid XML entitlements dictionary (\(dict.count) key(s))."
                            } catch {
                                validationStatus = error.localizedDescription
                            }
                        } label: {
                            Label("Validate Entitlements XML", systemImage: "checkmark.seal")
                                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        }
                        if let validationStatus {
                            Text(validationStatus).font(ZTypography.caption).foregroundStyle(.secondary)
                        }
                    } header: {
                        Text("Raw Entitlements XML Override")
                    } footer: {
                        Text("Warning: embedding an entitlement key not authorized by your provisioning profile causes iOS installd to refuse installation on stock devices.")
                    }
                }
            }
            .navigationTitle("Entitlements Editor")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
