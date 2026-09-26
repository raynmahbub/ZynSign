import Foundation

/// The boundary through which ZynSign reaches the content of an imported
/// archive container.
///
/// An imported package is untrusted input, and so is everything inside it.
/// This port is the seam where container parsing, resource limits, and content
/// access live; callers see only domain types and structured failures, and
/// never see a container handle, a filesystem location, or a decompression
/// detail.
///
/// The port is deliberately narrow. It answers the questions inspection
/// actually asks — what the container records, whether a named entry exists,
/// what kind of entry it is, and whether one entry's content can be read
/// within a stated bound. It does not offer extraction, writing, updating,
/// whole-container decompression, or any other capability the inspection
/// stage does not need. Application-bundle discovery is not part of this port:
/// it is a rule about package layout and therefore lives in the domain, where
/// it stays testable without a container.
///
/// Implementations are platform-bound and substitutable. A different container
/// engine, an optimized reader, or a platform-specific storage integration can
/// replace the current implementation without any caller changing, provided
/// the reader keeps refusing unsafe names and stays inside the resource policy.
protocol ArchiveReader: AnyObject {

    /// The complete entry table of the container, in container order.
    ///
    /// The table is metadata only: no entry content is read, and no entry is
    /// written to any filesystem. Entries whose recorded name fails ZynSign's
    /// safety rules are present with a `nil` path, so that they are reported
    /// rather than skipped.
    func readEntryTable() throws -> [ArchiveEntry]

    /// Whether the container records an entry at `path`.
    func containsEntry(at path: ArchivePath) throws -> Bool

    /// The kind the container records for the entry at `path`, or `nil` when
    /// the container records no such entry.
    func entryKind(at path: ArchivePath) throws -> ArchiveEntryKind?

    /// Reads the content of the entry at `path`, producing at most
    /// `maximumBytes` bytes.
    ///
    /// The bound is enforced against the reader's own policy as well, so a
    /// caller cannot widen it. The reader refuses rather than truncates: it
    /// fails with a typed error when the entry is absent, stored in a form the
    /// reader does not support, larger than the bound, or cannot be expanded.
    /// A caller therefore either receives the whole entry within the bound, or
    /// receives a failure — never a silently shortened value.
    func readEntryData(at path: ArchivePath, maximumBytes: Int) throws -> Data

    /// Reads at most `maximumBytes` expanded bytes from the entry at `path`.
    ///
    /// When the entry's declared compressed and expanded sizes both fit in
    /// `maximumBytes` and in the reader's policy, this is a complete read:
    /// implementations that record a checksum verify it, and the result is the
    /// whole entry. When the entry is larger, an implementation may return a
    /// prefix of at most `maximumBytes` expanded bytes without verifying the
    /// whole-entry checksum, or it may fail rather than return a partial
    /// value. The default fails closed by attempting a complete read.
    ///
    /// A prefix is not a substitute for the entry. Nothing this method does
    /// writes the container, extracts it, or follows a link.
    func readEntryPrefix(at path: ArchivePath, maximumBytes: Int) throws -> Data

    /// Releases the container's underlying resources.
    ///
    /// Closing is idempotent, and inspection closes the reader on every
    /// outcome — success, failure, and cancellation alike.
    func close()
}

extension ArchiveReader {

    /// Fails closed: a reader that has not implemented a true prefix read
    /// attempts a complete read and therefore refuses an entry larger than
    /// the bound rather than silently shortening it.
    func readEntryPrefix(at path: ArchivePath, maximumBytes: Int) throws -> Data {
        try readEntryData(at: path, maximumBytes: maximumBytes)
    }
}
