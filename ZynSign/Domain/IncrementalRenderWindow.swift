import Foundation

/// How much of a long list is handed to the view hierarchy at once.
///
/// A lazy container builds only the rows on screen, but it still has to
/// *diff* the whole identifier list every time the list changes, and it
/// still lays out enough to size its scroll indicator. With a few thousand
/// rows, each search keystroke — which replaces the whole visible list —
/// therefore costs work proportional to the library rather than to the
/// screen. The window bounds that cost: the view receives a prefix of the
/// results, long enough to fill several screens, and the prefix grows as
/// the user approaches its end. Scrolling feels continuous; a search that
/// matches everything still hands the view a few hundred rows.
///
/// The window is a value the model keeps. It knows nothing about views: the
/// model tells it the full result list and which row just appeared, and it
/// answers with the prefix to render. Accessibility relies on the same
/// mechanism — VoiceOver's scrolling reports row appearances like any
/// other scrolling — and a caller may ask for everything when a technology
/// needs the complete list (`showAll`).
struct IncrementalRenderWindow: Equatable, Sendable {

    /// How many rows are rendered before the user scrolls.
    let initialLimit: Int

    /// How many rows each extension adds.
    let step: Int

    /// How close to the end of the rendered prefix a row must be, in rows,
    /// for its appearance to extend the window.
    let threshold: Int

    /// The number of rows currently rendered, before clamping to the list.
    private(set) var limit: Int

    /// Whether the caller asked for the whole list.
    private(set) var showsAll = false

    init(initialLimit: Int = 120, step: Int = 120, threshold: Int = 24) {
        self.initialLimit = max(1, initialLimit)
        self.step = max(1, step)
        self.threshold = max(0, threshold)
        self.limit = self.initialLimit
    }

    /// The prefix of `all` to render.
    func rendered<T>(of all: [T]) -> [T] {
        if showsAll || all.count <= limit { return all }
        return Array(all.prefix(limit))
    }

    /// How many rows of `total` are hidden behind the window.
    func remainingCount(of total: Int) -> Int {
        if showsAll { return 0 }
        return max(0, total - limit)
    }

    /// Whether the window is hiding any of `total` rows.
    func isTruncating(_ total: Int) -> Bool {
        remainingCount(of: total) > 0
    }

    /// Reacts to the row at `position` (an index into the *rendered* list)
    /// appearing on screen. Returns `true` when the window grew.
    @discardableResult
    mutating func rowDidAppear(at position: Int, total: Int) -> Bool {
        guard !showsAll, total > limit else { return false }
        let renderedCount = min(limit, total)
        guard position >= renderedCount - 1 - threshold else { return false }
        limit = min(total, limit + step)
        return true
    }

    /// Renders every row from now on, until the next reset.
    mutating func showAll() {
        showsAll = true
    }

    /// Returns to the initial window. Called when the list is replaced —
    /// a new search, scope, or order — so a long-scrolled window does not
    /// carry its size into an unrelated list.
    mutating func reset() {
        limit = initialLimit
        showsAll = false
    }
}
