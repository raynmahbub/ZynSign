import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// File Inspector: comprehensive, read-only metadata inspector for any bundled resource.
public struct ResourceInspectorSheet: View {

    public let item: any ResourceItem
    public let appName: String
    @Environment(\.dismiss) private var dismiss
    @State private var toastMessage: String?

    public init(item: any ResourceItem, appName: String) {
        self.item = item
        self.appName = appName
    }

    private var fullBundlePath: String {
        "Payload/\(appName).app/\(item.bundlePath.rawValue)"
    }

    private var parentFolder: String {
        if let parent = item.bundlePath.parent, !parent.isRoot {
            return "Payload/\(appName).app/\(parent.rawValue)"
        }
        return "Payload/\(appName).app"
    }

    public var body: some View {
        NavigationStack {
            List {
                overviewSection
                metadataSection
                bundleLocationSection
                actionsSection
                footnoteSection
            }
            .navigationTitle("File Inspector")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .overlay(alignment: .bottom) {
                if let toastMessage {
                    Text(toastMessage)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, ZSpacing.md)
                        .padding(.vertical, ZSpacing.xs)
                        .background(Color.black.opacity(0.85), in: Capsule())
                        .padding(.bottom, ZSpacing.lg)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
    }

    // MARK: - Overview

    private var overviewSection: some View {
        Section("Overview") {
            LabeledContent("Filename") {
                Text(item.fileName)
                    .textSelection(.enabled)
            }
            LabeledContent("Path") {
                Text(item.bundlePath.rawValue)
                    .font(.footnote.monospaced())
                    .multilineTextAlignment(.trailing)
                    .textSelection(.enabled)
            }
            LabeledContent("Size") {
                Text("\(ByteCountFormatter.string(fromByteCount: Int64(item.fileSize), countStyle: .file)) (\(item.fileSize) bytes)")
            }
            LabeledContent("Type") {
                Label(item.category.displayName, systemImage: item.category.systemImage)
            }
        }
    }

    // MARK: - Metadata

    private var metadataSection: some View {
        Section("Metadata") {
            LabeledContent("Format", value: item.format.uppercased())

            if let icon = item as? AppIconAsset {
                if let dims = icon.dimensions {
                    LabeledContent("Dimensions", value: "\(dims.width) × \(dims.height) px")
                }
                if let scale = icon.scale {
                    LabeledContent("Scale", value: "@\(scale)x")
                }
                if let idiom = icon.idiom {
                    LabeledContent("Idiom", value: idiom.capitalized)
                }
                LabeledContent("Role", value: icon.roleDescription)
            } else if let img = item as? ImageAsset {
                if let dims = img.dimensions {
                    LabeledContent("Dimensions", value: "\(dims.width) × \(dims.height) px")
                }
                if let scale = img.scale {
                    LabeledContent("Scale", value: "@\(scale)x")
                }
                if let tag = img.tag {
                    LabeledContent("Tag", value: tag)
                }
            } else if let font = item as? FontAsset {
                LabeledContent("Font Family", value: font.fontFamily)
                LabeledContent("Style", value: font.style)
                LabeledContent("PostScript Name", value: font.fontName)
            } else if let loc = item as? LocalizationFileAsset {
                LabeledContent("Language", value: "\(loc.languageCode.uppercased()) (\(loc.languageCode))")
                LabeledContent("Table Name", value: loc.tableName)
                LabeledContent("String Count", value: "\(loc.keyCount) keys")
            } else if let audio = item as? AudioAsset {
                LabeledContent("Duration", value: audio.durationFormatted)
                if let sampleRate = audio.sampleRate {
                    LabeledContent("Sample Rate", value: "\(Int(sampleRate)) Hz")
                }
                if let channels = audio.channelCount {
                    LabeledContent("Channels", value: channels == 2 ? "Stereo (2)" : (channels == 1 ? "Mono (1)" : "\(channels)"))
                }
            } else if let video = item as? VideoAsset {
                if let res = video.resolution {
                    LabeledContent("Resolution", value: "\(res.width) × \(res.height) px")
                }
                LabeledContent("Duration", value: video.durationFormatted)
            }
        }
    }

    // MARK: - Bundle Location

    private var bundleLocationSection: some View {
        Section("Bundle Location") {
            LabeledContent("Full Bundle Path") {
                Text(fullBundlePath)
                    .font(.caption.monospaced())
                    .multilineTextAlignment(.trailing)
                    .textSelection(.enabled)
            }
            LabeledContent("Parent Folder") {
                Text(parentFolder)
                    .font(.caption.monospaced())
                    .multilineTextAlignment(.trailing)
                    .textSelection(.enabled)
            }
        }
    }

    // MARK: - Actions

    private var actionsSection: some View {
        Section("Actions") {
            Button {
                copyText(item.fileName, label: "Filename copied")
            } label: {
                Label("Copy Filename", systemImage: "doc.on.doc")
            }

            Button {
                copyText(fullBundlePath, label: "Full path copied")
            } label: {
                Label("Copy Bundle Path", systemImage: "folder")
            }
        }
    }

    // MARK: - Footnote

    private var footnoteSection: some View {
        Section {
            Text("Resource Studio is strictly read-only. File inspection does not modify, extract, or sign bundled assets.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func copyText(_ text: String, label: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = text
        #endif
        ZHaptics.tap()
        withAnimation {
            toastMessage = label
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation {
                if toastMessage == label {
                    toastMessage = nil
                }
            }
        }
    }
}
