import Foundation

/// Reads one application bundle's declared metadata from the content of its
/// bundle information file.
///
/// The reader is pure: its input is one untrusted byte blob — the content of
/// a bundle's information file — and it knows nothing about archives,
/// filesystems, paths, or where the bytes came from. Content access happens
/// outside it, through the archive boundary, and the bytes it receives are
/// treated exactly like any other hostile input: parsed with the platform's
/// property-list facility, interpreted fail-closed, and never trusted. The
/// reader makes no authenticity claims; its outcome is a record of what the
/// bundle declares, never evidence that the bundle is signed, genuine, or
/// installable.
///
/// Extraction and validation stay distinct inside the reader. Extraction
/// determines which declared values are present; validation determines
/// whether they satisfy the supported domain rules. Absent optional values
/// are `nil`, not errors. A present value with an unacceptable type, or a
/// required value that is missing or unacceptable, is an error. Failure is
/// deterministic: fields are examined in a fixed order and the first problem
/// found wins, so one input always produces the same single finding.
struct ApplicationMetadataReader {

    /// Reads the metadata declared by one bundle information file.
    ///
    /// The outcome carries either the extracted metadata with no findings, or
    /// `nil` metadata with the single finding behind the failure.
    static func read(from infoPlistData: Data) -> ApplicationMetadataExamination {
        var format = PropertyListSerialization.PropertyListFormat.openStep
        let root: Any
        do {
            root = try PropertyListSerialization.propertyList(
                from: infoPlistData,
                options: [],
                format: &format
            )
        } catch {
            return failedExamination(
                code: .unreadableInfoPlist,
                detail: "The bundle information file could not be parsed as a property list (cause: \(Self.causeSummary(error)))."
            )
        }

        guard format != .openStep else {
            return failedExamination(
                code: .unsupportedMetadataFormat,
                detail: "The bundle information file uses an OpenStep property list, which ZynSign does not support."
            )
        }

        guard let rootDictionary = root as? [String: Any] else {
            return failedExamination(
                code: .unreadableInfoPlist,
                detail: "The bundle information file's root is \(Self.observedTypeName(of: root)) rather than a dictionary."
            )
        }

        return Self.extract(from: rootDictionary)
    }

    // MARK: - Extraction and validation

