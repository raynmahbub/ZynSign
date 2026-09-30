import Foundation

/// The kind of payload a tweak carries.
///
/// Kinds are inferred from the file name at import time and preserved on the
/// record. They decide where a payload would be placed inside an application
/// bundle and how it is described in the library. Unknown shapes are kept as
/// `other` rather than rejected, so the library never refuses a file it can
/// still store and inspect.
enum TweakKind: String, CaseIterable, Hashable, Sendable, Codable {

    /// A dynamic library loaded into the process by an injection loader.
    case dynamicLibrary

    /// A Debian package archive containing one or more payloads and control
    /// metadata. The library keeps the archive intact; extraction is a
    /// presentation convenience only.
    case debPackage

    /// A framework directory (or a zipped one) carrying its own executable.
    case framework

    /// A resource bundle — images, plists, or other non-executable content.
    case resourceBundle

    /// An app extension payload.
    case appExtension

    /// Anything the library accepts but cannot classify.
    case other

    /// Infers the kind from a file name, using the path extension. Directory
    /// names ending in `.framework`, `.bundle`, or `.appex` classify by their
    /// suffix. A missing or unknown extension is `other`.
    static func infer(fromFileName fileName: String) -> TweakKind {
        let lowered = fileName.lowercased()
        if lowered.hasSuffix(".dylib") { return .dynamicLibrary }
        if lowered.hasSuffix(".deb") { return .debPackage }
        if lowered.hasSuffix(".framework") { return .framework }
        if lowered.hasSuffix(".appex") { return .appExtension }
        if lowered.hasSuffix(".bundle") { return .resourceBundle }
        return .other
    }

    /// A short human-facing description of the kind.
    var displayName: String {
        switch self {
        case .dynamicLibrary: return "Dynamic Library"
        case .debPackage: return "Package (.deb)"
        case .framework: return "Framework"
        case .resourceBundle: return "Resource Bundle"
        case .appExtension: return "App Extension"
        case .other: return "File"
        }
    }

    /// The SF Symbol the library shows for the kind.
    var symbolName: String {
        switch self {
        case .dynamicLibrary: return "puzzlepiece.extension"
        case .debPackage: return "shippingbox"
        case .framework: return "cube.box"
        case .resourceBundle: return "photo.on.rectangle"
        case .appExtension: return "square.grid.2x2"
        case .other: return "doc"
        }
    }
}

/// Where a tweak payload belongs when it is staged for an application bundle.
///
/// The placement policy is deliberately conservative: it only names locations
/// ZynSign's bundle model already understands. A placement is a decision, not
/// an action — staging applies it, and staging is the only writer.
enum TweakPlacement: Equatable, Hashable, Sendable {

    /// Inside the application's `Frameworks` directory.
    case frameworks

    /// Inside the application's `PlugIns` directory.
    case plugins

    /// At the application bundle root.
    case bundleRoot

    /// The payload has no meaningful bundle location; staging refuses it.
    case unsupported

    /// The placement a kind receives.
    static func policy(for kind: TweakKind) -> TweakPlacement {
        switch kind {
        case .dynamicLibrary: return .frameworks
        case .framework: return .frameworks
        case .appExtension: return .plugins
        case .resourceBundle: return .bundleRoot
        case .debPackage: return .unsupported
        case .other: return .unsupported
        }
    }

    /// The bundle-relative directory the placement names, when it names one.
    var relativeDirectory: String? {
        switch self {
        case .frameworks: return "Frameworks"
        case .plugins: return "PlugIns"
        case .bundleRoot: return ""
        case .unsupported: return nil
        }
    }
}

/// One tweak the user has imported into the library.
///
/// A descriptor is metadata: the bytes live in the library's tweak storage
/// directory, addressed by the record's identifier. Nothing here is secret —
/// a tweak is content the user chose to keep, described honestly.
struct TweakDescriptor: Equatable, Hashable, Codable, Sendable, Identifiable {

    /// Stable identity of the record.
    let id: UUID

    /// The display name the user sees. Defaults to the file name without its
    /// extension and can be renamed later.
    var name: String

    /// The original file name the bytes were imported under.
    let fileName: String

    /// The payload kind, inferred at import time.
    let kind: TweakKind

    /// Payload size in bytes.
    let byteSize: Int

    /// SHA-256 of the payload bytes, lowercase hex. Duplicate imports are
    /// detected by this fingerprint.
    let sha256Hex: String

