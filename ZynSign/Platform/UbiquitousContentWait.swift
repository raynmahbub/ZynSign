import Foundation

/// Getting an iCloud document's bytes before anything reads them.
///
/// A file the user picks in Files can be a *placeholder*: its name, its size,
/// and its directory entry are on the device while its content is not. Every
/// question asked of such a file answers "no bytes" — a zero length, a leading
/// block of nothing — so reading it directly refuses a perfectly good package
/// or identity as "empty" or "not an archive". The provider supplies the
/// content when it is asked for, asynchronously, so the honest order is: ask,
/// wait a bounded time, then read.
///
/// Two rules keep that wait from becoming a worse problem than the one it
/// solves.
///
/// - **It is bounded.** A provider that never answers produces the honest
///   "could not be read" refusal — and a retry — rather than a hung import.
/// - **It never sleeps on the main thread.** A caller that gives its time
///   slice to a provider it cannot hurry is a frozen interface, and on the
///   main thread the watchdog is measuring. A main-thread caller still gets
///   the *trigger*, because starting the download is worth doing whatever the
///   caller then reads; it simply does not wait. Callers on the import and
///   read paths run off the main actor precisely so that the wait is
///   available to them.
///
/// The outcome is an observation, never a verdict: `false` says the content
/// was not there within the budget, not that the file is broken.
enum UbiquitousContentWait {

    /// How long a read will wait for the provider to deliver content.
    static let budget: TimeInterval = 20

    /// How often the wait re-asks.
    static let pollInterval: TimeInterval = 0.25

    /// Whether `url` is an iCloud item whose content is not on the device.
    ///
    /// A placeholder that is *reachable* but dataless answers "no bytes" to
    /// every read, exactly like one that is unreachable; both need the
    /// provider's download first. An item this platform does not describe is
    /// not an item awaiting content — unknown is not "missing".
    static func isAwaitingContent(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [
            .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey,
        ]), values.isUbiquitousItem == true else {
            return false
        }
        return values.ubiquitousItemDownloadingStatus != .current
    }

    /// Asks the provider for the document's content and waits, bounded, for it.
    ///
    /// The trigger is idempotent: an item already downloading simply needs the
    /// download to finish, and an item that needs nothing returns immediately.
    ///
    /// - Parameters:
    ///   - url: the document to materialise. Read only, like every other step
    ///     before ZynSign has its own copy.
    ///   - isCancelled: checked between polls so work the user abandoned stops
    ///     waiting at once.
    /// - Returns: whether the content is present now — `true` when the item
    ///   never needed fetching, when it arrived, or when this is not an iCloud
    ///   item at all.
    @discardableResult
    static func materialize(_ url: URL, isCancelled: @escaping () -> Bool = { false }) -> Bool {
        guard isAwaitingContent(url) else { return true }
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        guard !Thread.isMainThread else { return false }
        let deadline = Date().addingTimeInterval(budget)
        while Date() < deadline {
            if isCancelled() { return false }
            Thread.sleep(forTimeInterval: pollInterval)
            if !isAwaitingContent(url) { return true }
        }
        return !isAwaitingContent(url)
    }
}