    private static func extract(from root: [String: Any]) -> ApplicationMetadataExamination {
        // Required: the bundle identifier. It must be present, a string,
        // non-empty, and valid under ZynSign's identifier rules. There is no
        // fallback, no invention, and no transformation of a missing value.
        guard let identifierValue = root[BundleInformationKeys.bundleIdentifier] else {
            return failedExamination(
                code: .missingRequiredMetadata,
                detail: "The bundle information file declares no '\(BundleInformationKeys.bundleIdentifier)'."
            )
        }
        guard let identifierString = identifierValue as? String else {
            return failedExamination(
                code: .malformedMetadata,
                detail: Self.wrongTypeMessage(key: BundleInformationKeys.bundleIdentifier, expected: "a string", observed: identifierValue)
            )
        }
        guard !identifierString.isEmpty else {
            return failedExamination(
                code: .malformedMetadata,
                detail: "The bundle information file declares an empty '\(BundleInformationKeys.bundleIdentifier)'."
            )
        }
        guard let bundleIdentifier = BundleIdentifier(rawValue: identifierString) else {
            return failedExamination(
                code: .malformedMetadata,
                detail: "The declared bundle identifier '\(Self.diagnosticValue(identifierString))' does not satisfy ZynSign's bundle identifier rules."
            )
        }

        // Optional declared strings. Absent values stay nil; present values
        // must be strings and are preserved exactly.
        let displayName = Self.declaredString(root, BundleInformationKeys.displayName)
        if let failure = displayName.failure { return failedExamination(failure) }
        let bundleName = Self.declaredString(root, BundleInformationKeys.bundleName)
        if let failure = bundleName.failure { return failedExamination(failure) }
        let shortVersion = Self.declaredString(root, BundleInformationKeys.shortVersion)
        if let failure = shortVersion.failure { return failedExamination(failure) }
        let buildVersion = Self.declaredString(root, BundleInformationKeys.buildVersion)
        if let failure = buildVersion.failure { return failedExamination(failure) }
        let minimumOSVersion = Self.declaredString(root, BundleInformationKeys.minimumOSVersion)
        if let failure = minimumOSVersion.failure { return failedExamination(failure) }
        let iconName = Self.declaredString(root, BundleInformationKeys.iconName)
        if let failure = iconName.failure { return failedExamination(failure) }

        // The executable name is interpreted, not merely preserved: it names
        // a file the bundle is expected to carry, so it must be a safe single
        // path component. An empty declaration conveys no executable and is
        // treated as absent.
        var executableName: String?
        if let executableValue = root[BundleInformationKeys.executable] {
            guard let executableString = executableValue as? String else {
                return failedExamination(
                    code: .malformedMetadata,
                    detail: Self.wrongTypeMessage(key: BundleInformationKeys.executable, expected: "a string", observed: executableValue)
                )
            }
            if !executableString.isEmpty {
                guard !executableString.contains("/"), ArchivePath(rawValue: executableString) != nil else {
                    return failedExamination(
                        code: .malformedMetadata,
                        detail: "The declared '\(BundleInformationKeys.executable)' '\(Self.diagnosticValue(executableString))' is not a safe single path component."
                    )
                }
                executableName = executableString
            }
        }

        // Device families. Absent stays nil; a present value must be an array
        // of integers. Elements outside ZynSign's known set are preserved.
        var deviceFamily: [ApplicationDeviceFamily]?
        if let familyValue = root[BundleInformationKeys.deviceFamily] {
            guard let familyValues = familyValue as? [Any] else {
                return failedExamination(
                    code: .malformedMetadata,
                    detail: Self.wrongTypeMessage(key: BundleInformationKeys.deviceFamily, expected: "an array of integers", observed: familyValue)
                )
            }
            var families: [ApplicationDeviceFamily] = []
            for (index, element) in familyValues.enumerated() {
                guard let rawValue = element as? Int else {
                    return failedExamination(
                        code: .malformedMetadata,
                        detail: "The '\(BundleInformationKeys.deviceFamily)' entry at index \(index) is \(Self.observedTypeName(of: element)) rather than an integer."
                    )
                }
                families.append(ApplicationDeviceFamily.interpret(rawValue: rawValue))
            }
            deviceFamily = families
        }

        let identity = ApplicationIdentity(
            bundleIdentifier: bundleIdentifier,
            declaredDisplayName: displayName.value,
            declaredBundleName: bundleName.value,
            shortVersionString: shortVersion.value,
            buildVersion: buildVersion.value
        )
        let metadata = ApplicationMetadata(
            identity: identity,
            executableName: executableName,
            minimumOSVersion: minimumOSVersion.value,
            deviceFamily: deviceFamily,
            iconName: iconName.value
        )
        return succeededExamination(metadata)
    }

    // MARK: - Outcomes

    private static func succeededExamination(_ metadata: ApplicationMetadata) -> ApplicationMetadataExamination {
        ApplicationMetadataExamination(metadata: metadata, findings: [])
    }

    private static func failedExamination(_ finding: ValidationFinding) -> ApplicationMetadataExamination {
        ApplicationMetadataExamination(metadata: nil, findings: [finding])
    }

    private static func failedExamination(code: ValidationIssueCode, detail: String) -> ApplicationMetadataExamination {
        failedExamination(ValidationFinding(severity: .error, code: code, detail: detail))
    }

    // MARK: - Field interpretation

    /// Reads one optional declared string field. An absent key yields a nil
    /// value and no failure; a present key whose recorded value is not a
    /// string yields the failure that ends the examination.
    private static func declaredString(
        _ root: [String: Any],
        _ key: String
    ) -> (value: String?, failure: ValidationFinding?) {
        guard let value = root[key] else {
            return (nil, nil)
        }
        guard let string = value as? String else {
            let finding = ValidationFinding(
                severity: .error,
                code: .malformedMetadata,
                detail: Self.wrongTypeMessage(key: key, expected: "a string", observed: value)
            )
            return (nil, finding)
        }
        return (string, nil)
    }

