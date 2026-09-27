import SwiftUI

/// Font Explorer: inspects bundled fonts with live typography preview sentences.
public struct FontExplorerView: View {

    @ObservedObject public var model: ResourceStudioModel
    @State private var previewSize: CGFloat = 18
    @State private var customText: String = "The quick brown fox jumps over the lazy dog."
    @State private var registeredFontNames: [String: String] = [:]

    private var fonts: [FontAsset] {
        if model.searchText.trimmingCharacters(in: .whitespaces).isEmpty {
            return model.catalog.fonts
        }
        let q = model.searchText.lowercased()
        return model.catalog.fonts.filter {
            $0.fileName.lowercased().contains(q) ||
            $0.fontFamily.lowercased().contains(q) ||
            $0.fontName.lowercased().contains(q) ||
            $0.style.lowercased().contains(q)
        }
    }

    public init(model: ResourceStudioModel) {
        self.model = model
    }

    public var body: some View {
        VStack(spacing: 0) {
            controlsBar

            if fonts.isEmpty {
                ContentUnavailableView {
                    Label("No Fonts Found", systemImage: "textformat")
                } description: {
                    Text(model.searchText.isEmpty ? "This application does not bundle custom fonts." : "No fonts match '\(model.searchText)'.")
                }
                .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: ZSpacing.md) {
                        ForEach(fonts) { font in
                            fontCard(font)
                        }
                    }
                    .padding(ZSpacing.md)
                }
            }
        }
    }

    private var controlsBar: some View {
        VStack(spacing: ZSpacing.xs) {
            HStack {
                Text("Size: \(Int(previewSize))pt")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Slider(value: $previewSize, in: 12...36, step: 2)
            }
        }
        .padding(.horizontal, ZSpacing.md)
        .padding(.vertical, ZSpacing.xs)
        .background(Color(.systemGroupedBackground))
    }

    private func fontCard(_ font: FontAsset) -> some View {
        ZCard(variant: .filled) {
            VStack(alignment: .leading, spacing: ZSpacing.sm) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(font.fontFamily)
                            .font(.headline)
                        Text("\(font.style) · \(font.format.uppercased())")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Text(ByteCountFormatter.string(fromByteCount: Int64(font.fileSize), countStyle: .file))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)

                    Button {
                        model.selectedResource = font
                    } label: {
                        Image(systemName: "info.circle")
                            .font(.body)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Font details")
                }

                Divider()

                // Live Typography Preview Sentence
                let resolvedName = registeredFontNames[font.id] ?? font.fontName
                Text(customText)
                    .font(.custom(resolvedName, size: previewSize))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                    .textSelection(.enabled)
                    .task(id: font.id) {
                        if registeredFontNames[font.id] == nil {
                            if let loaded = try? await model.mediaLoader.loadAndRegisterFont(
                                for: font.bundlePath,
                                recordID: model.entry.record.id
                            ) {
                                registeredFontNames[font.id] = loaded
                            }
                        }
                    }

                HStack {
                    Text(font.fileName)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                }
            }
        }
    }
}
