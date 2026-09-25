import Foundation

/// The platform implementation of `StorageCapacityProbing`: the free space
/// the volume holding ZynSign's own storage reports for important usage.
///
/// The number is the platform's estimate of what an application of
/// ZynSign's kind may use, which is the right figure to plan a signing
/// operation against: it is larger than the raw "available" figure and
/// accounts for purgeable space the system will reclaim rather than a
/// number that would refuse work the device could actually do.
///
/// A platform that cannot report the figure, or reports nothing, returns
/// `nil`. `nil` means *not measured*, and the caller proceeds: refusing to
/// sign because a number was unavailable would be a guess presented as a
/// fact.
struct FileVolumeStorageCapacity: StorageCapacityProbing, Sendable {

    /// A location on the volume to ask about. Any location inside the
    /// application container answers for the container's volume.
    let location: URL

    init(location: URL) {
        self.location = location
    }

    func availableByteCount() throws -> Int? {
        let values: URLResourceValues
        do {
            values = try location.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        } catch {
            throw ZynSignError.insufficientStorageForSigning(
                diagnosticDetail: "The device's free space could not be read.",
                underlyingError: error
            )
        }
        guard let capacity = values.volumeAvailableCapacityForImportantUsage else { return nil }
        return capacity > 0 ? Int(capacity) : 0
    }
}