    private static func wrongTypeMessage(key: String, expected: String, observed: Any) -> String {
        "The bundle information file declares '\(key)' as \(Self.observedTypeName(of: observed)) rather than \(expected)."
    }

    /// A log-safe rendering of one declared value for a diagnostic: control
    /// characters are replaced so they cannot forge log structure, and long
    /// values are truncated so one hostile value cannot dominate a report.
    private static func diagnosticValue(_ value: String, maximumLength: Int = 60) -> String {
        let sanitized = value.map { character in
            character.isControl ? "\u{FFFD}" : character
        }
        let text = String(sanitized)
        guard text.count > maximumLength else {
            return text
        }
        return String(text.prefix(maximumLength)) + "…"
    }

    /// The diagnostic name of the type an unexpected value actually carries.
    /// Diagnostic context only: it never echoes value content.
    private static func observedTypeName(of value: Any) -> String {
        if let number = value as? NSNumber {
            // Property-list numbers and booleans all arrive as NSNumber, and
            // an NSNumber casts successfully to several Swift numeric types,
            // so `is` checks cannot tell an integer from a boolean. The
            // number's own recorded type can: a property-list boolean is
            // recorded as a character, any other integral type is an integer,
            // and the remainder are real numbers.
            switch CFNumberGetType(number as CFNumber) {
            case .char: return "a boolean"
            case .sInt8, .sInt16, .sInt32, .sInt64, .cInt, .cLong, .cLongLong, .cfIndex:
                return "an integer"
            default: return "a number"
            }
        }
        switch value {
        case is String: return "a string"
        case is [Any]: return "an array"
        case is [String: Any]: return "a dictionary"
        case is [AnyHashable: Any]: return "a dictionary with non-string keys"
        case is Data: return "a data value"
        case is Date: return "a date"
        default: return "a value of a type ZynSign does not model"
        }
    }

    /// A bounded, log-safe summary of a parse failure's cause: an identifier
    /// and a code for platform errors, a type name for everything else. The
    /// cause's own text is never copied, because it may carry implementation
    /// detail this layer should not reproduce.
    private static func causeSummary(_ error: any Error) -> String {
        if let cocoaError = error as? NSError {
            return "\(cocoaError.domain), code \(cocoaError.code)"
        }
        return String(describing: type(of: error))
    }
}

/// The outcome of reading one bundle's declared metadata.
///
/// Either the extracted metadata with no findings, or `nil` metadata with the
/// single finding behind the failure. Like every examination outcome in
/// ZynSign, it is data rather than an exception: the caller decides what a
/// failed examination means for the artifact under examination.
struct ApplicationMetadataExamination: Equatable, Hashable {

    /// The extracted metadata, or `nil` when extraction failed.
    let metadata: ApplicationMetadata?

    /// The findings behind the outcome: empty on success, exactly one error
    /// on failure.
    let findings: [ValidationFinding]

    /// Whether extraction produced a complete metadata record.
    var isValid: Bool {
        metadata != nil && findings.isEmpty
    }
}

/// The bundle information file keys ZynSign's first metadata model reads.
///
/// ZynSign reads a deliberately small, stable set of keys. Every other key in
/// a bundle's information file is ignored: unknown keys must not break
/// extraction, and the first metadata model is a curated record, not a
/// general property-list viewer.
enum BundleInformationKeys {

    /// The bundle identifier, required for a valid metadata record.
    static let bundleIdentifier = "CFBundleIdentifier"

    /// The user-facing display name.
    static let displayName = "CFBundleDisplayName"

    /// The short bundle name, the display name's fallback.
    static let bundleName = "CFBundleName"

    /// The marketing version string.
    static let shortVersion = "CFBundleShortVersionString"

    /// The build version string.
    static let buildVersion = "CFBundleVersion"

    /// The name of the bundle's executable.
    static let executable = "CFBundleExecutable"

    /// The minimum OS version the bundle declares.
    static let minimumOSVersion = "MinimumOSVersion"

    /// The device families the bundle declares support for.
    static let deviceFamily = "UIDeviceFamily"

    /// The application icon name.
    static let iconName = "CFBundleIconName"
}
