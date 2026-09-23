import Foundation
import XCTest
@testable import ZynSign

// MARK: - Table and request fixtures

/// Builds the entry tables, requests, and observations nested-code tests work
/// with.
///
/// Every value is a synthetic literal: names, identifiers, and versions are
/// invented, and no real application appears anywhere. The helpers exist so
/// that a test states the structure it means — which directories, which files,
/// which kinds — rather than repeating the payload scaffolding.
enum NestedCodeFixtures {

    /// The entry table of a package whose payload holds one application
    /// bundle, followed by the supplied bundle-relative entries.
    ///
    /// The caller passes `Payload/Example.app/...` names, so a test reads as
    /// the bundle it describes.
    static func packageTable(
        bundleName: String = "Example.app",
        entries: [ArchiveEntry] = []
    ) -> [ArchiveEntry] {
        [
            makeEntry(IPALayout.payloadDirectoryName, kind: .directory),
            makeEntry("\(IPALayout.payloadDirectoryName)/\(bundleName)", kind: .directory),
        ] + entries
    }

    /// The request the application layer builds for the standard synthetic
    /// package: the bundle's location plus the declared identity a library
    /// record would hold.
    static func request(
        bundleName: String = "Example.app",
        executableName: String? = "Example",
        bundleIdentifier: String = "com.example.synthetic",
        shortVersion: String? = "1.2",
        buildVersion: String? = "34"
    ) -> NestedCodeDiscoveryRequest {
        NestedCodeDiscoveryRequest(
            bundlePath: makePath("\(IPALayout.payloadDirectoryName)/\(bundleName)"),
            applicationIdentity: identity(
                bundleIdentifier: bundleIdentifier,
                executableName: executableName,
                shortVersion: shortVersion,
                buildVersion: buildVersion
            )
        )
    }

    /// A declared identity with the supplied values.
    static func identity(
        bundleIdentifier: String? = "com.example.synthetic.frame",
        executableName: String? = nil,
        packageType: String? = nil,
        shortVersion: String? = nil,
        buildVersion: String? = nil
    ) -> NestedCodeBundleIdentity {
        var identifier: BundleIdentifier?
        if let bundleIdentifier {
            identifier = BundleIdentifier(rawValue: bundleIdentifier)
            if identifier == nil {
                preconditionFailure("Test fixture bundle identifier is not valid: \(bundleIdentifier)")
            }
        }
        return NestedCodeBundleIdentity(
            bundleIdentifier: identifier,
            executableName: executableName,
            packageType: packageType,
            shortVersionString: shortVersion,
            buildVersion: buildVersion
        )
    }

    /// A one-architecture arm64 summary, shaped like the summary a thin
    /// inspection produces.
    static func thinSummary() -> NestedCodeMachOSummary {
        NestedCodeMachOSummary(
            container: .thin,
            slices: [
                NestedCodeMachOSummary.Slice(
                    cpu: .arm64,
                    cpuSubtype: 0,
                    fileType: 2,
                    wordSize: .bits64,
                    byteOrder: .littleEndian
                )
            ]
        )
    }

    /// A two-architecture summary, shaped like the summary a universal
    /// inspection produces.
    static func universalSummary() -> NestedCodeMachOSummary {
        NestedCodeMachOSummary(
            container: .universal,
            slices: [
                NestedCodeMachOSummary.Slice(
                    cpu: .arm64,
                    cpuSubtype: 0,
                    fileType: 2,
                    wordSize: .bits64,
                    byteOrder: .littleEndian
                ),
                NestedCodeMachOSummary.Slice(
                    cpu: .x86_64,
                    cpuSubtype: 3,
                    fileType: 2,
                    wordSize: .bits64,
                    byteOrder: .littleEndian
                ),
            ]
        )
    }

    /// An inspection reporting Mach-O structure and no signature.
    static func unsignedMachO(isUniversal: Bool = false) -> NestedCodeBinaryInspection {
        NestedCodeBinaryInspection(
            observation: .machO(summary: isUniversal ? universalSummary() : thinSummary()),
            existingSignature: .absent
        )
    }

    /// An inspection reporting Mach-O structure whose signature parsed.
    static func signedMachO(isUniversal: Bool = false) -> NestedCodeBinaryInspection {
        NestedCodeBinaryInspection(
            observation: .machO(summary: isUniversal ? universalSummary() : thinSummary()),
            existingSignature: .structurallyParsed(signedSliceCount: isUniversal ? 2 : 1)
        )
    }

    /// An inspection reporting bytes that are not a Mach-O image.
    static var notMachO: NestedCodeBinaryInspection {
        NestedCodeBinaryInspection(observation: .notMachO)
    }

    /// An inspection reporting a structurally unusable Mach-O image.
    static func malformedMachO(
        _ reason: MachOParsingError.Reason = .malformedHeader,
        at boundary: MachOParsingError.Boundary = .header
    ) -> NestedCodeBinaryInspection {
        NestedCodeBinaryInspection(
            observation: .malformed(MachOParsingError(reason, at: boundary))
        )
    }

