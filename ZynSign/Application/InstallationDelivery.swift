import Foundation

/// Failures raised while preparing an installation delivery hand-off.
///
/// The cases are structural: they name the requirement that was not met,
/// never the contents that were refused. `userMessage` is the only text a
/// screen shows; it carries no URL, path, or identifier.
enum InstallationDeliveryError: Error, Equatable {
    /// The operator-supplied hosting location was not `https`. Over-the-air
    /// installation requires an HTTPS manifest; a local file URL cannot
    /// serve one.
    case hostingURLMustBeHTTPS

    /// The operator-supplied hosting location was not a URL the platform
    /// could parse at all.
    case hostingURLUnparsable

    /// The manifest property list could not be serialized.
    case manifestSerializationFailed

    /// The shareable manifest file could not be written to the delivery
    /// workspace.
    case manifestWriteFailed

    /// One sentence a screen can show for each failure. Fixed text.
    var userMessage: String {
        switch self {
        case .hostingURLMustBeHTTPS:
            return "The hosting address must use HTTPS. Over-the-air installation accepts only an HTTPS manifest."
        case .hostingURLUnparsable:
            return "The hosting address is not a valid web address. Enter the full address the installing device can reach."
        case .manifestSerializationFailed:
            return "The delivery manifest could not be produced."
        case .manifestWriteFailed:
            return "The delivery manifest could not be written for sharing."
        }
    }
}

/// The signed package an operator will deliver.
///
/// Everything here is display or manifest data read from things ZynSign
/// already established: the pipeline's verified output file and the
/// library record the signing run started from. No signature, profile, or
/// entitlement material is carried.
struct InstallationDeliveryPackage: Equatable {

    /// The signed container's file name, as it appears in `Documents/Signed`.
    let fileName: String

    /// The signed container's location in the application container.
    let fileURL: URL

    /// The application's declared display name, for the manifest title.
    let displayName: String

    /// The application's declared bundle identifier, for the manifest.
    let bundleIdentifier: String

    /// The application's declared marketing version, for the manifest.
    let bundleVersion: String

    /// The declared build version, when the record carries one.
    let buildVersion: String?

    /// Builds the delivery description of a pipeline-signed output for the
    /// library record it came from. The file name and URL come from the
    /// pipeline's output; the identity fields come from the record.
    init(signedIPA url: URL, record: ApplicationRecord) {
        self.fileName = url.lastPathComponent
        self.fileURL = url
        self.displayName = record.displayName ?? record.bundleIdentifier.rawValue
        self.bundleIdentifier = record.bundleIdentifier.rawValue
        self.bundleVersion = record.identity.shortVersionString ?? "1.0"
        self.buildVersion = record.identity.buildVersion
    }

    /// Builds the delivery description of an export for the workspace's
    /// delivery flow. The identity fields are the ones the export captured
    /// when the artifact was committed, so delivering stays possible after
    /// the library entry is gone.
    init(export: ExportRecord, fileURL: URL) {
        self.fileName = export.fileName
        self.fileURL = fileURL
        self.displayName = export.displayName
        self.bundleIdentifier = export.bundleIdentifier
        self.bundleVersion = export.shortVersion ?? export.buildVersion ?? "1.0"
        self.buildVersion = export.buildVersion
    }

    /// The size of the signed container in bytes, or `nil` when the file
    /// cannot currently be reached.
    var fileSizeBytes: Int64? {
        guard let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey]),
              let fileSize = values.fileSize else { return nil }
        return Int64(fileSize)
    }
}

/// The over-the-air installation manifest for one signed package.
///
/// The structure is Apple's documented `manifest.plist` shape for the
/// `itms-services` protocol. ZynSign produces the document and the
/// ready-to-paste install link; it never hosts, serves, or installs
/// anything — the operator publishes both files and the device does the
/// installing.
struct InstallationDeliveryManifest: Equatable {

    /// The HTTPS URL where the operator will publish the signed IPA.
    let softwarePackageURL: URL

    /// The manifest document's own HTTPS URL, referenced by the install link.
    let manifestURL: URL

    /// The application's declared bundle identifier.
    let bundleIdentifier: String

    /// The application's declared marketing version.
    let bundleVersion: String

    /// The title the installer shows.
    let displayName: String

    /// The manifest document as a property-list tree, in Apple's shape.
    var propertyList: [String: Any] {
        [
            "items": [
                [
                    "assets": [
                        [
                            "kind": "software-package",
                            "url": softwarePackageURL.absoluteString
                        ]
                    ],
                    "metadata": [
                        "bundle-identifier": bundleIdentifier,
                        "bundle-version": bundleVersion,
                        "kind": "software",
                        "title": displayName
                    ]
                ]
            ]
        ]
    }

    /// The manifest document serialized as XML property-list data.
    func xmlData() throws -> Data {
        do {
            return try PropertyListSerialization.data(
                fromPropertyList: propertyList,
                format: .xml,
                options: 0
            )
        } catch {
            throw InstallationDeliveryError.manifestSerializationFailed
        }
    }

    /// The `itms-services` install link for this manifest. The manifest URL
    /// is carried as a single percent-encoded query value, so the link can
    /// be pasted anywhere.
    var installLink: URL? {
        var components = URLComponents()
        components.scheme = "itms-services"
        components.queryItems = [
            URLQueryItem(name: "action", value: "download-manifest"),
            URLQueryItem(name: "url", value: manifestURL.absoluteString)
        ]
        return components.url
    }
}

