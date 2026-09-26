import Foundation

extension Notification.Name {

    /// Posted after a signing run appended a record to the signing journal.
    ///
    /// The journal is append-only and read by several screens; the one that
    /// signs posts this so the others — the library's signed state, its
    /// Recently Signed and Expiring Soon collections, and its statistics —
    /// re-read the journal without polling it. The notification carries no
    /// payload: observers read the journal itself, so what they show is
    /// always what the journal holds.
    static let signingHistoryDidChange = Notification.Name("ZynSignSigningHistoryDidChange")
}
