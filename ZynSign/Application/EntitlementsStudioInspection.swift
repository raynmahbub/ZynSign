import Foundation

struct EntitlementStudioTarget: Equatable, Identifiable {
    let id: Int
    let name: String
    let entitlements: CodeSigningEntitlements?
    let note: String
}

/// Reads only the declared main executable. Never extracts, follows a link,
/// edits a signature, or substitutes profile claims for app requests.
enum EntitlementsStudioInspection {
    static let maximumExecutableBytes = 64 * 1024 * 1024

    static func inspect(reader: any ArchiveReader, executableName: String?, parser: any MachOParsing) throws -> [EntitlementStudioTarget] {
        guard let executableName, BundlePath.isValidComponent(executableName) else {
            throw EntitlementsError.notRepresentable
        }
        let table = try reader.readEntryTable()
        guard case .exactlyOne(let bundle) = ApplicationBundleDiscovery.discover(in: table).outcome,
              let path = ArchivePath(rawValue: bundle.rawValue + "/" + executableName) else {
            throw EntitlementsError.notRepresentable
        }
        let entries = table.filter { $0.path == path }
        guard entries.count == 1, entries.first?.kind == .regularFile else {
            throw EntitlementsError.notRepresentable
        }
        try Task.checkCancellation()
        let bytes = try reader.readEntryData(at: path, maximumBytes: maximumExecutableBytes)
        let image = try parser.parse(bytes)
        return try image.slices.enumerated().map { index, slice in
            try Task.checkCancellation()
            let metadata = EmbeddedSigningMetadataInspector().inspect(slice: slice, artifact: bytes)
            let name = "Architecture \(index + 1) · \(String(describing: slice.header.cpu))"
            switch metadata.entitlements {
            case .present(let entitlements):
                let slot = metadata.entitlementsSource == .der ? "DER (slot 7)" : "XML (slot 5)"
                let disagreement = metadata.entitlementSlotsDisagree
                    ? " The XML (slot 5) and DER (slot 7) slots decode to different claim sets; the XML claims are shown. A signature this app produces encodes both from one dictionary, so treat the difference as a fact worth investigating."
                    : ""
                return .init(id: index, name: name, entitlements: entitlements,
                             note: "Decoded \(slot) entitlement claims from the main executable, architecture \(index + 1) of \(image.slices.count).\(disagreement) No signature integrity or platform authorization is inferred. Inspect each architecture separately.")
            case .absent:
                return .init(id: index, name: name, entitlements: nil,
                             note: "No entitlement slot was found in this architecture — neither XML (slot 5) nor DER (slot 7). The executable may be unsigned. Missing claims are unknown, not a verified empty set.")
            case .malformed:
                let slot = metadata.entitlementsSource == .der ? "DER (slot 7)" : "XML (slot 5)"
                return .init(id: index, name: name, entitlements: nil,
                             note: "The embedded \(slot) entitlement blob could not be decoded. No empty set has been substituted. Re-import an intact package or inspect its signature.")
            }
        }
    }

    static func readProfileFile(_ url: URL) throws -> Data {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        guard ["mobileprovision", "provisionprofile"].contains(url.pathExtension.lowercased()),
              let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size > 0, size <= 10 * 1024 * 1024 else { throw EntitlementsError.payloadTooLarge }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: size + 1) ?? Data()
        guard data.count == size, data.count <= 10 * 1024 * 1024 else { throw EntitlementsError.payloadTooLarge }
        return data
    }

    /// Strict payload extraction. No scanning for XML markers and no fallback
    /// that mistakes an arbitrary entitlement plist for a provisioning profile.
    static func parseProfile(_ data: Data) throws -> ProvisioningProfile {
        guard !data.isEmpty, data.count <= 10 * 1024 * 1024 else { throw EntitlementsError.payloadTooLarge }
        let payload: Data
        if let cms = try? CMSStructureReader.read(data), let content = cms.encapsulatedContent {
            payload = content
        } else {
            payload = data
        }
        let profile = try PropertyListProvisioningProfileParser().parse(ProvisioningProfilePayload(plistData: payload))
        guard profile.uuid != nil || profile.teamIdentifiers != nil || profile.applicationIdentifier != nil else {
            throw EntitlementsError.notRepresentable
        }
        return profile
    }
}
