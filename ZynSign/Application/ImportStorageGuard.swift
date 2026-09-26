import Foundation

/// Checks free space before each working copy is made, accounting for the
/// copies other imports are making at the same moment.
///
/// Every copy reserves its size for as long as it runs. A new copy is
/// refused — before a single byte is written — when the free space the
/// platform reports cannot hold it, the headroom, and every outstanding
/// reservation. Safe to use from any task.
final class ImportStorageGuard: @unchecked Sendable {

    /// A claim on free space, held while a working copy is written.
    struct Reservation: Hashable, Sendable {
        fileprivate let id: UUID
        let byteCount: Int
    }

    private let probe: (any StorageCapacityProbe)?
    private let lock = NSLock()
    private var reservations: [UUID: Int] = [:]

    /// Creates the guard over a capacity probe. Without one, every check is
    /// `unknown` and permits the copy.
    init(probe: (any StorageCapacityProbe)?) {
        self.probe = probe
    }

    /// Reserves space for a working copy of `byteCount` bytes, or throws
    /// `ImportFailure.insufficientStorage` without reserving anything.
    func reserve(byteCount: Int) throws -> Reservation {
        lock.lock()
        defer { lock.unlock() }
        let verdict = ImportStoragePolicy.verdict(
            forWorkingCopyOf: byteCount,
            reservedBytes: reservedTotal(),
            availableBytes: probe?.availableCapacity()
        )
        if case .insufficient(let required, let available) = verdict {
            throw ImportFailure.insufficientStorage(requiredBytes: required, availableBytes: available)
        }
        let reservation = Reservation(id: UUID(), byteCount: max(0, byteCount))
        reservations[reservation.id] = reservation.byteCount
        return reservation
    }

    /// Releases a reservation once its copy has finished or failed.
    func release(_ reservation: Reservation) {
        lock.lock()
        reservations[reservation.id] = nil
        lock.unlock()
    }

    /// The bytes currently reserved by running copies.
    var reservedByteCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return reservedTotal()
    }

    /// The free space the platform reports, when it can.
    func availableCapacity() -> Int? {
        probe?.availableCapacity()
    }

    private func reservedTotal() -> Int {
        reservations.values.reduce(0) { total, bytes in
            let (sum, overflow) = total.addingReportingOverflow(bytes)
            return overflow ? Int.max : sum
        }
    }
}
