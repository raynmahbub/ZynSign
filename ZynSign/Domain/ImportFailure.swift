import Foundation

/// A failure explanation for one import, composed for the user.
///
/// This is the single place where the two vocabularies of an import failure —
/// the typed errors the intake and the library throw, and the typed findings
/// the inspection stage records — become words a person can act on. Nothing
/// else composes that text, so the same failure reads the same way wherever
/// it is shown, and no diagnostic detail, filesystem location, or foreign
/// error text can reach the user through a second path.
///
/// Three things are stated separately, because they are different questions:
/// what happened (`title`), what it means (`message`), and what the user can
/// do about it (`recovery`). `isRetryable` is the answer to a fourth — whether
/// attempting the same file again can plausibly end differently — which
/// decides whether the interface offers a retry at all rather than offering
/// one that is certain to fail again.
///
/// Nothing here claims anything about a package's authenticity. A refusal
/// says the package did not satisfy ZynSign's structural and declared-metadata
/// rules; it is not a statement that the file is malicious, and an acceptance
/// is not a statement that it is safe.
struct ImportFailure: Equatable, Hashable, Sendable {

    /// What the user can do next. Recovery is advice, not an action: the
    /// interface decides which controls, if any, the suggestion becomes.
    enum Recovery: Equatable, Hashable, Sendable {

        /// Choose a different file — the selected one cannot be imported.
        case chooseAnotherFile

        /// Attempt the same file again. Offered only when the failure is one
        /// that a later attempt can plausibly survive.
        case retry

        /// Free storage on the device, then attempt the import again.
        case freeStorage

        /// Re-grant ZynSign access to the file, then attempt it again.
        case checkAccess

        /// Nothing to do; the explanation stands on its own.
        case none

        /// The user-presentable name of the suggested action.
        var displayName: String {
            switch self {
            case .chooseAnotherFile: return "Choose Another Package"
            case .retry: return "Try Again"
            case .freeStorage: return "Free Up Space"
            case .checkAccess: return "Allow Access"
            case .none: return "OK"
            }
        }

        /// The SF Symbol shown beside the suggestion.
        var symbolName: String {
            switch self {
            case .chooseAnotherFile: return "folder.badge.plus"
            case .retry: return "arrow.clockwise"
            case .freeStorage: return "externaldrive.badge.exclamationmark"
            case .checkAccess: return "lock.open"
            case .none: return "checkmark"
            }
        }
    }

    /// The short headline: what happened.
    let title: String

    /// The explanation: what it means, in the user's terms.
    let message: String

    /// What the user can do about it.
    let recovery: Recovery

    /// Whether attempting the same file again can plausibly end differently.
    let isRetryable: Bool

    /// The category the failure belongs to, for diagnostics and for rules
    /// that must not depend on wording.
    let category: DiagnosticCategory

    /// The finding that refused the package, when a refusal produced this
    /// explanation. `nil` for failures that were not refusals.
    let primaryCode: ValidationIssueCode?

    /// Records an explanation. Prefer the factories below, which map typed
    /// outcomes onto the vocabulary this type guarantees.
    init(
        title: String,
        message: String,
        recovery: Recovery,
        isRetryable: Bool,
        category: DiagnosticCategory,
        primaryCode: ValidationIssueCode? = nil
    ) {
        self.title = title
        self.message = message
        self.recovery = recovery
        self.isRetryable = isRetryable
        self.category = category
        self.primaryCode = primaryCode
    }

    // MARK: - From a thrown error

    /// Composes the explanation for an import that ended by throwing.
    ///
    /// A `ZynSignError` carries its own user-facing message, which is written
    /// to be shown directly and to contain nothing from its cause. Anything
    /// else is a failure ZynSign does not model; its text is never rendered,
    /// so a foreign error cannot leak a path or a provider identity into the
    /// interface.
    ///
    /// An `ImportFailure` thrown as an error — which the Import Hub's
    /// workflow does for refusals it has already explained — is returned
    /// unchanged.
    static func from(error: any Error) -> ImportFailure {
        if let failure = error as? ImportFailure {
            return failure
        }
        guard let zynSignError = error as? ZynSignError else {
            return ImportFailure(
                title: "Import Failed",
                message: "An unexpected problem ended the import.",
                recovery: .retry,
                isRetryable: true,
                category: .internalFailure
            )
        }
        return ImportFailure(
            title: Self.title(for: zynSignError.category),
            message: zynSignError.userMessage,
            recovery: Self.recovery(for: zynSignError.category),
            isRetryable: Self.permitsRetry(zynSignError.category),
            category: zynSignError.category
        )
    }

