/// The resource policy ZynSign applies while inspecting an imported archive.
///
/// An imported package is untrusted, so the reader must be able to refuse work
/// before or during inspection rather than discover exhaustion afterwards.
/// These limits are architectural policy rather than implementation detail:
/// they are declared as data, chosen by the composition root, and enforced by
/// the reader and the structural validator.
///
/// The defaults are conservative ceilings for a redistributable application
/// package, not tuned measurements. They are deliberately generous enough to
/// accept an ordinary large package, and low enough that a small archive
/// cannot describe work far larger than itself without being refused.
struct ArchiveLimits: Equatable, Hashable {

    /// The greatest number of entries one container may record.
    let maximumEntryCount: Int

    /// The greatest accepted entry-name length, in bytes, as recorded by the
    /// container. Longer names are refused rather than decoded.
    let maximumEntryNameLength: Int

    /// The greatest accepted nesting depth of an entry path, in components.
    let maximumPathDepth: Int

    /// The greatest expanded size accepted for a single entry, in bytes.
    let maximumEntryBytes: Int

    /// The greatest total expanded size accepted for the whole container, in
    /// bytes, as declared by the container's own metadata.
    let maximumTotalUncompressedBytes: Int

    /// The greatest accepted ratio between an entry's declared expanded size
    /// and its stored size. A ratio far beyond what real package content
    /// reaches is treated as an attempt to describe work the reader should
    /// not perform.
    let maximumCompressionRatio: Int

    /// The greatest number of bytes one bounded content read may produce, in
    /// bytes. Inspection reads are capped so that a single small request can
    /// never expand into a large allocation, whatever the container claims.
    let maximumInspectionReadBytes: Int

    /// Records a resource policy.
    init(
        maximumEntryCount: Int,
        maximumEntryNameLength: Int,
        maximumPathDepth: Int,
        maximumEntryBytes: Int,
        maximumTotalUncompressedBytes: Int,
        maximumCompressionRatio: Int,
        maximumInspectionReadBytes: Int
    ) {
        self.maximumEntryCount = maximumEntryCount
        self.maximumEntryNameLength = maximumEntryNameLength
        self.maximumPathDepth = maximumPathDepth
        self.maximumEntryBytes = maximumEntryBytes
        self.maximumTotalUncompressedBytes = maximumTotalUncompressedBytes
        self.maximumCompressionRatio = maximumCompressionRatio
        self.maximumInspectionReadBytes = maximumInspectionReadBytes
    }

    /// The policy ZynSign applies unless the composition root chooses another.
    static let `default` = ArchiveLimits(
        maximumEntryCount: 100_000,
        maximumEntryNameLength: 4_096,
        maximumPathDepth: 32,
        maximumEntryBytes: 2 * 1_024 * 1_024 * 1_024,
        maximumTotalUncompressedBytes: 16 * 1_024 * 1_024 * 1_024,
        maximumCompressionRatio: 1_000,
        maximumInspectionReadBytes: 4 * 1_024 * 1_024
    )

    /// Whether the container declares more expanded content in one entry than
    /// the policy accepts.
    func exceedsEntryBytes(_ uncompressedSize: Int) -> Bool {
        uncompressedSize > maximumEntryBytes
    }

    /// Whether the container declares more expanded content overall than the
    /// policy accepts.
    func exceedsTotalUncompressedBytes(_ totalUncompressedBytes: Int) -> Bool {
        totalUncompressedBytes > maximumTotalUncompressedBytes
    }

    /// Whether one entry declares an expansion ratio beyond the policy. The
    /// comparison is by division rather than multiplication so that hostile
    /// sizes cannot overflow the arithmetic.
    func exceedsCompressionRatio(uncompressedSize: Int, compressedSize: Int) -> Bool {
        guard compressedSize > 0 else {
            return uncompressedSize > 0 && maximumCompressionRatio < Int.max
        }
        return (uncompressedSize / compressedSize) > maximumCompressionRatio
    }
}
