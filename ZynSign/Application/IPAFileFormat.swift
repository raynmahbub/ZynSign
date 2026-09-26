import Foundation

/// The file-type policy for package imports.
///
/// The policy accepts the canonical `.ipa` extension and the `tipa`
/// (TrollStore-patched IPA) alias, case-insensitively, as the same ZIP
/// container format. The check is a cheap gate that runs before any byte is
/// copied; it is deliberately not trusted as evidence about content. A file
/// whose extension matches may still be anything at all — the archive layer,
/// not this policy, decides whether the content is a valid application
/// package.
///
/// The presentation layer also reads `pathExtension` to request the matching
/// content type from the system document picker, so the picker, the policy,
/// and the intake gate all describe the same accepted input.
enum IPAFileFormat {

    /// The canonical file-name extension, without the leading period.
    static let pathExtension = "ipa"

    /// Additional aliases that are treated as the same container format.
    /// `tipa` is a TrollStore variant that is byte-identical to an IPA.
    static let additionalPathExtensions = ["tipa"]

    /// All accepted extensions, lowercased.
    static var acceptedPathExtensions: [String] {
        [pathExtension] + additionalPathExtensions
    }

    /// Whether a file-name extension is the accepted package type. The
    /// comparison is case-insensitive; an empty extension is refused.
    static func acceptsPathExtension(_ candidate: String) -> Bool {
        acceptedPathExtensions.contains(candidate.lowercased())
    }

    /// Whether a document URL carries the accepted package type.
    static func accepts(_ source: URL) -> Bool {
        acceptsPathExtension(source.pathExtension)
    }

    // MARK: - Containers

    /// Archive extensions the Import Hub opens to look for packages inside.
    ///
    /// A ZIP is accepted as a *container*, not as a package: its entry table
    /// is classified before anything is extracted, packages inside it are
    /// offered to the user, and an archive with none is refused with an
    /// explanation. The package policy above is unchanged by this.
    static let containerPathExtensions = ["zip"]

    /// Whether `candidate` is an accepted container extension, compared
    /// case-insensitively.
    static func acceptsContainerPathExtension(_ candidate: String) -> Bool {
        containerPathExtensions.contains(candidate.lowercased())
    }

    /// Whether the Import Hub accepts `source`: a package, or an archive that
    /// may hold packages.
    static func acceptsForImport(_ source: URL) -> Bool {
        accepts(source) || acceptsContainerPathExtension(source.pathExtension)
    }
}
