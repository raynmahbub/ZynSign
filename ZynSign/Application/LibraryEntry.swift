/// One library record together with the current state of its artifact.
///
/// The record is what persistence holds; the availability is derived from
/// artifact storage each time the entry is produced. Separating the two keeps
/// the persisted record free of state that storage, not the record, decides,
/// and means a record whose artifact has gone missing is still listed — with
/// its metadata intact and its problem visible — rather than hidden or
/// silently repaired.
struct LibraryEntry: Equatable, Hashable, Sendable {

    /// The persisted record.
    let record: ApplicationRecord

    /// Whether the artifact the record refers to is where the record says it
    /// is, as observed when the entry was produced.
    let artifactAvailability: ArtifactAvailability

    /// Whether the artifact can be relied on to be the recorded bytes.
    var isArtifactAvailable: Bool {
        artifactAvailability.isAvailable
    }
}

/// The outcome of offering an accepted import to the library.
enum LibraryAdmission: Equatable, Hashable {

    /// A new record was created and the artifact was taken into library
    /// storage. The relation describes any existing records that share the
    /// application's bundle identifier.
    case recorded(ApplicationRecord, relation: ApplicationRecordRelation)

    /// The library already holds byte-identical content, so no record was
    /// created and no bytes were taken. The existing record is reported.
    case alreadyRecorded(existing: ApplicationRecord)

    /// The record that now stands for the import: the new one, or the
    /// existing one it duplicated.
    var record: ApplicationRecord {
        switch self {
        case .recorded(let record, _):
            return record
        case .alreadyRecorded(let existing):
            return existing
        }
    }
}

/// The outcome of one package import: the examined artifact, and — when the
/// package was accepted — what the library did with it.
///
/// `admission` is `nil` exactly when inspection rejected the package; the
/// artifact's findings then say why. A non-`nil` admission means the package
/// passed inspection and either became a library record or was recognised
/// as content the library already held.
struct PackageImportResult: Equatable, Hashable {

    /// The artifact with the inspection outcome recorded.
    let artifact: IPAArtifact

    /// The library's decision for an accepted package, or `nil` when the
    /// package was rejected.
    let admission: LibraryAdmission?

    /// Whether inspection accepted the package.
    var isAccepted: Bool {
        artifact.permitsLaterStages
    }
}
