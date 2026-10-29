import Foundation

/// Port controlling optional silent-audio background keep-alive while active
/// package downloads are running.
protocol BackgroundDownloadKeepAliveControlling: AnyObject, Sendable {
    @MainActor func setActiveTransferCount(_ count: Int, enabled: Bool)
}
