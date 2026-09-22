import Foundation

/// The file-type policy for package imports.
///
/// The policy is deliberately narrow: the accepted input is an `.ipa` file,
/// matched case-insensitively on the file-name extension. The check is a
/// cheap gate that runs before any byte is copied; it is deliberately not
/// trusted as evidence about content. A file whose extension is `.ipa` may
/// still be anything at all — the archive layer, not this policy, decides
/// whether the content is a valid application package.
///
/// The presentation layer also reads `pathExtension` to request the matching
/// content type from the system document picker, so the picker, the policy,
/// and the intake gate all describe the same accepted input.
enum IPAFileFormat {

    /// The file-name extension of the accepted package type, without the
    /// leading period.
    static let pathExtension = "ipa"

    /// Whether a file-name extension is the accepted package type. The
    /// comparison is case-insensitive; an empty extension is refused.
    static func acceptsPathExtension(_ candidate: String) -> Bool {
        candidate.lowercased() == pathExtension
    }

    /// Whether a document URL carries the accepted package type.
    static func accepts(_ source: URL) -> Bool {
        acceptsPathExtension(source.pathExtension)
    }
}
