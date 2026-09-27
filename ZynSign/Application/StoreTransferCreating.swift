import Foundation

protocol StoreTransferring: AnyObject {
    func start()
    func pause()
    func resume()
    func cancel()
}
protocol StoreTransferCreating: Sendable {
    func make(url: URL, destination: URL, expectedSize: Int64?,
              progress: @escaping @Sendable (Double?) -> Void,
              completion: @escaping @Sendable (Result<URL, Error>) -> Void) -> any StoreTransferring
}
struct StoreTransferFactory: StoreTransferCreating {
    func make(url: URL, destination: URL, expectedSize: Int64?,
              progress: @escaping @Sendable (Double?) -> Void,
              completion: @escaping @Sendable (Result<URL, Error>) -> Void) -> any StoreTransferring {
        StorePackageTransfer(url: url, destination: destination, expectedSize: expectedSize, progress: progress, completion: completion)
    }
}
