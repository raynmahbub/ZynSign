/// Whether the device has room for an import's working copy, decided
/// *before* anything is copied.
///
/// A working copy needs its own size in free space, plus headroom so an
/// import never drives the device to completely full, plus whatever other
/// imports running at the same time have already claimed. A capacity the
/// platform cannot report is not treated as a shortage: the copy itself
/// then settles it, and still fails cleanly if the volume fills up.
enum ImportStoragePolicy {

    /// The free space always left untouched on top of a working copy.
    static let headroomBytes = 100 * 1_024 * 1_024

    /// The outcome of a storage check.
    enum Verdict: Equatable, Hashable, Sendable {

        /// There is room for the working copy.
        case sufficient

        /// There is not enough room. `requiredBytes` includes the headroom
        /// and every concurrent claim; `availableBytes` is what the
        /// platform reported.
        case insufficient(requiredBytes: Int, availableBytes: Int)

        /// The platform could not report its free space.
        case unknown

        /// Whether the verdict permits the copy.
        var permitsCopy: Bool {
            switch self {
            case .sufficient, .unknown: return true
            case .insufficient: return false
            }
        }
    }

    /// The free space a working copy of `byteCount` bytes needs while
    /// `reservedBytes` are already claimed by other running imports.
    static func requiredBytes(forWorkingCopyOf byteCount: Int, reservedBytes: Int = 0) -> Int {
        let parts = [max(0, byteCount), max(0, reservedBytes), headroomBytes]
        return parts.reduce(0) { total, part in
            let (sum, overflow) = total.addingReportingOverflow(part)
            return overflow ? Int.max : sum
        }
    }

    /// Decides whether a working copy of `byteCount` bytes fits.
    static func verdict(
        forWorkingCopyOf byteCount: Int,
        reservedBytes: Int,
        availableBytes: Int?
    ) -> Verdict {
        guard let availableBytes else { return .unknown }
        let required = requiredBytes(forWorkingCopyOf: byteCount, reservedBytes: reservedBytes)
        return availableBytes >= required
            ? .sufficient
            : .insufficient(requiredBytes: required, availableBytes: availableBytes)
    }
}
