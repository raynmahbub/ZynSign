/// Where a user's request to import a package came from.
///
/// Provenance is presentation metadata: it decides the label and symbol a
/// queued import shows, and nothing else. No rule in ZynSign behaves
/// differently because of it — every origin enters the same validation,
/// staging, examination, duplicate, and admission path — and it is never a
/// trust input, because the file it describes is untrusted however it
/// arrived.
enum ImportOrigin: String, CaseIterable, Hashable, Sendable {

    /// The user chose the file in the system document picker, from any
    /// screen that offers one.
    case documentPicker

    /// Another application handed the file to ZynSign: “Open in ZynSign”,
    /// “Share → ZynSign”, or a document-open request.
    case shareSheet

    /// The user dropped the file onto a ZynSign screen.
    case dragAndDrop

    /// The user asked for the file again after an earlier attempt did not
    /// finish. The job keeps the origin of the request it repeats, so this
    /// case never appears on a job.
    case retry

    /// The short name shown on a queued import.
    var displayName: String {
        switch self {
        case .documentPicker: return "Files"
        case .shareSheet: return "Shared"
        case .dragAndDrop: return "Dropped"
        case .retry: return "Retried"
        }
    }

    /// The sentence shown when a job needs explaining in full.
    var explanation: String {
        switch self {
        case .documentPicker: return "Chosen from Files."
        case .shareSheet: return "Handed to ZynSign by another application."
        case .dragAndDrop: return "Dropped into ZynSign."
        case .retry: return "Attempted again."
        }
    }

    /// The SF Symbol shown beside the origin label.
    var symbolName: String {
        switch self {
        case .documentPicker: return "folder"
        case .shareSheet: return "square.and.arrow.down"
        case .dragAndDrop: return "hand.point.up.left"
        case .retry: return "arrow.clockwise"
        }
    }
}
