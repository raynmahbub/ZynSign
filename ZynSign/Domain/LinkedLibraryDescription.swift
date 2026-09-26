import Foundation

/// Where a linked library comes from, read from its install name.
enum LinkedLibraryOrigin: String, CaseIterable, Hashable {
    /// A public system framework (`/System/Library/Frameworks`).
    case systemFramework
    /// A private system framework (`/System/Library/PrivateFrameworks`).
    case privateFramework
    /// The Swift runtime and overlays (`/usr/lib/swift`, `libswift*`).
    case swiftRuntime
    /// Another system library (`/usr/lib`).
    case systemLibrary
    /// Code shipped inside the app, found through `@rpath`,
    /// `@executable_path`, or `@loader_path`.
    case embedded
    /// Any other location.
    case other

    var displayName: String {
        switch self {
        case .systemFramework: return "System Framework"
        case .privateFramework: return "Private System Framework"
        case .swiftRuntime: return "Swift Runtime"
        case .systemLibrary: return "System Library"
        case .embedded: return "Embedded in App"
        case .other: return "Other Location"
        }
    }

    var systemImage: String {
        switch self {
        case .systemFramework: return "apple.logo"
        case .privateFramework: return "lock"
        case .swiftRuntime: return "swift"
        case .systemLibrary: return "books.vertical"
        case .embedded: return "shippingbox"
        case .other: return "questionmark.folder"
        }
    }

    var explanation: String {
        switch self {
        case .systemFramework:
            return "Provided by iOS itself. It is not part of this app's package, so ZynSign cannot inspect it here."
        case .privateFramework:
            return "A framework iOS uses internally. Apps normally do not link against private frameworks."
        case .swiftRuntime:
            return "The Swift standard library and overlays. Current iOS versions provide them as part of the system."
        case .systemLibrary:
            return "A system library provided by iOS, such as libSystem. It is not part of this app's package."
        case .embedded:
            return "Shipped inside this app's bundle and loaded from a path relative to the app. It carries its own code signature."
        case .other:
            return "Loaded from a location ZynSign does not classify."
        }
    }
}

/// Human-readable facts about one linked library.
struct LinkedLibraryDescription: Equatable, Identifiable {
    let reference: MachODylibReference

    var id: String { "\(reference.kind.rawValue):\(reference.installName)" }

    /// The short name developers use: `UIKit`, `libSystem.B`, `Core`.
    var displayName: String { Self.displayName(for: reference.installName) }

    var origin: LinkedLibraryOrigin { Self.origin(of: reference.installName) }

    static func displayName(for installName: String) -> String {
        let components = installName.split(separator: "/").map(String.init)
        if let frameworkIndex = components.lastIndex(where: { $0.hasSuffix(".framework") }) {
            return String(components[frameworkIndex].dropLast(".framework".count))
        }
        guard var last = components.last, !last.isEmpty else { return installName }
        if last.hasSuffix(".dylib") {
            last = String(last.dropLast(".dylib".count))
        }
        return last
    }

    static func origin(of installName: String) -> LinkedLibraryOrigin {
        if installName.hasPrefix("/System/Library/Frameworks/") { return .systemFramework }
        if installName.hasPrefix("/System/Library/PrivateFrameworks/") { return .privateFramework }
        if installName.hasPrefix("/usr/lib/swift/") { return .swiftRuntime }
        let name = installName.split(separator: "/").last.map(String.init) ?? installName
        if name.hasPrefix("libswift") && installName.hasPrefix("@rpath/") { return .swiftRuntime }
        if installName.hasPrefix("/usr/lib/") { return .systemLibrary }
        if installName.hasPrefix("@rpath/") || installName.hasPrefix("@executable_path/")
            || installName.hasPrefix("@loader_path/") {
            return .embedded
        }
        return .other
    }

    /// The executable inside the bundle this library resolves to, when it is
    /// embedded code the bundle ships.
    ///
    /// Resolution is by path suffix: `@rpath/Core.framework/Core` resolves to
    /// the target whose location ends in `Core.framework/Core`. It does not
    /// evaluate the binary's run-path search list; it only connects a name to
    /// code ZynSign can inspect, and says nothing when there is no match.
    func resolvedTarget(in targets: [BinaryTarget]) -> BinaryTarget? {
        guard origin == .embedded || origin == .swiftRuntime else { return nil }
        let installName = reference.installName
        guard let slash = installName.firstIndex(of: "/") else { return nil }
        let suffix = String(installName[installName.index(after: slash)...])
        guard !suffix.isEmpty else { return nil }
        let normalizedSuffix = suffix.hasPrefix("Frameworks/") ? String(suffix.dropFirst("Frameworks/".count)) : suffix
        return targets.first { target in
            target.kind != .mainExecutable
                && (target.executablePath.rawValue == suffix
                    || target.executablePath.rawValue.hasSuffix("/" + normalizedSuffix)
                    || target.executablePath.rawValue == normalizedSuffix)
        }
    }
}