/// Prepares an operator-assisted delivery for a signed package.
///
/// This service is the honest answer to "install": ZynSign still cannot
/// install anything — `InstallationCapabilityAssessment` keeps reporting
/// `noDeliveryMechanism` — but an operator with a hosting location, an MDM
/// relationship, or a host tool can deliver a signed IPA themselves, and
/// ZynSign can make that hand-off one-tap instead of manual. The service
/// produces a manifest, an install link, and a QR code; it never hosts,
/// uploads, contacts a server, or claims an installation outcome.
struct InstallationDeliveryService {

    /// Validates the operator-supplied hosting location.
    ///
    /// Over-the-air installation requires the manifest — and by convention
    /// the package — to be served over HTTPS. A local file URL is refused:
    /// it cannot be reached by the installing device, and pretending
    /// otherwise would produce a link that silently fails off-device.
    func validateHostingURL(_ raw: String) throws -> URL {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme != nil else {
            throw InstallationDeliveryError.hostingURLUnparsable
        }
        guard url.scheme?.lowercased() == "https" else {
            throw InstallationDeliveryError.hostingURLMustBeHTTPS
        }
        return url
    }

    /// Builds the manifest for a package the operator will publish at the
    /// validated hosting location. `manifestURL` is where the operator will
    /// publish the manifest document itself.
    func manifest(
        for package: InstallationDeliveryPackage,
        packageURL: URL,
        manifestURL: URL
    ) throws -> InstallationDeliveryManifest {
        _ = try validateHostingURL(packageURL.absoluteString)
        _ = try validateHostingURL(manifestURL.absoluteString)
        return InstallationDeliveryManifest(
            softwarePackageURL: packageURL,
            manifestURL: manifestURL,
            bundleIdentifier: package.bundleIdentifier,
            bundleVersion: package.bundleVersion,
            displayName: package.displayName
        )
    }

    /// Writes the manifest document into the temporary delivery workspace
    /// for sharing. The workspace follows the same convention as the
    /// certificate export: `tmp/ZynSign-Delivery/`, a location the system
    /// may purge and nothing durable depends on.
    func writeManifest(_ manifest: InstallationDeliveryManifest) throws -> URL {
        let data = try manifest.xmlData()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZynSign-Delivery", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("manifest.plist", isDirectory: false)
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            throw InstallationDeliveryError.manifestWriteFailed
        }
    }
}

/// The delivery channels an operator can use, with honest steps for each.
///
/// ZynSign performs none of these steps on the operator's behalf; the
/// channel list exists so the hand-off screen says exactly what remains
/// outside the app instead of implying a completed install.
enum InstallationDeliveryChannel: String, CaseIterable {
    case overTheAir
    case mobileDeviceManagement
    case hostTool

    var title: String {
        switch self {
        case .overTheAir: return "Over-the-Air (itms-services)"
        case .mobileDeviceManagement: return "MDM"
        case .hostTool: return "Host Tooling"
        }
    }

    /// One-sentence summary of the channel. Fixed text, redacted.
    var summary: String {
        switch self {
        case .overTheAir:
            return "Publish the IPA and manifest on your own HTTPS server; the device installs from the link."
        case .mobileDeviceManagement:
            return "Distribute the signed IPA through your organisation's device-management relationship."
        case .hostTool:
            return "Install the signed IPA from a computer with Finder (macOS) or Apple Configurator."
        }
    }

    /// The steps the operator performs outside ZynSign, in order. Fixed
    /// text — no URL, path, or identifier appears here.
    var steps: [String] {
        switch self {
        case .overTheAir:
            return [
                "Share the signed IPA out of Documents/Signed and upload it to your HTTPS host.",
                "Upload the generated manifest.plist beside it, at the manifest URL you entered.",
                "Open the itms-services link or scan the QR code on the target device.",
                "Confirm the install prompt on the device. ZynSign never sees this outcome.",
                "The device must trust the signing certificate (Settings → General → VPN & Device Management) and the server's TLS certificate must be trusted by the device."
            ]
        case .mobileDeviceManagement:
            return [
                "Share the signed IPA out of Documents/Signed.",
                "Add it as an in-house or custom app in your MDM solution.",
                "Assign it to devices or users and let the MDM deliver it.",
                "Delivery and installation status live in the MDM console, not in ZynSign."
            ]
        case .hostTool:
            return [
                "Share the signed IPA out of Documents/Signed to your computer.",
                "Drag it into Apple Configurator, or drop it on the Finder device pane.",
                "Confirm the install on the device.",
                "The host tool reports the outcome; ZynSign makes no statement about it."
            ]
        }
    }

    /// The requirement most often missed for this channel. Fixed text.
    var requirement: String {
        switch self {
        case .overTheAir:
            return "Requires HTTPS hosting the device trusts, and a signature the device accepts."
        case .mobileDeviceManagement:
            return "Requires an MDM relationship; in-house distribution requires an Apple Developer Enterprise Program role."
        case .hostTool:
            return "Requires a computer and a cable; free-provisioning limits still apply on the device."
        }
    }
}
