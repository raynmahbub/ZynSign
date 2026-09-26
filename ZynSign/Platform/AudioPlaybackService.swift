import Foundation
import Combine
#if canImport(AVFoundation)
import AVFoundation
#endif

/// Presentation-facing service providing audio playback controls for bundled audio assets.
@MainActor
public final class AudioPlaybackService: NSObject, ObservableObject {

    @Published public private(set) var isPlaying: Bool = false
    @Published public private(set) var currentAssetID: String?
    @Published public private(set) var currentTime: TimeInterval = 0
    @Published public private(set) var duration: TimeInterval = 0
    @Published public private(set) var playbackError: String?

    #if canImport(AVFoundation)
    private var player: AVAudioPlayer?
    private var timer: Timer?
    #endif

    public override init() {
        super.init()
    }

    /// Starts or resumes audio playback for the given data and asset ID.
    public func play(data: Data, assetID: String) {
        #if canImport(AVFoundation)
        if currentAssetID == assetID, let player = player {
            player.play()
            isPlaying = true
            startTimer()
            return
        }

        stop()
        playbackError = nil

        do {
            #if os(iOS)
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try? AVAudioSession.sharedInstance().setActive(true)
            #endif

            let newPlayer = try AVAudioPlayer(data: data)
            newPlayer.delegate = self
            newPlayer.prepareToPlay()
            newPlayer.play()

            self.player = newPlayer
            self.currentAssetID = assetID
            self.duration = newPlayer.duration
            self.currentTime = 0
            self.isPlaying = true
            startTimer()
        } catch {
            playbackError = "Unable to play audio format: \(error.localizedDescription)"
            isPlaying = false
        }
        #else
        currentAssetID = assetID
        isPlaying = true
        duration = 10
        currentTime = 0
        #endif
    }

    /// Pauses audio playback.
    public func pause() {
        #if canImport(AVFoundation)
        player?.pause()
        stopTimer()
        #endif
        isPlaying = false
    }

    /// Toggles play / pause for the current or new track.
    public func togglePlayPause(data: Data, assetID: String) {
        if currentAssetID == assetID && isPlaying {
            pause()
        } else {
            play(data: data, assetID: assetID)
        }
    }

    /// Stops audio playback completely and resets position.
    public func stop() {
        #if canImport(AVFoundation)
        player?.stop()
        player = nil
        stopTimer()
        #endif
        isPlaying = false
        currentAssetID = nil
        currentTime = 0
        duration = 0
    }

    /// Seeks playback to a specific timestamp in seconds.
    public func seek(to time: TimeInterval) {
        #if canImport(AVFoundation)
        player?.currentTime = time
        #endif
        currentTime = time
    }

    #if canImport(AVFoundation)
    private func startTimer() {
        stopTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self = self, let p = self.player else { return }
            Task { @MainActor in
                self.currentTime = p.currentTime
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
    #endif
}

#if canImport(AVFoundation)
extension AudioPlaybackService: AVAudioPlayerDelegate {
    public nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.isPlaying = false
            self.currentTime = 0
            self.stopTimer()
        }
    }
}
#endif
