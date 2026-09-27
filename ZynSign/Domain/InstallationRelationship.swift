import Foundation

/// The lifecycle of one application, projected from what ZynSign holds.
///
/// The relationship view answers "how did this application get from an
/// import to an installed record?" by walking the links ZynSign actually
/// recorded: the library entry, the signing run, the export, the delivery
/// attempt, and the installed record. Every step is shown as ZynSign knows
/// it — a step with nothing behind it reads as missing, never as a success
/// invented to fill the picture.
struct InstallationRelationship: Equatable, Sendable {

    /// One step in the lifecycle.
    struct Node: Equatable, Identifiable, Sendable {

        /// Which step this is, in lifecycle order.
        enum Kind: String, CaseIterable, Sendable {
            case imported
            case signed
            case exported
            case delivery
            case installed

            /// The step's name.
            var displayName: String {
                switch self {
                case .imported: return "Imported"
                case .signed: return "Signed"
                case .exported: return "Exported"
                case .delivery: return "Delivery"
                case .installed: return "Installed"
                }
            }

            /// The symbol the step shows.
            var symbolName: String {
                switch self {
                case .imported: return "square.and.arrow.down"
                case .signed: return "signature"
                case .exported: return "doc.badge.arrow.up"
                case .delivery: return "tray.and.arrow.up"
                case .installed: return "arrow.down.app"
                }
            }
        }

        /// What the step reads as.
        enum State: Equatable, Sendable {
            /// ZynSign holds the fact and it is current.
            case current
            /// ZynSign holds the fact but something about it deserves
            /// attention (an artifact no longer held, an expired asset).
            case attention
            /// There is nothing behind this step yet. Shown honestly as
            /// "not yet", never as a failure of the later steps.
            case missing

            /// The mark the step shows.
            var displayMark: String {
                switch self {
                case .current: return "✓"
                case .attention: return "!"
                case .missing: return "–"
                }
            }
        }

        /// Which step.
        let kind: Kind

        /// How the step reads.
        let state: State

        /// The step's headline, e.g. the artifact's file name.
        let title: String

        /// The step's one supporting line, e.g. when it happened.
        let detail: String

        var id: Kind { kind }
    }

    /// The steps, in lifecycle order.
    let nodes: [Node]

    /// The application's name, for the view's title.
    let appName: String

    /// Assembles the lifecycle from the parts ZynSign holds, each optional
    /// because any of them may be absent.
    static func assemble(
        appName: String,
        importedAt: Date?,
        importAvailable: Bool?,
        signingRecord: SigningRecord?,
        exportEntry: ExportEntry?,
        latestEvent: InstalledApplicationEvent?
    ) -> InstallationRelationship {
        var nodes: [Node] = []

        if let importedAt {
            let attention = importAvailable == false
            nodes.append(Node(
                kind: .imported,
                state: attention ? .attention : .current,
                title: "Library record",
                detail: attention
                    ? "Imported \(DateFormatter.localizedString(from: importedAt, dateStyle: .medium, timeStyle: .none)) · artifact no longer held"
                    : "Imported \(DateFormatter.localizedString(from: importedAt, dateStyle: .medium, timeStyle: .none))"
            ))
        } else {
            nodes.append(Node(
                kind: .imported,
                state: .missing,
                title: "Library record",
                detail: "No import is linked to this application."
            ))
        }

        if let signingRecord, signingRecord.outcome == .succeeded {
            nodes.append(Node(
                kind: .signed,
                state: .current,
                title: signingRecord.certificateDisplayName ?? "Signing run",
                detail: "Signed \(DateFormatter.localizedString(from: signingRecord.startedAt, dateStyle: .medium, timeStyle: .short))"
            ))
        } else if let signingRecord {
            nodes.append(Node(
                kind: .signed,
                state: .attention,
                title: "Signing run",
                detail: "The run on \(DateFormatter.localizedString(from: signingRecord.startedAt, dateStyle: .medium, timeStyle: .short)) did not deliver output."
            ))
        } else {
            nodes.append(Node(
                kind: .signed,
                state: .missing,
                title: "Signing run",
                detail: "No signing run for this application is in the journal."
            ))
        }

        if let exportEntry {
            let state: Node.State = exportEntry.isAvailable ? .current : .attention
            nodes.append(Node(
                kind: .exported,
                state: state,
                title: exportEntry.record.fileName,
                detail: exportEntry.isAvailable
                    ? "Exported \(DateFormatter.localizedString(from: exportEntry.record.createdAt, dateStyle: .medium, timeStyle: .short)) · held in export storage"
                    : "Exported \(DateFormatter.localizedString(from: exportEntry.record.createdAt, dateStyle: .medium, timeStyle: .short)) · no longer held"
            ))
        } else {
            nodes.append(Node(
                kind: .exported,
                state: .missing,
                title: "Exported artifact",
                detail: "No export is linked to this application."
            ))
        }

        if let event = latestEvent {
            nodes.append(Node(
                kind: .delivery,
                state: .current,
                title: event.channel.displayName,
                detail: "Confirmed \(DateFormatter.localizedString(from: event.at, dateStyle: .medium, timeStyle: .short))"
            ))
        } else {
            nodes.append(Node(
                kind: .delivery,
                state: .missing,
                title: "Delivery",
                detail: "No delivery has been confirmed through ZynSign."
            ))
        }

        if let event = latestEvent {
            nodes.append(Node(
                kind: .installed,
                state: .current,
                title: "\(event.kind.displayName) · \(event.versionDisplay)",
                detail: "Recorded \(DateFormatter.localizedString(from: event.at, dateStyle: .medium, timeStyle: .short)) — confirmed by you"
            ))
        } else {
            nodes.append(Node(
                kind: .installed,
                state: .missing,
                title: "Installed record",
                detail: "No installation has been recorded for this application."
            ))
        }

        return InstallationRelationship(nodes: nodes, appName: appName)
    }
}
