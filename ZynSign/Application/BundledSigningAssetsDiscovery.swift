import Foundation

/// Discovers pre-bundled signing assets placed inside `Bundle.main` under
/// `signing-assets/<Folder>/{cert.p12, cert.mobileprovision, cert.txt}`
/// so the user can import them in one tap without hunting in Files.
struct BundledSigningAssetsDiscovery: Sendable {

    struct DiscoveredAssetSet: Equatable, Sendable, Identifiable {
        var id: String { folderName }
        let folderName: String
        let p12URL: URL
        let profileURL: URL
        let password: String
    }

    static func discover(in bundle: Bundle = .main) -> [DiscoveredAssetSet] {
        var combined: [DiscoveredAssetSet] = []
        if let resourceRoot = bundle.resourceURL {
            combined.append(contentsOf: discover(under: resourceRoot.appendingPathComponent("signing-assets", isDirectory: true)))
        }
        if let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            combined.append(contentsOf: discover(under: docs.appendingPathComponent("signing-assets", isDirectory: true)))
        }
        return combined
    }

    static func discover(under assetsRoot: URL) -> [DiscoveredAssetSet] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: assetsRoot.path),
              let folders = try? fm.contentsOfDirectory(
                at: assetsRoot,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
              ) else { return [] }

        var results: [DiscoveredAssetSet] = []
        for folder in folders.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            if let pair = FileArchiveTools.detectCertificatePair(in: folder) {
                results.append(DiscoveredAssetSet(
                    folderName: folder.lastPathComponent,
                    p12URL: pair.p12URL,
                    profileURL: pair.profileURL,
                    password: pair.passwordHint ?? ""
                ))
            }
        }
        return results
    }
}
