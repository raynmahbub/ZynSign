import Foundation

/// One surface the shell owes the user, named as a value.
///
/// An Open In hand-off, a drop, and a tap on an import action all arrive as a
/// request to show something. The request is held as the surface's name and
/// the document that came with it — never as a stored closure — so it can
/// wait for the screen without keeping a view alive.
enum ShellPresentation: Equatable, Hashable {

    /// The Import Hub, for a package or archive.
    case importHub

    /// Certificates & Profiles with the Profiles segment selected, ready to
    /// import `url` when supplied.
    case profiles(URL?)

    /// Certificates & Profiles with the Certificates segment selected, ready
    /// to import `url` when supplied.
    case certificates(URL?)

    /// The Export Center, optionally opened at one artifact.
    case exports(ExportIdentifier?)

    /// Whether `other` names the same surface, whatever document it carries.
    ///
    /// A second hand-off of the same kind updates the screen that is already
    /// up rather than stacking a second sheet on top of it.
    func isSameSurface(as other: ShellPresentation) -> Bool {
        switch (self, other) {
        case (.importHub, .importHub), (.profiles, .profiles), (.certificates, .certificates):
            return true
        case (.exports, .exports):
            return true
        default:
            return false
        }
    }
}

/// What the shell does with a surface it has been asked to present.
enum ShellPresentationDecision: Equatable {

    /// Raise it now.
    case present

    /// Keep the request and raise it when the screen is free. Holding is never
    /// discarding: the request keeps its place until a dismissal, an
    /// activation, or the next attempt presents it.
    case hold
}

/// The rule for presenting a shell surface.
///
/// Three facts decide it, and only these:
///
/// - the scene must be active, because UIKit drops a presentation requested
///   while another application's controller is still on screen;
/// - a request for the surface that is *already* showing updates it in place,
///   so a second Open In never stacks a duplicate sheet;
/// - any other shell surface being up means the screen is busy, and the
///   request waits for its turn instead of being dropped.
///
/// Kept as a value so the rule is regression-tested without a live window —
/// the presentation code around it needs UIKit, the decision does not.
enum ShellPresentationRouting {

    static func decide(
        sceneIsActive: Bool,
        surfaceIsAlreadyShowing: Bool,
        shellIsOccupied: Bool
    ) -> ShellPresentationDecision {
        guard sceneIsActive else { return .hold }
        if surfaceIsAlreadyShowing { return .present }
        return shellIsOccupied ? .hold : .present
    }
}

/// The surfaces waiting for the screen, oldest first.
///
/// One drag can legitimately carry both a certificate and a provisioning
/// profile, and two hand-offs can arrive while a sheet is still dismissing, so
/// this is a queue rather than a single slot: a single slot silently discarded
/// the second file.
struct ShellPresentationQueue: Equatable {

    private(set) var pending: [ShellPresentation] = []

    var isEmpty: Bool { pending.isEmpty }

    var count: Int { pending.count }

    /// Adds `surface`.
    ///
    /// A retry is inserted at the front so it keeps its place ahead of requests
    /// that arrived while the screen was busy; a fresh request joins the back.
    mutating func enqueue(_ surface: ShellPresentation, atFront: Bool = false) {
        if atFront {
            pending.insert(surface, at: 0)
        } else {
            pending.append(surface)
        }
    }

    /// Takes the oldest request, or `nil` when nothing is waiting.
    mutating func removeFirst() -> ShellPresentation? {
        guard !pending.isEmpty else { return nil }
        return pending.removeFirst()
    }
}
