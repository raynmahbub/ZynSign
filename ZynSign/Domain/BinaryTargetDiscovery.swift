import Foundation

/// Finds the executables of one application bundle from its recorded
/// structure.
///
/// Discovery is a rule over names and locations, applied to the bundle
/// structure the archive boundary already produced. It reads nothing itself:
/// the caller supplies the executable names the nested bundles declare
/// (`CFBundleExecutable`), and discovery falls back to the platform's naming
/// convention — the bundle's own base name — when a bundle declares none.
/// Whether a candidate really is Mach-O code is established later, when the
/// inspector parses it; a candidate that is not is reported as such, never
/// hidden.
///
/// The locations match what iOS loads from an app: the main executable at
/// the bundle root; frameworks and standalone libraries directly in
/// `Frameworks`; extensions in `PlugIns` and `Extensions`; nested apps in
/// `Watch` and `AppClips`. Nested code deeper than one level is left to the
/// bundle explorer.
enum BinaryTargetDiscovery {

    /// The containers whose Info.plist declares a nested executable name, in
    /// discovery order. The caller reads these, bounded, before calling
    /// `discover`.
    static func nestedContainers(in contents: BundleContents) -> [BundlePath] {
        var containers: [BundlePath] = []
        for (directory, suffixes) in containerDirectories {
            guard let path = BundlePath(rawValue: directory),
                  let children = contents.entries(in: path) else { continue }
            for child in children where child.isDirectory && hasSuffix(child.name, suffixes) {
                containers.append(child.path)
            }
        }
        return containers
    }

    /// Discovers every executable target.
    ///
    /// - Parameters:
    ///   - contents: The bundle structure.
    ///   - mainExecutableName: The name the application declares, or `nil`.
    ///   - declaredExecutableNames: The executable names nested bundles
    ///     declare, by container path.
    ///   - maximumNestedTargets: The most nested targets returned; the rest
    ///     are counted as omitted.
    static func discover(
        contents: BundleContents,
        mainExecutableName: String?,
        declaredExecutableNames: [BundlePath: String],
        maximumNestedTargets: Int
    ) -> BinaryBundleOverview {
        var nested: [BinaryTarget] = []

        for (directory, suffixes) in containerDirectories {
            guard let directoryPath = BundlePath(rawValue: directory),
                  let children = contents.entries(in: directoryPath) else { continue }
            for child in children {
                if child.isDirectory, hasSuffix(child.name, suffixes) {
                    let declared = declaredExecutableNames[child.path].flatMap(validName)
                    let name = declared ?? baseName(of: child.name)
                    guard let executablePath = child.path.appending(component: name),
                          let entry = contents.entry(at: executablePath),
                          entry.kind == .regularFile else { continue }
                    nested.append(BinaryTarget(
                        kind: kind(forContainerNamed: child.name),
                        name: name,
                        executablePath: executablePath,
                        containerPath: child.path,
                        declaredByteCount: entry.declaredByteCount
                    ))
                } else if directory == "Frameworks",
                          child.kind == .regularFile,
                          child.name.lowercased().hasSuffix(".dylib") {
                    nested.append(BinaryTarget(
                        kind: .dynamicLibrary,
                        name: child.name,
                        executablePath: child.path,
                        containerPath: nil,
                        declaredByteCount: child.declaredByteCount
                    ))
                }
            }
        }

        nested.sort { lhs, rhs in
            if lhs.kind.sortRank != rhs.kind.sortRank { return lhs.kind.sortRank < rhs.kind.sortRank }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        let bound = max(0, maximumNestedTargets)
        let kept = Array(nested.prefix(bound))

        var targets: [BinaryTarget] = []
        if let name = mainExecutableName.flatMap(validName),
           let path = BundlePath.root.appending(component: name),
           let entry = contents.entry(at: path),
           entry.kind == .regularFile {
            targets.append(BinaryTarget(
                kind: .mainExecutable,
                name: name,
                executablePath: path,
                containerPath: .root,
                declaredByteCount: entry.declaredByteCount
            ))
        }
        targets.append(contentsOf: kept)
        return BinaryBundleOverview(
            bundleName: contents.bundleName,
            targets: targets,
            omittedTargetCount: max(0, nested.count - kept.count)
        )
    }

    // MARK: - Rules

    /// The directories searched, and the container suffixes each holds.
    private static let containerDirectories: [(String, [String])] = [
        ("Frameworks", [".framework"]),
        ("PlugIns", [".appex"]),
        ("Extensions", [".appex"]),
        ("Watch", [".app"]),
        ("AppClips", [".app"]),
    ]

    private static func hasSuffix(_ name: String, _ suffixes: [String]) -> Bool {
        let lowered = name.lowercased()
        return suffixes.contains { lowered.hasSuffix($0) && lowered.count > $0.count }
    }

    private static func kind(forContainerNamed name: String) -> BinaryTarget.Kind {
        let lowered = name.lowercased()
        if lowered.hasSuffix(".framework") { return .framework }
        if lowered.hasSuffix(".appex") { return .appExtension }
        return .nestedApplication
    }

    /// `Example.framework` → `Example`.
    static func baseName(of containerName: String) -> String {
        guard let dot = containerName.lastIndex(of: "."), dot > containerName.startIndex else {
            return containerName
        }
        return String(containerName[..<dot])
    }

    /// A declared executable name is accepted only as a single, safe path
    /// component: a declaration cannot point discovery elsewhere in the bundle.
    private static func validName(_ name: String) -> String? {
        BundlePath.isValidComponent(name) ? name : nil
    }
}
