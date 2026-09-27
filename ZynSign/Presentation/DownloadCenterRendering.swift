import Foundation

/// Presentation copy for the Download Center.
///
/// Kept free of views so VoiceOver strings and storage labels can be tested
/// without constructing a screen. Nothing here invents a percentage the
/// transfer did not establish.
enum DownloadCenterRendering {

    static func cardLabel(for job: DownloadCenter.Job) -> String {
        var parts = [job.request.displayName, job.sourceText, job.statusText]
        if let version = job.request.version { parts.insert(version, at: 1) }
        return parts.joined(separator: ", ")
    }

    static func progressValue(for job: DownloadCenter.Job) -> String {
        var parts: [String] = []
        if let fraction = job.progress.fraction {
            parts.append("\(Int((fraction * 100).rounded())) percent")
        } else if job.isTransferring {
            parts.append("size not yet known")
        }
        if let speed = job.progress.bytesPerSecond, speed > 1 {
            parts.append("\(bytes(Int64(speed))) per second")
        }
        if let remaining = job.progress.remainingBytes {
            parts.append("\(bytes(remaining)) remaining")
        }
        if let eta = job.progress.estimatedRemainingSeconds {
            parts.append(etaText(eta))
        }
        return parts.isEmpty ? job.statusText : parts.joined(separator: ", ")
    }

    /// A spoken update when progress crosses a quarter, or the stage changes.
    /// Returns nil when nothing new should be announced.
    static func milestoneAnnouncement(previous: String?, current job: DownloadCenter.Job) -> String? {
        let token = milestoneToken(for: job)
        guard token != previous else { return nil }
        return "\(job.request.displayName), \(progressValue(for: job))"
    }

    static func milestoneToken(for job: DownloadCenter.Job) -> String {
        let quarter: String
        if let fraction = job.progress.fraction {
            quarter = String(Int(fraction * 4))
        } else {
            quarter = "unknown"
        }
        return "\(job.id.rawValue)|\(job.statusText)|\(quarter)"
    }

    static func announcement(for notice: DownloadNotice) -> String {
        "\(notice.title). \(notice.message)"
    }

    static func bytes(_ count: Int64?) -> String {
        guard let count else { return "—" }
        return ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }

    static func speed(_ bytesPerSecond: Double?) -> String {
        guard let bytesPerSecond, bytesPerSecond.isFinite, bytesPerSecond > 1 else { return "—" }
        return bytes(Int64(bytesPerSecond)) + "/s"
    }

    static func etaText(_ seconds: TimeInterval?) -> String {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return "—" }
        if seconds < 5 { return "A few seconds" }
        if seconds < 60 { return "Less than a minute" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes) min" }
        return "\(minutes / 60) hr \(minutes % 60) min"
    }

    static func remainingText(for job: DownloadCenter.Job) -> String {
        guard let remaining = job.progress.remainingBytes else { return "—" }
        return bytes(remaining)
    }
}

/// How the shell opens Library or the signing queue from Downloads.
struct DownloadNavigation {
    var openLibrary: () -> Void
    var openSigningQueue: () -> Void

    static let inactive = DownloadNavigation(openLibrary: {}, openSigningQueue: {})
}
