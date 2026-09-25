/// Counts the explorer shows for one bundle.
///
/// Every count is derived from the entry table the package already recorded.
/// `bundleSize` is the sum of declared regular-file sizes, saturating rather
/// than overflowing. It is not a measurement taken by reading file bytes, and
/// none of the counts is a verdict on signatures, encryption, or
/// installability.
struct BundleStatistics: Equatable, Hashable {

    /// Regular files at every depth, including executables and images.
    let totalFiles: Int

    /// `.framework` directories, including nested ones.
    let frameworks: Int

    /// `.appex` directories.
    let extensions: Int

    /// Declared, conventional, and `.dylib` executables.
    let executables: Int

    /// Files classified as images.
    let images: Int

    /// The sum of declared regular-file sizes, in bytes.
    let bundleSize: Int

    /// Counts `contents`. Walking the tree does not read file bytes.
    init(contents: BundleContents) {
        var files = 0
        var frameworks = 0
        var extensions = 0
        var executables = 0
        var images = 0

        func walk(_ directory: BundlePath) {
            for entry in contents.entries(in: directory) ?? [] {
                switch BundleFileClassification.recognize(entry) {
                case .framework:
                    frameworks += 1
                case .appExtension:
                    extensions += 1
                case .executable:
                    executables += 1
                    files += 1
                case .image:
                    images += 1
                    files += 1
                case .metadata, .provisioningProfile, .text, .propertyList, .assetCatalog, .generic:
                    if entry.kind == .regularFile {
                        files += 1
                    }
                case .folder, .localization, .symbolicLink, .unsupported:
                    break
                }
                if entry.isDirectory {
                    walk(entry.path)
                }
            }
        }

        walk(.root)
        self.totalFiles = files
        self.frameworks = frameworks
        self.extensions = extensions
        self.executables = executables
        self.images = images
        self.bundleSize = contents.totalDeclaredByteCount
    }
}

/// Structural measurements the framework and extension pages share.
enum ExplorerMeasurements {

    /// The declared size of every regular file strictly inside `directory`.
    /// Saturates at `Int.max`.
    static func declaredByteCount(within directory: BundlePath, contents: BundleContents) -> Int {
        var total = 0
        func walk(_ dir: BundlePath) {
            for entry in contents.entries(in: dir) ?? [] {
                if let bytes = entry.declaredByteCount {
                    let (sum, overflow) = total.addingReportingOverflow(bytes)
                    total = overflow ? Int.max : sum
                }
                if entry.isDirectory {
                    walk(entry.path)
                }
            }
        }
        walk(directory)
        return total
    }

    /// The regular file a framework or extension bundle conventionally names
    /// as its executable, if that file is recorded. This is a name match, not
    /// a Mach-O parse.
    static func conventionalExecutable(
        in directory: BundlePath,
        bundleFileName: String,
        suffix: String,
        contents: BundleContents
    ) -> BundleEntry? {
        guard bundleFileName.count > suffix.count, bundleFileName.hasSuffix(suffix) else { return nil }
        let executableName = String(bundleFileName.dropLast(suffix.count))
        guard !executableName.isEmpty,
              let path = directory.appending(component: executableName),
              let entry = contents.entry(at: path),
              entry.kind == .regularFile else {
            return nil
        }
        return entry
    }
}
