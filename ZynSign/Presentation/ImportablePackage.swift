import UniformTypeIdentifiers

/// The document-picker content types for ZynSign's package import, in one
/// place for every screen that opens the picker.
///
/// The types are derived from the same file-type policy the import use case
/// enforces (`IPAFileFormat`). The picker restricts the user's choice; it is
/// still not trusted as evidence about content — the use case re-checks the
/// file it is handed.
enum ImportablePackage {

    /// The content types the system document picker offers.
    static var contentTypes: [UTType] {
        if let packageType = UTType(
            filenameExtension: IPAFileFormat.pathExtension,
            conformingTo: .data
        ) {
            return [packageType]
        }
        return [.data]
    }
}
