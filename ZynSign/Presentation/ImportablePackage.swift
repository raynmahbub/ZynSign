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
    ///
    /// The set is deliberately broad so a legitimate `.ipa` is never hidden
    /// by a narrow type filter. A real `.ipa` is a ZIP container and the
    /// system reports its type differently depending on OS version,
    /// provider, and whether the file was downloaded, renamed, or stored in
    /// iCloud. The dynamic type from the extension alone can miss
    /// `com.apple.itunes.ipa` / `public.zip-archive` reported by Files, so
    /// the picker offers the union: the dynamic extension type when it can
    /// be formed, plus the well-known archive and data supertypes and the
    /// declared `com.apple.itunes.ipa` identifier. The import use case still
    /// re-checks the extension and then validates content — the picker never
    /// decides validity.
    static var contentTypes: [UTType] {
        var types: Set<UTType> = []
        for ext in IPAFileFormat.acceptedPathExtensions {
            if let dynamic = UTType(filenameExtension: ext, conformingTo: .data) {
                types.insert(dynamic)
            }
            if let dynamicZIP = UTType(filenameExtension: ext, conformingTo: .zip) {
                types.insert(dynamicZIP)
            }
            if let dynamicArchive = UTType(filenameExtension: ext, conformingTo: .archive) {
                types.insert(dynamicArchive)
            }
            // Dynamic fallback without conformance — covers `tipa` on systems
            // that have no known supertype for it.
            if let fallback = UTType(filenameExtension: ext) {
                types.insert(fallback)
            }
        }
        // Supertypes that every `.ipa` (a ZIP) conforms to — ensures Files
        // actually shows the file even when the dynamic type mismatches the
        // provider's reported UTI.
        types.insert(.data)
        types.insert(.zip)
        if #available(iOS 15.0, *) {
            types.insert(.archive)
        }
        types.insert(.item)
        // Declared Apple identifier for IPA, where the OS knows it.
        if let itunesIPA = UTType("com.apple.itunes.ipa") {
            types.insert(itunesIPA)
        }
        if let itunesIPAPackage = UTType("com.apple.itunes.ipa-package") {
            types.insert(itunesIPAPackage)
        }
        return Array(types)
    }
}
