/// Where a user's request to import a package came from.
///
/// Provenance is presentation metadata: it decides the label and symbol a
/// queued import shows, and the source the import history records, and
/// nothing else. No rule in ZynSign behaves differently because of it —
/// every origin enters the same Import Hub and the same validation,
/// staging, examination, duplicate, and admission path — and it is never a
/// trust input, because the file it describes is untrusted however it
/// arrived.
///
/// The raw values are persisted by the import history and the interrupted
/// import journal, so they must never be renamed.
enum ImportOrigin: String, CaseIterable, Hashable, Sendable, Codable {

    /// The user chose the file in the system document picker, from any
    /// screen that offers one.
    case documentPicker

    /// Another application handed ZynSign a copy of the file through the
    /// share sheet (“Copy to ZynSign”). The system places such copies in
    /// ZynSign's own inbox.
    case shareSheet

    /// The user dropped the file onto a ZynSign screen.
    case dragAndDrop

    /// The user asked for the file again after an earlier attempt did not
    /// finish. An item keeps the origin of the request it repeats, so this
    /// case never appears on an item.
    case retry

    /// Another application opened the file in ZynSign in place (“Open in
    /// ZynSign” from Files, or a document-open request), without handing
    /// over a copy.
    case openIn

    /// The short name shown on a queued import.
    var displayName: String {
        switch self {
        case .documentPicker: return "Files"
        case .shareSheet: return "Shared"
        case .dragAndDrop: return "Dropped"
        case .retry: return "Retried"
        case .openIn: return "Opened In"
        }
    }

    /// The sentence shown when an item needs explaining in full.
    var explanation: String {
        switch self {
        case .documentPicker: return "Chosen from Files."
        case .shareSheet: return "Handed to ZynSign by another application."
        case .dragAndDrop: return "Dropped into ZynSign."
        case .retry: return "Attempted again."
        case .openIn: return "Opened in ZynSign from another application."
        }
    }

    /// The SF Symbol shown beside the origin label.
    var symbolName: String {
        switch self {
        case .documentPicker: return "folder"
        case .shareSheet: return "square.and.arrow.down"
        case .dragAndDrop: return "hand.point.up.left"
        case .retry: return "arrow.clockwise"
        case .openIn: return "arrow.up.forward.app"
        }
    }
}
