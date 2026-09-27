import Foundation

/// Retired transfer entry point.
///
/// Downloads are owned by `DownloadCenter` and `URLSessionDownloadTransfer`.
/// ZynSign does not advertise universal pause/resume, and it does not advertise
/// downloads that survive the process being killed: there is no background-session
/// relaunch handler, and resume is reported only when a transfer actually
/// captured resume data. These flags exist so that claim cannot be reintroduced
/// quietly.
enum DownloadTransferHonesty {
    /// A background URLSession relaunch handler is not installed.
    static let claimsBackgroundRelaunch = false

    /// Resume is per transfer, and only when resume data was captured.
    static let claimsUniversalResume = false
}
