import Foundation

/// The inventory of every construct in ZynSign's own sources that could turn
/// a recoverable condition into a crash.
///
/// Crash hardening is an inventory, not a document. Every `try!`, `as!`,
/// force unwrap, `fatalError`, `preconditionFailure`, `precondition`,
/// `assertionFailure` and `unowned` in the application's sources is either
/// absent or named here with the reason it is acceptable. CI refuses a build
/// in which the code and this list disagree
/// (`Scripts/audit_crash_surface.py`), so the list cannot quietly stop being
/// true, and the Compatibility Lab shows it as the static half of the crash
/// status category.
///
/// The rule for adding an entry is stricter than the rule for keeping one:
/// a new construct is a decision a reviewer has to defend in the rationale,
/// and the preferred answer is always to convert the crash into a typed
/// error the caller can recover from.
enum CrashSurfaceBaseline {

    /// One justified construct, in one file.
    struct Expectation: Hashable, Sendable {

        /// The file, relative to the repository root.
        let file: String

        /// The construct: `try!`, `as!`, `forceUnwrap`, `fatalError`,
        /// `preconditionFailure`, `precondition`, `assertionFailure`,
        /// `unowned`.
        let construct: String

        /// How many the file holds.
        let count: Int

        /// Why this one is acceptable. Written for a reviewer who did not
        /// see it being added.
        let rationale: String

        init(file: String, construct: String, count: Int, rationale: String) {
            self.file = file
            self.construct = construct
            self.count = count
            self.rationale = rationale
        }
    }

    /// Every justified construct in the application's sources today.
    ///
    /// The list is empty when there is nothing to justify. It is the state
    /// ZynSign aims to keep: every construct here is a decision, and every
    /// decision is one a release reviewer can read.
    static let expectations: [Expectation] = [
        Expectation(
            file: "ZynSign/Presentation/ApplicationDetailView.swift",
            construct: "preconditionFailure",
            count: 2,
            rationale: "Preview-fixture helpers: a fixture literal that ZynSign's own identifier or digest rules refuse is a defect in the fixture, discovered the moment the preview loads, never reachable from the application's own code paths."
        ),
        Expectation(
            file: "ZynSign/Presentation/ApplicationLibraryView.swift",
            construct: "preconditionFailure",
            count: 2,
            rationale: "Preview-fixture helpers: the same two literals as the detail view's fixtures, and the same reasoning — a trap here fires in Xcode's canvas, never on a device."
        ),
        Expectation(
            file: "ZynSign/Presentation/BundleExplorerView.swift",
            construct: "preconditionFailure",
            count: 1,
            rationale: "Preview-fixture helper building a synthetic bundle path from a literal: preview-only, unreachable from the running application."
        ),
        Expectation(
            file: "ZynSign/Platform/ApplePKCS12Importer.swift",
            construct: "as!",
            count: 1,
            rationale: "SecIdentity bridging right after PKCS#12 import: the dictionary entry's dynamic type is proven first with CFGetTypeID == SecIdentityGetTypeID(), and Swift 6.2 rejects a conditional downcast to a Core Foundation type as always succeeding, so the forced form is the only one the compiler accepts. With the type check proven, a wrong-type trap is unreachable; Security.framework's own samples bridge identities the same way."
        ),
        Expectation(
            file: "ZynSign/Platform/ApplePKCS12Importer.swift",
            construct: "forceUnwrap",
            count: 1,
            rationale: "The `!` inside the single baselined `as!` on the line above: same proven SecIdentity bridge, same compiler constraint, no separate construct."
        ),
        Expectation(
            file: "ZynSign/Platform/AppleSigningKeyResolver.swift",
            construct: "as!",
            count: 1,
            rationale: "SecKey bridging inside loadKey: the guard directly above has already required CFGetTypeID(value) == SecKeyGetTypeID() plus the private-key class and accessibility attributes, and Swift 6.2 rejects a conditional downcast to a Core Foundation type as always succeeding, so the forced form is the only one the compiler accepts. A value that is not a key cannot reach this line."
        ),
        Expectation(
            file: "ZynSign/Platform/AppleSigningKeyResolver.swift",
            construct: "forceUnwrap",
            count: 1,
            rationale: "The `!` inside the single baselined `as!` on the line above: same proven SecKey bridge, same compiler constraint, no separate construct."
        )
    ]

    /// How many constructs the inventory accounts for.
    static var totalCount: Int {
        expectations.reduce(0) { $0 + $1.count }
    }

    /// Whether the inventory accounts for nothing at all — the state ZynSign
    /// prefers, and the state a release reviewer should see.
    static var isEmpty: Bool { expectations.isEmpty }
}