    /// An inspection reporting a recognized Mach-O form this build does not
    /// model.
    static func unsupportedMachO(
        _ reason: MachOParsingError.Reason = .unsupportedCodeDirectoryVersion,
        at boundary: MachOParsingError.Boundary = .codeDirectory
    ) -> NestedCodeBinaryInspection {
        NestedCodeBinaryInspection(
            observation: .unsupported(MachOParsingError(reason, at: boundary))
        )
    }

    /// An inspection reporting content that could not be produced.
    static var unreadableBinary: NestedCodeBinaryInspection {
        NestedCodeBinaryInspection(observation: .unreadable)
    }
}

// MARK: - Item fixtures

/// Builds one nested-code item for dependency and ordering tests.
///
/// The default is an established Mach-O item whose executable sits directly
/// inside its own container, which is the shape the bundle structure produces.
func makeNestedCodeItem(
    kind: NestedCodeKind,
    location: String,
    executablePath: String? = nil,
    parentID: NestedCodeItemID? = nil,
    status: NestedCodeItemStatus = .established,
    bundleIdentifier: String? = nil,
    identity executableName: String? = nil,
    isUniversal: Bool = false
) -> NestedCodeItem {
    let bundlePath = makeBundlePath(location)
    var resolvedExecutable: BundlePath?
    if let executablePath {
        resolvedExecutable = makeBundlePath(executablePath)
    } else if kind != .dynamicLibrary {
        resolvedExecutable = bundlePath.appending(component: kind.defaultExecutableName)
    }
    // The default identifier is derived from the location so that two
    // fixtures built without an explicit identifier never accidentally
    // declare the same one, which the graph validation would report.
    let identity = NestedCodeFixtures.identity(
        bundleIdentifier: bundleIdentifier ?? fixtureIdentifier(for: bundlePath),
        executableName: executableName
    )
    let information: NestedCodeBundleInformation = kind.isBundleBacked
        ? .read(identity)
        : .notPresent
    return NestedCodeItem(
        id: NestedCodeItemID(kind: kind, location: bundlePath),
        kind: kind,
        bundlePath: bundlePath,
        executablePath: resolvedExecutable,
        executableProvenance: resolvedExecutable == nil ? nil : .declared,
        bundleInformation: information,
        binary: .machO(summary: isUniversal
            ? NestedCodeFixtures.universalSummary()
            : NestedCodeFixtures.thinSummary()),
        existingSignature: .absent,
        parentID: parentID,
        status: status
    )
}

/// A syntactically valid fixture identifier derived from one bundle path, so
/// that distinct fixtures declare distinct identifiers.
private func fixtureIdentifier(for path: BundlePath) -> String {
    let components = path.components.compactMap { component -> String? in
        var result = ""
        for character in component {
            let permitted = character.isASCII && (character.isLetter || character.isNumber)
            if permitted {
                result.append(character)
            } else if !result.hasSuffix(".") {
                result.append(".")
            }
        }
        while result.hasSuffix(".") {
            result.removeLast()
        }
        return result.isEmpty ? nil : result
    }
    return "com.example.fixture" + components.map { ".\($0)" }.joined()
}

/// A validated bundle path from a literal name.
func makeBundlePath(_ name: String) -> BundlePath {
    guard let path = BundlePath(rawValue: name) else {
        preconditionFailure("Test fixture used an unsafe bundle path: \(name)")
    }
    return path
}

private extension NestedCodeKind {

    /// The executable name the platform's convention gives a container of
    /// this kind, used only to build fixtures.
    var defaultExecutableName: String {
        switch self {
        case .application: return "Example"
        case .framework: return "Frame"
        case .applicationExtension: return "Widget"
        case .dynamicLibrary: return "Frame"
        }
    }
}

// MARK: - Inspection source double

/// A `NestedCodeInspectionSource` that answers from prepared observations and
/// records what discovery asked for.
///
/// It exists so that the domain rule can be exercised exhaustively without a
/// container: a test states exactly what is at each location, and the double
/// reports the locations discovery actually asked about — which is what the
/// "reads only candidates" and "reads nothing it did not name" properties are
/// checked with.
final class SyntheticNestedCodeInspectionSource: NestedCodeInspectionSource {

    private var binariesByPath: [String: NestedCodeBinaryInspection]
    private var informationByContainer: [String: NestedCodeBundleInformation]

    /// The binary locations discovery asked about, in order.
    private(set) var requestedBinaryPaths: [ArchivePath] = []

    /// The container locations discovery asked about, in order.
    private(set) var requestedInformationPaths: [ArchivePath] = []

    /// How many reads the source was asked to perform.
    var requestedReadCount: Int {
        requestedBinaryPaths.count + requestedInformationPaths.count
    }

    init(
        binaries: [String: NestedCodeBinaryInspection] = [:],
        information: [String: NestedCodeBundleInformation] = [:]
    ) {
        self.binariesByPath = binaries
        self.informationByContainer = information
    }

    func bundleInformation(
        ofContainerAt path: ArchivePath,
        maximumBytes: Int
    ) -> NestedCodeBundleInformation {
        requestedInformationPaths.append(path)
        return informationByContainer[path.rawValue] ?? .notPresent
    }

    func binary(
        at path: ArchivePath,
        declaredByteCount: Int?,
        maximumBytes: Int
    ) -> NestedCodeBinaryInspection {
        requestedBinaryPaths.append(path)
        return binariesByPath[path.rawValue] ?? .unevaluated
    }
}
