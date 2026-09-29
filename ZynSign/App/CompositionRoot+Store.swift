import Foundation

/// The Store and the Download Center.
///
/// Part of `CompositionRoot`, which chooses every concrete
/// implementation and wires the layers together. Split out of the
/// original single file for readability; the members are unchanged.
extension CompositionRoot {

    /// The Download Center and the repository directory it trusts only after
    /// metadata validation. Transfers are foreground URLSession tasks. Resume
    /// is reported only when resume data is captured.
    static func makeDownloadCenter(
        library: ApplicationLibrary,
        importHub: ImportHub,
        notifier: (any DownloadNotifying)?,
        catalogs: @escaping @MainActor () -> [RepositoryCatalog]
    ) -> DownloadCenter {
        let client = URLSessionRepositoryClient()
        let center = DownloadCenter(
            transfer: URLSessionDownloadTransfer(),
            validator: IPADownloadValidator(),
            store: FileDownloadCenterStore(rootDirectory: downloadCenterRoot),
            importer: ImportHubDownloadImporter(hub: importHub),
            notifier: notifier,
            manifestResolver: client,
            installedApplications: { @MainActor in
                let entries = (try? await library.entries()) ?? []
                return entries.map { entry in
                    InstalledApplication(
                        bundleIdentifier: entry.record.bundleIdentifier.rawValue,
                        name: entry.record.displayName ?? entry.record.bundleIdentifier.rawValue,
                        version: entry.record.identity.shortVersionString,
                        build: entry.record.identity.buildVersion,
                        recordID: entry.record.id.rawValue
                    )
                }
            },
            catalogs: catalogs
        )
        return center
    }

    static func makeRepositoryDirectory() -> RepositoryDirectory {
        RepositoryDirectory(
            storeURL: repositorySourceStoreURL,
            cacheDirectory: downloadCenterRoot.appendingPathComponent("Catalogs", isDirectory: true),
            fetcher: URLSessionRepositoryClient()
        )
    }
}
