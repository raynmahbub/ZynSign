import Foundation

/// A bounded, read-only snapshot of the keys in one bundle's Info.plist.
///
/// Values are rendered to short, inert descriptions at the inspection
/// boundary. The snapshot never carries an arbitrary property-list object
/// into SwiftUI, and binary data values are represented by their byte count
/// rather than exposed as content.
struct InfoPlistKeyValue: Equatable, Hashable, Identifiable {
    let key: String
    let valueDescription: String

    var id: String { key }
}

/// The aggregate archive facts the details screen can show without
/// extracting or modifying the package.
struct ArchiveCompressionSummary: Equatable, Hashable {
    enum State: String, Equatable, Hashable {
        case compressed
        case noNetCompression
        case unknown

        var displayName: String {
            switch self {
            case .compressed: return "Compressed"
            case .noNetCompression: return "No net compression"
            case .unknown: return "Unknown"
            }
        }
    }

    let entryCount: Int
    let compressedByteCount: Int
    let uncompressedByteCount: Int

    var state: State {
        guard entryCount > 0 else { return .unknown }
        return compressedByteCount < uncompressedByteCount ? .compressed : .noNetCompression
    }
}

/// One framework, library, extension, or nested application found by name
/// and location inside the inspected application bundle.
///
/// This summary is structural only. It does not open or load the component,
/// and a familiar bundle suffix is not evidence that the component is valid.
struct ApplicationBundleComponent: Equatable, Hashable, Identifiable {
    enum Kind: String, Equatable, Hashable {
        case framework
        case dynamicLibrary
        case appExtension
        case nestedApplication

        var displayName: String {
            switch self {
            case .framework: return "Framework"
            case .dynamicLibrary: return "Dynamic Library"
            case .appExtension: return "App Extension"
            case .nestedApplication: return "Nested Application"
            }
        }
    }

    let path: BundlePath
    let kind: Kind
    let extensionPointIdentifier: String?

    var id: String { "\(kind.rawValue):\(path.rawValue)" }
    var name: String { path.name ?? path.rawValue }

    /// WidgetKit and legacy widget extension identifiers are recognized from
    /// the extension's own Info.plist declaration. Nothing is inferred from
    /// its display name.
    var isWidget: Bool {
        guard kind == .appExtension else { return false }
        return extensionPointIdentifier == "com.apple.widgetkit-extension"
            || extensionPointIdentifier == "com.apple.widget-extension"
    }
}

/// Detected nested code and extension bundles. Lists are kept separately so
/// the inspector can show counts first and expand each category on demand.
struct ApplicationBundleComponentSummary: Equatable, Hashable {
    let frameworks: [ApplicationBundleComponent]
    let dynamicLibraries: [ApplicationBundleComponent]
    let appExtensions: [ApplicationBundleComponent]
    let nestedApplications: [ApplicationBundleComponent]
    let uninspectedExtensionCount: Int

    var widgets: [ApplicationBundleComponent] {
        appExtensions.filter(\.isWidget)
    }

    static let empty = ApplicationBundleComponentSummary(
        frameworks: [],
        dynamicLibraries: [],
        appExtensions: [],
        nestedApplications: [],
        uninspectedExtensionCount: 0
    )
}

/// How the main executable's signature structure appeared to the bounded
/// Mach-O parser. A `signed` result means a signature structure was found;
/// it does not mean a cryptographic signature or trust chain was verified.
enum MainExecutableSignatureState: Equatable, Hashable {
    case signed
    case unsigned
    case partiallySigned
    case malformed
    case notInspected(MainExecutableInspectionLimit)

    var displayName: String {
        switch self {
        case .signed: return "Signed"
        case .unsigned: return "Unsigned"
        case .partiallySigned: return "Partially Signed"
        case .malformed: return "Malformed Signature"
        case .notInspected: return "Not Inspected"
        }
    }
}

/// Why ZynSign did not draw a signature-structure conclusion about the
/// main executable. These are inspection limits or input-read outcomes, not
/// statements that a signature is invalid.
enum MainExecutableInspectionLimit: String, Equatable, Hashable {
    case missingExecutable
    case exceedsReadLimit
    case unreadable
    case notMachO
    case malformedMachO

    var explanation: String {
        switch self {
        case .missingExecutable: return "The declared executable could not be found as a regular file in the bundle."
        case .exceedsReadLimit: return "The executable is larger than the bounded read ZynSign uses for this summary."
        case .unreadable: return "The executable could not be read within the archive's inspection policy."
        case .notMachO: return "The declared executable is not a Mach-O image ZynSign recognizes."
        case .malformedMachO: return "The executable's Mach-O structure could not be parsed safely."
        }
    }
}

/// A signature-structure and architecture summary for the main executable.
struct MainExecutableInspection: Equatable, Hashable {
    let signatureState: MainExecutableSignatureState
    let architectureNames: [String]
    let unsupportedArchitectureNames: [String]
    let hasDeviceArchitecture: Bool
}

/// The severity of one structured app-detail diagnostic.
enum ApplicationInspectionDiagnosticSeverity: String, Equatable, Hashable {
    case success
    case warning
    case error
    case unsupported

    var displayName: String {
        switch self {
        case .success: return "Success"
        case .warning: return "Warning"
        case .error: return "Error"
        case .unsupported: return "Unsupported"
        }
    }
}

/// One presentation-ready diagnostic produced by app details inspection.
///
/// The stable code and severity are separate from the copy shown to the
/// user, so presentation never has to infer meaning from diagnostic prose.
struct ApplicationInspectionDiagnostic: Equatable, Hashable, Identifiable {
    let code: String
    let title: String
    let detail: String
    let severity: ApplicationInspectionDiagnosticSeverity

    var id: String { "\(severity.rawValue):\(code):\(title):\(detail)" }
}

/// Everything the App Details screen can establish from an imported IPA
/// using bounded, read-only archive inspection.
struct ApplicationDetailsInspectionReport: Equatable {
    let bundlePath: ArchivePath?
    let bundleContents: BundleContents?
    let metadata: ApplicationMetadata?
    let infoPlistEntries: [InfoPlistKeyValue]
    let omittedInfoPlistEntryCount: Int
    let bundleType: String?
    let supportedPlatforms: [String]
    let omittedSupportedPlatformCount: Int
    let archive: ArchiveCompressionSummary
    let components: ApplicationBundleComponentSummary
    let executable: MainExecutableInspection?
    let validationClassification: ValidationClassification
    let diagnostics: [ApplicationInspectionDiagnostic]
}
