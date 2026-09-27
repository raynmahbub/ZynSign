import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Summary Card

/// A summary card showing the resource category count.
public struct ResourceSummaryCard: View {
    public let title: String
    public let count: Int
    public let systemImage: String
    public let tint: Color
    public let action: () -> Void

    public init(
        title: String,
        count: Int,
        systemImage: String,
        tint: Color,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.count = count
        self.systemImage = systemImage
        self.tint = tint
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            ZCard(variant: .filled) {
                VStack(alignment: .leading, spacing: ZSpacing.xs) {
                    HStack {
                        Image(systemName: systemImage)
                            .font(.title2)
                            .foregroundStyle(tint)
                        Spacer()
                        Text("\(count)")
                            .font(.title3.weight(.bold))
                            .foregroundStyle(.primary)
                    }
                    Text(title)
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(count) resources")
        .accessibilityHint("Opens \(title) in the Resource Studio")
    }
}

// MARK: - Filter Pills

/// Horizontal scrollable bar of resource filter chips.
public struct ResourceFilterPills: View {
    @Binding public var selectedFilter: ResourceFilter

    public init(selectedFilter: Binding<ResourceFilter>) {
        self._selectedFilter = selectedFilter
    }

    public var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: ZSpacing.xs) {
                ForEach(ResourceFilter.allCases) { filter in
                    Button {
                        ZHaptics.tap()
                        selectedFilter = filter
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: filter.systemImage)
                                .font(.caption2)
                            Text(filter.rawValue)
                                .font(.subheadline.weight(selectedFilter == filter ? .semibold : .regular))
                        }
                        .padding(.horizontal, ZSpacing.sm)
                        .padding(.vertical, 6)
                        .background(
                            selectedFilter == filter
                                ? Color.accentColor
                                : Color(.secondarySystemBackground),
                            in: Capsule()
                        )
                        .foregroundStyle(selectedFilter == filter ? Color.white : Color.primary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Filter by \(filter.rawValue)")
                }
            }
            .padding(.horizontal, ZSpacing.md)
            .padding(.vertical, 4)
        }
    }
}

// MARK: - Lazy Image Thumbnail

/// Displays a lazily-loaded image thumbnail from bundle data.
public struct LazyImageThumbnail: View {
    public let bundlePath: BundlePath
    public let recordID: ApplicationRecordIdentifier
    public let mediaLoader: ResourceMediaLoader
    public let cornerRadius: CGFloat
    public let contentMode: ContentMode

    @State private var uiImage: UIImage?
    @State private var isLoading = false
    @State private var loadFailed = false

    public init(
        bundlePath: BundlePath,
        recordID: ApplicationRecordIdentifier,
        mediaLoader: ResourceMediaLoader,
        cornerRadius: CGFloat = ZRadius.sm,
        contentMode: ContentMode = .fit
    ) {
        self.bundlePath = bundlePath
        self.recordID = recordID
        self.mediaLoader = mediaLoader
        self.cornerRadius = cornerRadius
        self.contentMode = contentMode
    }

