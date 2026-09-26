import SwiftUI

/// Localization Studio: inspects `.lproj` folders, string files, keys, and language comparisons.
public struct LocalizationStudioView: View {

    @ObservedObject public var model: ResourceStudioModel
    @State private var selectedLanguage: String?
    @State private var isComparing = false
    @State private var keySearchText: String = ""

    private var languages: [LocalizationLanguageGroup] {
        model.catalog.localizations
    }

    private var activeLanguageGroup: LocalizationLanguageGroup? {
        if let selected = selectedLanguage {
            return languages.first { $0.languageCode == selected }
        }
        return languages.first
    }

    public init(model: ResourceStudioModel) {
        self.model = model
    }

    public var body: some View {
        VStack(spacing: 0) {
            topToolBar

            if languages.isEmpty {
                ContentUnavailableView {
                    Label("No Localization Folders", systemImage: "globe")
                } description: {
                    Text("This application does not contain `.lproj` localization bundles.")
                }
                .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: ZSpacing.md) {
                        languagePickerBar

                        if let group = activeLanguageGroup {
                            languageDetailsView(group)
                        }
                    }
                    .padding(ZSpacing.md)
                }
            }
        }
        .sheet(isPresented: $isComparing) {
            LanguageComparisonSheet(model: model)
        }
    }

    // MARK: - Toolbar

    private var topToolBar: some View {
        HStack {
            Text("\(languages.count) languages detected")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                ZHaptics.tap()
                isComparing = true
            } label: {
                Label("Compare Languages", systemImage: "arrow.left.arrow.right")
                    .font(.footnote.weight(.semibold))
            }
            .buttonStyle(.bordered)
            .disabled(languages.count < 2)
        }
        .padding(.horizontal, ZSpacing.md)
        .padding(.vertical, ZSpacing.xs)
        .background(Color(.systemGroupedBackground))
    }

    // MARK: - Language Selector

    private var languagePickerBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: ZSpacing.xs) {
                ForEach(languages) { group in
                    let isSelected = (activeLanguageGroup?.languageCode == group.languageCode)
                    Button {
                        ZHaptics.tap()
                        selectedLanguage = group.languageCode
                        model.selectedStringsFile = group.files.first
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(group.displayName)
                                .font(.subheadline.weight(isSelected ? .semibold : .regular))
                            Text("\(group.totalKeyCount) keys · \(group.languageCode.uppercased())")
                                .font(.caption2)
                                .foregroundStyle(isSelected ? Color.white.opacity(0.8) : Color.secondary)
                        }
                        .padding(.horizontal, ZSpacing.sm)
                        .padding(.vertical, 8)
                        .background(
                            isSelected ? Color.accentColor : Color(.secondarySystemBackground),
                            in: RoundedRectangle(cornerRadius: ZRadius.sm, style: .continuous)
                        )
                        .foregroundStyle(isSelected ? Color.white : Color.primary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Language Details & String Files

    private func languageDetailsView(_ group: LocalizationLanguageGroup) -> some View {
        VStack(alignment: .leading, spacing: ZSpacing.md) {
            Text("String Tables in \(group.displayName)")
                .font(.headline)

            ForEach(group.files) { file in
                stringTableCard(file)
            }
        }
    }

    private func stringTableCard(_ file: LocalizationFileAsset) -> some View {
        ZCard(variant: .filled) {
            VStack(alignment: .leading, spacing: ZSpacing.sm) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(file.fileName)
                            .font(.subheadline.weight(.semibold))
                        Text("\(file.keyCount) keys · \(ByteCountFormatter.string(fromByteCount: Int64(file.fileSize), countStyle: .file))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        model.selectedResource = file
                    } label: {
                        Image(systemName: "info.circle")
                            .font(.body)
                    }
                    .buttonStyle(.plain)
                }

                if !file.entries.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(file.entries.prefix(6)) { entry in
                            HStack(alignment: .top, spacing: ZSpacing.xs) {
                                Text(entry.key)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .frame(width: 120, alignment: .leading)
                                Text("=")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                Text(entry.value)
                                    .font(.caption)
                                    .lineLimit(2)
                                Spacer()
                            }
                        }
                        if file.entries.count > 6 {
                            Text("+ \(file.keyCount - 6) more keys in this table")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .padding(.top, 2)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Language Comparison Sheet

/// Side-by-side localization comparison between two languages.
public struct LanguageComparisonSheet: View {
    @ObservedObject public var model: ResourceStudioModel
    @Environment(\.dismiss) private var dismiss

    @State private var baseCode: String = "en"
    @State private var targetCode: String = "fr"
    @State private var selectedTable: String = "Localizable"
    @State private var baseEntries: [LocalizationEntry] = []
    @State private var targetEntries: [LocalizationEntry] = []
    @State private var isLoading = false

    private var availableTables: [String] {
        let tables = model.catalog.localizationFiles.map(\.tableName)
        return Array(Set(tables)).sorted()
    }

    public init(model: ResourceStudioModel) {
        self.model = model
    }

    public var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                selectorBar

                if isLoading {
                    ProgressView("Comparing string tables…")
                        .frame(maxHeight: .infinity)
                } else {
                    comparisonList
                }
            }
            .navigationTitle("Compare Localizations")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                setupDefaults()
                await runComparison()
            }
        }
    }

    private var selectorBar: some View {
        VStack(spacing: ZSpacing.xs) {
            HStack {
                Picker("Base", selection: $baseCode) {
                    ForEach(model.catalog.localizations) { loc in
                        Text(loc.displayName).tag(loc.languageCode)
                    }
                }
                .pickerStyle(.menu)

                Image(systemName: "arrow.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("Target", selection: $targetCode) {
                    ForEach(model.catalog.localizations) { loc in
                        Text(loc.displayName).tag(loc.languageCode)
                    }
                }
                .pickerStyle(.menu)
            }

            if availableTables.count > 1 {
                Picker("Table", selection: $selectedTable) {
                    ForEach(availableTables, id: \.self) { table in
                        Text(table).tag(table)
                    }
                }
                .pickerStyle(.segmented)
            }
        }
        .padding(ZSpacing.sm)
        .background(Color(.secondarySystemBackground))
        .onChange(of: baseCode) { _ in Task { await runComparison() } }
        .onChange(of: targetCode) { _ in Task { await runComparison() } }
        .onChange(of: selectedTable) { _ in Task { await runComparison() } }
    }

    private var comparisonList: some View {
        let targetMap = Dictionary(uniqueKeysWithValues: targetEntries.map { ($0.key, $0.value) })
        let missingKeys = baseEntries.filter { targetMap[$0.key] == nil }
        let translated = baseEntries.filter { targetMap[$0.key] != nil }

        return List {
            Section("Summary") {
                LabeledContent("Base keys (\(baseCode.uppercased()))", value: "\(baseEntries.count)")
                LabeledContent("Target keys (\(targetCode.uppercased()))", value: "\(targetEntries.count)")
                LabeledContent("Missing translations", value: "\(missingKeys.count)")
                    .foregroundStyle(missingKeys.isEmpty ? Color.secondary : Color.orange)
            }

            if !missingKeys.isEmpty {
                Section("Missing in \(targetCode.uppercased()) (\(missingKeys.count))") {
                    ForEach(missingKeys) { entry in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.key)
                                .font(.caption.monospaced())
                                .foregroundStyle(.orange)
                            Text(entry.value)
                                .font(.caption)
                        }
                    }
                }
            }

            Section("Translated Keys (\(translated.count))") {
                ForEach(translated.prefix(50)) { entry in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.key)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                        Text("\(baseCode.uppercased()): \(entry.value)")
                            .font(.caption)
                        Text("\(targetCode.uppercased()): \(targetMap[entry.key] ?? "")")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(Color.accentColor)
                    }
                }
            }
        }
    }

    private func setupDefaults() {
        if let first = model.catalog.localizations.first?.languageCode {
            baseCode = first
        }
        if model.catalog.localizations.count > 1 {
            targetCode = model.catalog.localizations[1].languageCode
        }
        if let table = availableTables.first {
            selectedTable = table
        }
    }

    private func runComparison() async {
        isLoading = true
        defer { isLoading = false }

        let baseFile = model.catalog.localizationFiles.first {
            $0.languageCode == baseCode && $0.tableName == selectedTable
        }
        let targetFile = model.catalog.localizationFiles.first {
            $0.languageCode == targetCode && $0.tableName == selectedTable
        }

        if let bf = baseFile {
            baseEntries = (try? await model.inspection.readStringsEntries(recordWithID: model.entry.record.id, bundlePath: bf.bundlePath)) ?? bf.entries
        } else {
            baseEntries = []
        }

        if let tf = targetFile {
            targetEntries = (try? await model.inspection.readStringsEntries(recordWithID: model.entry.record.id, bundlePath: tf.bundlePath)) ?? tf.entries
        } else {
            targetEntries = []
        }
    }
}
