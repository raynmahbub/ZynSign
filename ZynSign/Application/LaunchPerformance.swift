import Foundation

/// Records where launch time goes, and decides what waits.
///
/// **Essential versus deferred.** The Home screen needs the environment,
/// the preferences, and the persisted queue's *existence* — not its
/// restoration, not a swept drop inbox, not a rebuilt index, not a cache
/// sweep. `StartupWorkPlan` names the work that may run before the first
/// frame and the work that must wait until after it, and the shell follows
/// the plan: deferred work starts one run-loop turn after the first frame
/// is on screen and runs through the background scheduler at deferred
/// priority, so nothing the user is looking at competes with it.
///
/// **Timeline.** Marks are recorded as offsets from process start, using
/// the kernel's process start time when it is available, so the first
/// mark already includes the time spent before `main`. The timeline is
/// kept for the Performance page and recorded as a measurement so a
/// slower launch shows up as a regression like any other.
final class LaunchPerformanceRecorder: @unchecked Sendable {

    private let lock = NSLock()
    private var timeline = LaunchTimeline()
    private let processStart: Date
    private let now: @Sendable () -> Date

    /// Creates a recorder anchored at the process start when it can be
    /// read, and at the recorder's own creation otherwise.
    init(processStart: Date? = nil, now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
        self.processStart = processStart ?? Self.processStartTime() ?? now()
    }

    /// Records `milestone` now. A milestone recorded twice keeps its first
    /// offset.
    func mark(_ milestone: String) {
        let offset = now().timeIntervalSince(processStart)
        lock.withLock {
            timeline.record(milestone, at: offset)
        }
    }

    /// The timeline so far.
    var current: LaunchTimeline {
        lock.withLock { timeline }
    }

    /// The offset of the first frame, when recorded.
    var timeToFirstFrame: TimeInterval? {
        current.offset(of: LaunchTimeline.Milestone.firstFrame)
    }

    /// The process's start time from the kernel, or `nil` where it cannot
    /// be read.
    static func processStartTime() -> Date? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        let result = sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0)
        guard result == 0 else { return nil }
        let start = info.kp_proc.p_starttime
        let seconds = TimeInterval(start.tv_sec) + TimeInterval(start.tv_usec) / 1_000_000
        guard seconds > 0 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }
}

/// What runs before the first frame and what waits until after it.
///
/// The plan is data so a test can assert it and so the shell has one
/// place to consult rather than a growing chain of `Task`s. Adding a new
/// piece of launch work means adding it here and deciding which side of
/// the first frame it belongs on.
struct StartupWorkPlan: Equatable, Sendable {

    /// One piece of launch work.
    enum Item: String, CaseIterable, Hashable, Sendable {

        /// Tidy scratch files, when the policy allows. Runs first because
        /// restoration must see exactly the files the policy kept.
        case temporaryCleanup

        /// Restore imports the last run interrupted.
        case restoreInterruptedImports

        /// Sweep files dropped onto ZynSign while it was not running.
        case sweepDropInbox

        /// Restore the persisted signing queue.
        case restoreSigningQueue

        /// Reconcile the metadata index and the search index.
        case reconcileIndexes

        /// Apply cache policies.
        case enforceCachePolicies

        /// Begin observing memory pressure.
        case startMemoryObservation

        /// Whether the item must run before the first frame. Nothing does:
        /// the Home screen renders from the environment and the
        /// preferences, which are read during composition.
        var isEssential: Bool { false }

        /// Whether the item may run on the background scheduler rather
        /// than the main actor. Restoration touches main-actor state and
        /// runs there; sweeps and sweeps alone go to the scheduler.
        var runsOnScheduler: Bool {
            switch self {
            case .sweepDropInbox, .reconcileIndexes, .enforceCachePolicies:
                return true
            case .temporaryCleanup, .restoreInterruptedImports, .restoreSigningQueue, .startMemoryObservation:
                return false
            }
        }
    }

    /// The items in the order they run.
    let items: [Item]

    /// The delay between the first frame and the first deferred item, so
    /// the initial layout and the tab bar's first animation are not
    /// competing with restoration.
    let deferralDelay: Duration

    init(items: [Item] = Item.allCases, deferralDelay: Duration = .milliseconds(350)) {
        self.items = items
        self.deferralDelay = deferralDelay
    }

    /// The shipped plan.
    static let standard = StartupWorkPlan()

    /// The items that run before the first frame.
    var essential: [Item] { items.filter(\.isEssential) }

    /// The items that wait for the first frame.
    var deferred: [Item] { items.filter { !$0.isEssential } }
}