    // MARK: - From a refused package

    /// Composes the explanation for a package the inspection stage refused.
    ///
    /// The primary rejecting finding decides the wording; the code is kept so
    /// diagnostics and rules can read the machine-readable reason without
    /// parsing the sentence.
    static func from(validation: ValidationResult?) -> ImportFailure {
        let primary = validation?.errors.first
        return ImportFailure(
            title: "Package Refused",
            message: Self.message(for: primary?.code),
            recovery: .chooseAnotherFile,
            isRetryable: false,
            category: primary?.category ?? .invalidInput,
            primaryCode: primary?.code
        )
    }

    // MARK: - Vocabulary

    /// The user-facing explanation for one refusal code. Every code ZynSign
    /// can produce appears here; the wording describes what was wrong with
    /// the package and never how the check that refused it works.
    static func message(for code: ValidationIssueCode?) -> String {
        switch code {
        case .none:
            return "This file is not a valid application package."
        case .some(.unreadableArchive):
            return "The file could not be read as a package archive."
        case .some(.unsafePath), .some(.conflictingPaths):
            return "The package contains entries ZynSign cannot safely read."
        case .some(.missingPayloadDirectory), .some(.missingApplicationBundle):
            return "No application was found inside the package."
        case .some(.multipleApplicationBundles):
            return "The package contains more than one application, so it cannot be imported."
        case .some(.missingInfoPlist):
            return "The application inside the package is missing required information."
        case .some(.unreadableInfoPlist):
            return "The application's information file could not be read."
        case .some(.malformedMetadata), .some(.missingRequiredMetadata):
            return "The application's declared information is incomplete or malformed."
        case .some(.unsupportedMetadataFormat), .some(.unsupportedArchiveFeature):
            return "The package uses features ZynSign does not support."
        case .some(.resourceLimitExceeded):
            return "The package is larger or more complex than ZynSign can inspect."
        case .some(.inconsistentMetadata), .some(.missingExecutable):
            return "The application's declared information does not match its content."
        }
    }

    /// The headline for a failure category.
    private static func title(for category: DiagnosticCategory) -> String {
        switch category {
        case .invalidInput, .unsupportedInput, .ambiguousInput: return "Import Refused"
        case .capabilityUnavailable: return "Not Available"
        case .cancelled: return "Import Cancelled"
        case .storageFailure, .internalFailure: return "Import Failed"
        }
    }

    /// The suggested recovery for a failure category.
    private static func recovery(for category: DiagnosticCategory) -> Recovery {
        switch category {
        case .invalidInput, .unsupportedInput, .ambiguousInput: return .chooseAnotherFile
        case .capabilityUnavailable, .cancelled: return .none
        case .storageFailure: return .retry
        case .internalFailure: return .retry
        }
    }

    /// Whether a failure in `category` can plausibly end differently on a
    /// second attempt at the same file.
    ///
    /// Input that failed its own rules will fail them again, and a capability
    /// the platform does not provide will not appear; both are excluded.
    /// Storage and internal failures are included deliberately: a file
    /// provider may become reachable again after the file downloads, and a
    /// transient condition is exactly what a retry is for. The retry never
    /// changes the file — it re-runs the same, unmodified read.
    private static func permitsRetry(_ category: DiagnosticCategory) -> Bool {
        switch category {
        case .storageFailure, .internalFailure: return true
        case .invalidInput, .unsupportedInput, .ambiguousInput, .capabilityUnavailable, .cancelled: return false
        }
    }
}

// MARK: - Import Hub refusals

/// The Import Hub's workflow throws refusals it has already explained as
/// `ImportFailure`s, so the explanation travels to the item unchanged.
extension ImportFailure: Error {}

extension ImportFailure {

