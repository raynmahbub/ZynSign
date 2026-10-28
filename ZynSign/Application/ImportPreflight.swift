import Foundation

/// The checks that run on a selected document before any of it is copied into
/// ZynSign.
///
/// The pre-import checks answer the questions that can be answered cheaply
/// and that decide whether spending storage on the file is worth anything:
/// does the file exist and can it be reached, does it carry the accepted
/// extension, is it a regular file rather than a directory, is there anything
/// in it, is it small enough to copy, and does it begin the way a package
/// archive begins. They run **before** the copy, so a file that cannot be
/// imported costs the user nothing but the refusal.
///
/// These checks are deliberately shallow, and they are not a substitute for
/// the examinations that follow. Passing preflight means only that the file
/// is worth copying: it is not evidence that the archive is well formed, that
/// its entries are safe, that it contains an application, that its declared
/// metadata is complete, or that the package is genuine, signed, or
/// installable. The archive boundary and the metadata examination decide
/// those, about the copied bytes, and their findings are the ones that refuse
/// a package.
///
/// **The name is a shortcut, never the verdict.** A document is a candidate
/// when its name is one ZynSign imports *or* when its leading bytes are a ZIP
/// container's, and a package that arrived under a name Files, a browser, or
/// another app rewrote is still imported. The reverse is true as well: a
/// document named like a package whose leading bytes could not be read — or
/// whose leading bytes are not what a ZIP begins with — is still copied and
/// handed to the archive boundary, because the copy is the authority on
/// content and a shallow check is not allowed to overrule it. Only a name
/// ZynSign does not import *together with* leading bytes that are definitely
/// not a container is refused here, which is the one case where both
/// observations agree.
///
/// Every refusal is a typed `ZynSignError` whose user-facing message names
/// what was observed — "empty", "too large", "not a package archive" — rather
/// than a stage name, so the interface can render the reason without a second
/// vocabulary.
enum ImportPreflight {

    /// The greatest candidate ZynSign will copy.
    ///
    /// A deliberate ceiling rather than a tuned measurement: the largest
    /// redistributable application packages are well under this, and a
    /// selection beyond it is refused before a byte is written rather than
    /// discovered when the device runs out of room. The archive's own entry
    /// and expansion limits still apply afterwards.
    static let maximumCandidateByteCount = 4 * 1_024 * 1_024 * 1_024

    /// Applies the policy to a described candidate, throwing the typed error
    /// that explains the refusal.
    ///
    /// Two observations decide whether the file is worth copying: the name
    /// the platform reported, and the leading bytes it could read. Either one
    /// is enough to make a candidate, because both routes into a package are
    /// real — a `.ipa` from a browser keeps its name, and a package AirDropped
    /// as `App.zip` or handed over with no name at all keeps its bytes. The
    /// refusal is for the case where neither observation is hopeful: a name
    /// ZynSign does not import, on a document whose bytes begin with something
    /// that is definitely not a ZIP container.
    ///
    /// A package-named document that begins with anything else is *not*
    /// refused here. A few bytes read through one route are a weaker
    /// observation than the copy that follows, and a provider that answers
    /// with a decrypted or partial view of its file has produced a
    /// disagreement, not a verdict. The copy's own bytes go to the archive
    /// boundary, and that boundary refuses what is not an archive with a
    /// message about the archive rather than about the name.
    ///
    /// - Parameters:
    ///   - source: the URL the platform vended for the selection, used for
    ///     its extension alone.
    ///   - description: what the platform observed about the document.
    ///   - acceptingContainers: whether a ZIP archive that may *hold*
    ///     packages is acceptable too. The Import Hub accepts them and opens
    ///     them safely; the one-shot import accepts packages only.
    static func validate(
        _ source: URL,
        describedBy description: ImportSourceDescription,
        acceptingContainers: Bool = false
    ) throws {
        let acceptsName = acceptingContainers
            ? IPAFileFormat.acceptsForImport(source)
            : IPAFileFormat.accepts(source)
        // Only the route that can open a container accepts one by its
        // content: the Import Hub classifies an archive before extracting
        // anything, so a package renamed to anything at all still has a way
        // in. The one-shot import reads packages and nothing else, and a
        // renamed container belongs in the hub.
        let beginsWithContainer = acceptingContainers && description.beginsWithArchiveSignature == true
        guard acceptsName || beginsWithContainer else {
            throw ZynSignError.unsupportedImportFile(
                diagnosticDetail: "The selected file is neither named as a package or archive nor does it begin with a ZIP container signature."
            )
        }

        switch description.kind {
        case .directory:
            throw ZynSignError.unsupportedImportFile(
                diagnosticDetail: "The selected document is a directory, not a regular file."
            )
        case .regularFile, .unknown:
            // An unknown kind is not a refusal: a provider that cannot
            // describe its item is not evidence that the item is unusable,
            // and the copy is what settles it.
            break
        }

        // The size is policed only when it was observed, and only as a bound
        // on what ZynSign is willing to copy. It is not a statement about the
        // content: the archive boundary measures the copy itself.
        if let byteCount = description.byteCount {
            guard byteCount > 0 else {
                throw ZynSignError.importSourceEmpty(
                    diagnosticDetail: "The selected document reports zero bytes."
                )
            }
            guard byteCount <= maximumCandidateByteCount else {
                throw ZynSignError.importSourceTooLarge(
                    diagnosticDetail: "The selected document is \(byteCount) bytes, above the accepted ceiling of \(maximumCandidateByteCount) bytes."
                )
            }
        }

        // No content check follows, deliberately. Whether the copy is an
        // archive is decided by reading the copy — the one place where the
        // bytes, their length, and their checksums are all observable — and
        // not by four bytes read through whatever route a provider happened
        // to offer before the copy.
    }
}
