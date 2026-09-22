/// Bundle-inspection constructors for `ZynSignError`.
///
/// Inspecting a library application's bundle can fail before the package is
/// opened — the record is gone, or the record is present but its package is
/// not the one the library keeps — and after, when the package cannot be
/// read or holds no application bundle. The pre-opening failures are named
/// here so that "the file is missing" and "the file is not the file that was
/// imported" reach the user as distinct, honest statements rather than as a
/// generic read failure. Failures inside the package reuse the archive and
/// artifact factories: an unreadable container or an absent bundle is the
/// same outcome whether it is met during import or during inspection.
///
/// Every message describes reading. None makes a claim about signatures,
/// trust, or installability, because inspection establishes none of those.
///
/// `diagnosticDetail` remains subject to the redaction rules: no key
/// material, credentials, profile bodies, device identifiers, user data, or
/// unnecessary filesystem locations.
extension ZynSignError {

    /// The record exists but the library holds no package for it, so there
    /// is nothing to inspect. Reported as a storage failure: the library's
    /// storage no longer matches its catalog.
    static func bundleArtifactMissing(
        diagnosticDetail: String? = nil,
        underlyingError: (any Error)? = nil
    ) -> ZynSignError {
        ZynSignError(
            category: .storageFailure,
            userMessage: "The package for this application is missing from ZynSign's library, so its contents cannot be shown.",
            diagnosticDetail: diagnosticDetail,
            underlyingError: underlyingError
        )
    }

    /// The record exists and the library holds a package for it, but the
    /// package no longer matches what was imported. Inspection refuses to
    /// describe bytes the record does not vouch for.
    static func bundleArtifactInconsistent(
        diagnosticDetail: String? = nil,
        underlyingError: (any Error)? = nil
    ) -> ZynSignError {
        ZynSignError(
            category: .storageFailure,
            userMessage: "The package for this application has changed since it was imported, so its contents cannot be shown.",
            diagnosticDetail: diagnosticDetail,
            underlyingError: underlyingError
        )
    }

    /// Inspection met a failure that is not one of ZynSign's own — an
    /// unexpected error from below the archive boundary. Reported as an
    /// internal failure so that unexplained errors are never dressed up as
    /// facts about the package.
    static func bundleInspectionFailure(
        diagnosticDetail: String? = nil,
        underlyingError: (any Error)? = nil
    ) -> ZynSignError {
        ZynSignError(
            category: .internalFailure,
            userMessage: "An unexpected problem stopped ZynSign from reading the application's contents.",
            diagnosticDetail: diagnosticDetail,
            underlyingError: underlyingError
        )
    }
}