    /// The user's organizational group, when one is set.
    var group: String?

    /// Whether the tweak participates in signing selections by default.
    var enabledByDefault: Bool

    /// When the record was added.
    let addedAt: Date

    /// Updates the record's identity in place — used by rename, regroup, and
    /// toggle operations so the store stays the single writer.
    init(
        id: UUID = UUID(),
        name: String,
        fileName: String,
        kind: TweakKind,
        byteSize: Int,
        sha256Hex: String,
        group: String? = nil,
        enabledByDefault: Bool = true,
        addedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.fileName = fileName
        self.kind = kind
        self.byteSize = byteSize
        self.sha256Hex = sha256Hex
        self.group = group
        self.enabledByDefault = enabledByDefault
        self.addedAt = addedAt
    }

    /// The placement policy says this payload has a bundle location.
    var isStageable: Bool {
        TweakPlacement.policy(for: kind) != .unsupported
    }
}

/// One entry in a tweak staging manifest.
///
/// The manifest is the written record of what a signing session staged, where
/// each payload would live, and the fingerprint that identifies its bytes. It
/// is content for a JSON document; it never references the library's storage
/// paths.
struct TweakManifestEntry: Equatable, Hashable, Codable, Sendable {
    let name: String
    let fileName: String
    let kind: TweakKind
    let sha256Hex: String
    let byteSize: Int
    let targetDirectory: String?

    init(descriptor: TweakDescriptor) {
        let placement = TweakPlacement.policy(for: descriptor.kind)
        name = descriptor.name
        fileName = descriptor.fileName
        kind = descriptor.kind
        sha256Hex = descriptor.sha256Hex
        byteSize = descriptor.byteSize
        targetDirectory = placement.relativeDirectory
    }
}

/// A plan describing which library tweaks a signing session selected.
///
/// The plan is built by `makePlan(selection:from:)` and is validated: a plan
/// that exceeds the entry or byte budgets is refused with a typed reason
/// instead of silently dropping items.
struct TweakInjectionPlan: Equatable, Hashable, Sendable {

    /// The most tweaks one plan may carry.
    static let maximumEntries = 12

    /// The most payload bytes one plan may carry (64 MiB).
    static let maximumTotalBytes = 64 * 1024 * 1024

    /// Why a plan could not be built.
    enum Refusal: Error, Equatable, Hashable, Sendable {
        case empty
        case tooManyEntries(count: Int, limit: Int)
        case tooLarge(totalBytes: Int, limit: Int)

        var message: String {
            switch self {
            case .empty:
                return "No enabled tweaks are selected."
            case .tooManyEntries(let count, let limit):
                return "A staging plan carries at most \(limit) tweaks; \(count) were selected."
            case .tooLarge(let totalBytes, let limit):
                return "A staging plan carries at most \(limit / (1024 * 1024)) MiB of payload; the selection totals \(totalBytes) bytes."
            }
        }
    }

    /// The selected tweaks, in deterministic order (by name, then id).
    let entries: [TweakDescriptor]

    /// The manifest the plan produces.
    var manifestEntries: [TweakManifestEntry] { entries.map(TweakManifestEntry.init) }

    /// The total payload bytes the plan carries.
    var totalBytes: Int { entries.reduce(0) { $0 + $1.byteSize } }

    /// Whether every entry has a bundle location the policy supports.
    var isFullyStageable: Bool { entries.allSatisfy(\.isStageable) }

    /// Entries the placement policy cannot locate inside a bundle.
    var unstageableEntries: [TweakDescriptor] { entries.filter { !$0.isStageable } }

    /// Builds a plan from a selection, or refuses with a typed reason.
    static func makePlan(selection: [TweakDescriptor]) -> Result<TweakInjectionPlan, Refusal> {
        let ordered = selection.sorted {
            ($0.name, $0.id.uuidString) < ($1.name, $1.id.uuidString)
        }
        guard !ordered.isEmpty else { return .failure(.empty) }
        guard ordered.count <= maximumEntries else {
            return .failure(.tooManyEntries(count: ordered.count, limit: maximumEntries))
        }
        let total = ordered.reduce(0) { $0 + $1.byteSize }
        guard total <= maximumTotalBytes else {
            return .failure(.tooLarge(totalBytes: total, limit: maximumTotalBytes))
        }
        return .success(TweakInjectionPlan(entries: ordered))
    }

    private init(entries: [TweakDescriptor]) {
        self.entries = entries
    }
}