    /// The device does not have room for the import's working copy. Decided
    /// before anything is copied; freeing space and retrying can succeed.
    static func insufficientStorage(requiredBytes: Int, availableBytes: Int) -> ImportFailure {
        let required = ByteCountFormatter.string(fromByteCount: Int64(requiredBytes), countStyle: .file)
        let available = ByteCountFormatter.string(fromByteCount: Int64(max(0, availableBytes)), countStyle: .file)
        return ImportFailure(
            title: "Not Enough Space",
            message: "This import needs about \(required) of free space and \(available) is available. Nothing was copied.",
            recovery: .freeStorage,
            isRetryable: true,
            category: .storageFailure
        )
    }

    /// The file could not be read as an archive at all.
    static func corruptedArchive() -> ImportFailure {
        ImportFailure(
            title: "Package Refused",
            message: "The file is damaged or is not an archive ZynSign can read.",
            recovery: .chooseAnotherFile,
            isRetryable: false,
            category: .invalidInput,
            primaryCode: .unreadableArchive
        )
    }

    /// The archive holds no application package.
    static func archiveHasNoPackages() -> ImportFailure {
        ImportFailure(
            title: "Nothing to Import",
            message: "The archive doesn't contain an application package (.ipa).",
            recovery: .chooseAnotherFile,
            isRetryable: false,
            category: .invalidInput,
            primaryCode: .missingApplicationBundle
        )
    }

    /// The archive holds something recognisable that ZynSign does not
    /// import, with what to do instead.
    static func unsupportedLayout(_ layout: PackageContainerClassification.UnsupportedLayout) -> ImportFailure {
        let title: String
        let message: String
        switch layout {
        case .xcodeArchive:
            title = "Unsupported Layout"
            message = "This is an Xcode archive. Export it from Xcode as an .ipa, then import the .ipa."
        case .bareApplicationBundle:
            title = "Unsupported Layout"
            message = "This archive holds an .app bundle rather than an .ipa package. Package the app as an .ipa, then import it."
        case .nestedArchives:
            title = "Unsupported Layout"
            message = "This archive only contains other archives. ZynSign doesn't open archives inside archives — extract the inner archive first."
        case .certificateMaterial:
            title = "Certificates, Not Packages"
            message = "This archive holds signing certificates (.p12 / .mobileprovision), not packages. Extract it in Files, then import each file from Certificates & Profiles."
        }
        return ImportFailure(
            title: title,
            message: message,
            recovery: .chooseAnotherFile,
            isRetryable: false,
            category: .unsupportedInput
        )
    }

    /// The archive was refused outright because an entry could not be
    /// handled safely. Nothing was extracted from it.
    static func unsafeArchive(_ reason: PackageContainerClassification.UnsafeReason) -> ImportFailure {
        let message: String
        let code: ValidationIssueCode
        switch reason {
        case .unsafeEntryName:
            message = "The archive contains an entry whose name could place files outside the archive. ZynSign refused the whole archive and extracted nothing."
            code = .unsafePath
        case .duplicateEntries:
            message = "The archive lists the same entry more than once, so ZynSign can't tell which copy is real. Nothing was extracted."
            code = .conflictingPaths
        case .linkedPackage:
            message = "The archive contains a package that is a link rather than a file. ZynSign refused the archive and extracted nothing."
            code = .unsafePath
        }
        return ImportFailure(
            title: "Archive Refused",
            message: message,
            recovery: .chooseAnotherFile,
            isRetryable: false,
            category: .invalidInput,
            primaryCode: code
        )
    }

    /// The import was interrupted — ZynSign was closed or stopped — and it
    /// cannot resume: it keeps no way back to the original file.
    ///
    /// Without a working copy the file was never fully copied, so nothing
    /// was imported. With one that has since disappeared, the import may
    /// have been completing, so the explanation points at the library
    /// rather than claiming either outcome.
    static func interrupted(hadWorkingCopy: Bool) -> ImportFailure {
        ImportFailure(
            title: "Import Interrupted",
            message: hadWorkingCopy
                ? "ZynSign closed before this import finished, and its working copy is gone. If the app isn't in your library, add the file again. The original file was not changed."
                : "ZynSign closed before it finished copying this file. Nothing was imported and the original file was not changed. Add the file again to import it.",
            recovery: .chooseAnotherFile,
            isRetryable: false,
            category: .storageFailure
        )
    }
}
