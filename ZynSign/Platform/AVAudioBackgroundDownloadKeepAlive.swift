import Foundation
import AVFoundation

/// Plays a zero-amplitude synthesized 1-second PCM WAV loop under `.playback`
/// + `.mixWithOthers` ONLY when the user explicitly enables Background Download
/// Keep-Alive AND active transfers are in flight, stopping immediately on idle.
final class AVAudioBackgroundDownloadKeepAlive: BackgroundDownloadKeepAliveControlling, @unchecked Sendable {

    private var player: AVAudioPlayer?
    private let silentWAVData: Data

    init() {
        self.silentWAVData = Self.makeSilentWAV(sampleRate: 8_000, durationSeconds: 1)
    }

    @MainActor
    func setActiveTransferCount(_ count: Int, enabled: Bool) {
        guard enabled && count > 0 else {
            stop()
            return
        }
        guard player?.isPlaying != true else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
            let audioPlayer = try AVAudioPlayer(data: silentWAVData)
            audioPlayer.numberOfLoops = -1
            audioPlayer.volume = 0.0
            audioPlayer.prepareToPlay()
            audioPlayer.play()
            player = audioPlayer
        } catch {
            stop()
        }
    }

    @MainActor
    private func stop() {
        guard let active = player else { return }
        active.stop()
        player = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    /// Builds a valid 44-byte RIFF/WAVE header + 1s of 8-bit unsigned silence (0x80).
    static func makeSilentWAV(sampleRate: UInt32, durationSeconds: UInt32) -> Data {
        let dataBytes = sampleRate * durationSeconds
        let riffChunkSize = 36 + dataBytes
        var out = Data()
        out.reserveCapacity(Int(44 + dataBytes))
        out.append(contentsOf: "RIFF".utf8)
        appendLE32(&out, riffChunkSize)
        out.append(contentsOf: "WAVEfmt ".utf8)
        appendLE32(&out, 16)
        appendLE16(&out, 1) // PCM
        appendLE16(&out, 1) // Mono
        appendLE32(&out, sampleRate)
        appendLE32(&out, sampleRate)
        appendLE16(&out, 1) // Block align
        appendLE16(&out, 8) // 8-bit PCM
        out.append(contentsOf: "data".utf8)
        appendLE32(&out, dataBytes)
        out.append(Data(repeating: 0x80, count: Int(dataBytes)))
        return out
    }

    private static func appendLE16(_ data: inout Data, _ value: UInt16) {
        var le = value.littleEndian
        withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
    }

    private static func appendLE32(_ data: inout Data, _ value: UInt32) {
        var le = value.littleEndian
        withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
    }
}
