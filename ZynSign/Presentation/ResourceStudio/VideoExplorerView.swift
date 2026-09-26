import SwiftUI
#if canImport(AVKit)
import AVKit
#endif

/// Video Explorer: inspects video assets, displaying duration, resolution, size, and on-demand playback.
public struct VideoExplorerView: View {

    @ObservedObject public var model: ResourceStudioModel
    @State private var playingVideoURL: URL?
    @State private var isStaging = false

    private var videos: [VideoAsset] {
        if model.searchText.trimmingCharacters(in: .whitespaces).isEmpty {
            return model.catalog.videos
        }
        let q = model.searchText.lowercased()
        return model.catalog.videos.filter {
            $0.fileName.lowercased().contains(q) ||
            $0.format.lowercased().contains(q) ||
            $0.bundlePath.rawValue.lowercased().contains(q)
        }
    }

    public init(model: ResourceStudioModel) {
        self.model = model
    }

    public var body: some View {
        VStack(spacing: 0) {
            if videos.isEmpty {
                ContentUnavailableView {
                    Label("No Video Files", systemImage: "film")
                } description: {
                    Text(model.searchText.isEmpty ? "This application does not bundle video assets." : "No videos match '\(model.searchText)'.")
                }
                .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: ZSpacing.md) {
                        ForEach(videos) { video in
                            videoCard(video)
                        }
                    }
                    .padding(ZSpacing.md)
                }
            }
        }
        .sheet(item: Binding(
            get: { playingVideoURL.map { IdentifiableURL(url: $0) } },
            set: { playingVideoURL = $0?.url }
        )) { item in
            VideoPlaybackSheet(url: item.url)
        }
    }

    private func videoCard(_ video: VideoAsset) -> some View {
        ZCard(variant: .filled) {
            VStack(alignment: .leading, spacing: ZSpacing.sm) {
                // Thumbnail / Video Container
                ZStack {
                    RoundedRectangle(cornerRadius: ZRadius.card, style: .continuous)
                        .fill(Color(.tertiarySystemFill))
                        .frame(height: 140)

                    VStack(spacing: ZSpacing.xs) {
                        Image(systemName: "film")
                            .font(.system(size: 36))
                            .foregroundStyle(Color.accentColor)

                        Button {
                            playVideo(video)
                        } label: {
                            Label("Play Video", systemImage: "play.fill")
                                .font(.subheadline.weight(.semibold))
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(video.fileName)
                        .font(.headline)
                        .lineLimit(1)

                    HStack {
                        Text(video.resolutionDescription)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("·")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                        Text(video.durationFormatted)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Text("·")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                        Text(video.format.uppercased())
                            .font(.caption.weight(.bold))
                            .foregroundStyle(Color.accentColor)
                        Spacer()
                        Text(ByteCountFormatter.string(fromByteCount: Int64(video.fileSize), countStyle: .file))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Divider()

                HStack {
                    Text(video.bundlePath.rawValue)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                    Spacer()
                    Button {
                        model.selectedResource = video
                    } label: {
                        Label("Details", systemImage: "info.circle")
                            .font(.caption2)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                }
            }
        }
    }

    private func playVideo(_ video: VideoAsset) {
        ZHaptics.tap()
        Task {
            do {
                let url = try await model.mediaLoader.stageVideo(
                    for: video.bundlePath,
                    recordID: model.entry.record.id
                )
                self.playingVideoURL = url
            } catch {}
        }
    }
}

private struct IdentifiableURL: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

/// Plays staged video via native VideoPlayer on supported platforms.
private struct VideoPlaybackSheet: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack {
                #if canImport(AVKit)
                VideoPlayer(player: AVPlayer(url: url))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                #else
                Text("Video playback not supported in this environment.")
                #endif
            }
            .navigationTitle("Video Player")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
