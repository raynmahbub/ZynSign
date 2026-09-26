import Foundation

extension Notification.Name {

    /// Posted after the signing journal changed: a run was appended, a
    /// record was removed, or the journal was cleared.
    ///
    /// The journal is read by several screens. The library's signed state,
    /// its Recently Signed and Expiring Soon collections, and its statistics
    /// re-read the journal when this is posted rather than polling it. The
    /// notification carries no payload: observers read the journal itself,
    /// so what they show is always what the journal holds. It is posted by
    /// `NotifyingSigningHistoryStore`, so every writer is covered without any
    /// of them having to remember to post it.
    static let signingHistoryDidChange = Notification.Name("ZynSignSigningHistoryDidChange")
}

/// A signing journal that says when it changed.
///
/// Wraps the journal port and posts `signingHistoryDidChange` after every
/// change it completes — whoever made it: a signing run, storage cleanup
/// removing old records, or the user clearing the journal. Reads pass
/// straight through and post nothing, and a change that throws posts
/// nothing either, because nothing changed.
struct NotifyingSigningHistoryStore: SigningHistoryStore {

    private let base: any SigningHistoryStore

    /// Wraps `base`.
    init(wrapping base: any SigningHistoryStore) {
        self.base = base
    }

    var capacity: Int { base.capacity }

    func allRecords() async throws -> [SigningRecord] {
        try await base.allRecords()
    }

    func records(forPreset presetID: PresetIdentifier) async throws -> [SigningRecord] {
        try await base.records(forPreset: presetID)
    }

    func append(_ record: SigningRecord) async throws {
        try await base.append(record)
        Self.announceChange()
    }

    func remove(recordWithID id: SigningRecordIdentifier) async throws {
        try await base.remove(recordWithID: id)
        Self.announceChange()
    }

    func clear() async throws {
        try await base.clear()
        Self.announceChange()
    }

    func count() async throws -> Int {
        try await base.count()
    }

    private static func announceChange() {
        NotificationCenter.default.post(name: .signingHistoryDidChange, object: nil)
    }
}
