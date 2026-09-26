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
    /// The document's *name* is checked here because the name is the only
    /// thing ZynSign has to go on before reading content, and it is checked
    /// as a policy gate only: a file called `Example.ipa` is still untrusted
    /// afterwards, and nothing later in the import relies on the name.
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
        guard acceptsName else {
            throw ZynSignError.unsupportedImportFile(
                diagnosticDetail: "The selected file's extension is not an accepted package or archive type."
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

        // Only an observation of *wrong* bytes refuses the candidate. When
        // the leading bytes could not be read at all, the archive boundary
        // decides instead — a provider that vends its content only through a
        // coordinated read is not a broken package.
        if description.beginsWithArchiveSignature == false {
            throw ZynSignError.importContainerUnrecognised(
                diagnosticDetail: "The selected document's first bytes are not a ZIP container signature."
            )
        }
    }
}