    public var body: some View {
        ZStack {
            Color(.tertiarySystemFill)

            if let uiImage {
                Image(uiImage: uiImage)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else if isLoading {
                ProgressView()
                    .scaleEffect(0.7)
            } else if loadFailed {
                Image(systemName: "photo")
                    .foregroundStyle(.secondary)
            } else {
                Color.clear
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .task(id: bundlePath) {
            await loadImage()
        }
    }

    private func loadImage() async {
        guard uiImage == nil, !isLoading else { return }
        isLoading = true
        loadFailed = false
        do {
            let data = try await mediaLoader.loadData(for: bundlePath, recordID: recordID)
            if let img = UIImage(data: data) {
                self.uiImage = img
            } else {
                self.loadFailed = true
            }
        } catch {
            self.loadFailed = true
        }
        isLoading = false
    }
}

// MARK: - Zoomable Image View

/// Interactive pinch-to-zoom full-screen preview.
public struct ZoomableImageView: View {
    public let bundlePath: BundlePath
    public let recordID: ApplicationRecordIdentifier
    public let mediaLoader: ResourceMediaLoader

    @State private var scale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0
    @State private var uiImage: UIImage?
    @State private var isLoading = true

    public init(
        bundlePath: BundlePath,
        recordID: ApplicationRecordIdentifier,
        mediaLoader: ResourceMediaLoader
    ) {
        self.bundlePath = bundlePath
        self.recordID = recordID
        self.mediaLoader = mediaLoader
    }

    public var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.ignoresSafeArea()

                if let uiImage {
                    Image(uiImage: uiImage)
                        .resizable()
                        .scaledToFit()
                        .scaleEffect(scale)
                        .gesture(
                            MagnificationGesture()
                                .onChanged { value in
                                    let delta = value / lastScale
                                    lastScale = value
                                    scale = min(max(scale * delta, 1.0), 5.0)
                                }
                                .onEnded { _ in
                                    lastScale = 1.0
                                }
                        )
                        .onTapGesture(count: 2) {
                            withAnimation(ZMotion.interactive) {
                                scale = scale > 1.5 ? 1.0 : 2.5
                            }
                        }
                } else if isLoading {
                    ProgressView()
                        .tint(.white)
                } else {
                    Text("Image preview unavailable")
                        .foregroundStyle(.white)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .task {
            do {
                let data = try await mediaLoader.loadData(
                    for: bundlePath,
                    recordID: recordID,
                    maxBytes: ResourceStudioLimits.maximumImagePreviewBytes
                )
                self.uiImage = UIImage(data: data)
            } catch {}
            self.isLoading = false
        }
    }
}

// MARK: - Audio Playback Row

/// Reusable audio playback row with interactive play/pause and progress.
public struct AudioPlaybackRow: View {
    public let audio: AudioAsset
    public let recordID: ApplicationRecordIdentifier
    public let mediaLoader: ResourceMediaLoader
    @ObservedObject public var audioService: AudioPlaybackService

    @State private var audioData: Data?
    @State private var isPreparing = false

    public init(
        audio: AudioAsset,
        recordID: ApplicationRecordIdentifier,
        mediaLoader: ResourceMediaLoader,
        audioService: AudioPlaybackService
    ) {
        self.audio = audio
        self.recordID = recordID
        self.mediaLoader = mediaLoader
        self.audioService = audioService
    }

    private var isCurrentlyPlaying: Bool {
        audioService.currentAssetID == audio.id && audioService.isPlaying
    }

    private var progressFraction: Double {
        guard audioService.currentAssetID == audio.id, audioService.duration > 0 else { return 0 }
        return audioService.currentTime / audioService.duration
    }

    public var body: some View {
        HStack(spacing: ZSpacing.sm) {
            Button {
                togglePlayback()
            } label: {
                Image(systemName: isCurrentlyPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)
            .disabled(isPreparing)
            .accessibilityLabel(isCurrentlyPlaying ? "Pause audio" : "Play audio")

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(audio.fileName)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Spacer()
                    Text(audio.format.uppercased())
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color(.tertiarySystemFill), in: Capsule())
                }

                if audioService.currentAssetID == audio.id {
                    ProgressView(value: progressFraction)
                        .tint(Color.accentColor)
                }

                HStack {
                    Text(ByteCountFormatter.string(fromByteCount: Int64(audio.fileSize), countStyle: .file))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if audioService.currentAssetID == audio.id {
                        let curSec = Int(audioService.currentTime)
                        let totSec = Int(audioService.duration)
                        Text(String(format: "%02d:%02d / %02d:%02d", curSec / 60, curSec % 60, totSec / 60, totSec % 60))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    } else {
                        Text(audio.durationFormatted)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func togglePlayback() {
        ZHaptics.tap()
        if let data = audioData {
            audioService.togglePlayPause(data: data, assetID: audio.id)
        } else {
            isPreparing = true
            Task {
                do {
                    let d = try await mediaLoader.loadData(
                        for: audio.bundlePath,
                        recordID: recordID,
                        maxBytes: ResourceStudioLimits.maximumAudioPlaybackBytes
                    )
                    self.audioData = d
                    self.audioService.play(data: d, assetID: audio.id)
                } catch {}
                self.isPreparing = false
            }
        }
    }
}
