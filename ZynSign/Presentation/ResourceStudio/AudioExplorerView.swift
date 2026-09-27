import SwiftUI

/// Audio Explorer: lists bundled audio files with format, duration, size, and playback controls.
public struct AudioExplorerView: View {

    @ObservedObject public var model: ResourceStudioModel

    private var audioFiles: [AudioAsset] {
        if model.searchText.trimmingCharacters(in: .whitespaces).isEmpty {
            return model.catalog.audio
        }
        let q = model.searchText.lowercased()
        return model.catalog.audio.filter {
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
            if let error = model.audioService.playbackError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(ZSpacing.xs)
                    .frame(maxWidth: .infinity)
                    .background(Color.red.opacity(0.1))
            }

            if audioFiles.isEmpty {
                ContentUnavailableView {
                    Label("No Audio Files", systemImage: "waveform")
                } description: {
                    Text(model.searchText.isEmpty ? "This application does not bundle audio assets." : "No audio matches '\(model.searchText)'.")
                }
                .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: ZSpacing.sm) {
                        ForEach(audioFiles) { audio in
                            ZCard(variant: .filled) {
                                VStack(spacing: 6) {
                                    AudioPlaybackRow(
                                        audio: audio,
                                        recordID: model.entry.record.id,
                                        mediaLoader: model.mediaLoader,
                                        audioService: model.audioService
                                    )

                                    HStack {
                                        Text(audio.bundlePath.rawValue)
                                            .font(.caption2)
                                            .foregroundStyle(.tertiary)
                                            .lineLimit(1)
                                        Spacer()
                                        Button {
                                            model.selectedResource = audio
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
                    }
                    .padding(ZSpacing.md)
                }
            }
        }
    }
}
