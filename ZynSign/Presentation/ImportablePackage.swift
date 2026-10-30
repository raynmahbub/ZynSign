import Foundation
import SwiftUI
import UniformTypeIdentifiers
#if canImport(UIKit)
import UIKit
#endif

/// The document-picker content types for ZynSign's package import, in one
/// place for every screen that opens the picker.
///
/// The types are derived from the same file-type policy the import use case
/// enforces (`IPAFileFormat`). The picker restricts the user's choice; it is
/// still not trusted as evidence about content — the use case re-checks the
/// file it is handed.
enum ImportablePackage {

    /// The content types the system document picker offers.
    static var contentTypes: [UTType] {
        var types: Set<UTType> = []
        for ext in IPAFileFormat.acceptedPathExtensions {
            if let dynamic = UTType(filenameExtension: ext, conformingTo: .data) {
                types.insert(dynamic)
            }
            if let dynamicZIP = UTType(filenameExtension: ext, conformingTo: .zip) {
                types.insert(dynamicZIP)
            }
            if let dynamicArchive = UTType(filenameExtension: ext, conformingTo: .archive) {
                types.insert(dynamicArchive)
            }
            if let fallback = UTType(filenameExtension: ext) {
                types.insert(fallback)
            }
        }
        types.insert(.data)
        types.insert(.zip)
        if #available(iOS 15.0, *) {
            types.insert(.archive)
        }
        types.insert(.item)
        if let itunesIPA = UTType("com.apple.itunes.ipa") {
            types.insert(itunesIPA)
        }
        if let itunesIPAPackage = UTType("com.apple.itunes.ipa-package") {
            types.insert(itunesIPAPackage)
        }
        if let zynSignTIPA = UTType("io.zynsign.tipa") {
            types.insert(zynSignTIPA)
        }
        return Array(types)
    }

    /// Content types for provisioning profile pickers (`.mobileprovision` /
    /// `.provisionprofile`), including broad `.data` / `.item` fallbacks so
    /// Files never dims valid profiles downloaded from Safari or third-party
    /// providers.
    static var profileContentTypes: [UTType] {
        var types: Set<UTType> = [.data, .item]
        for ext in ["mobileprovision", "provisionprofile"] {
            if let dynamic = UTType(filenameExtension: ext) {
                types.insert(dynamic)
            }
            if let dynamicData = UTType(filenameExtension: ext, conformingTo: .data) {
                types.insert(dynamicData)
            }
        }
        if let declared = UTType("com.apple.mobileprovision") {
            types.insert(declared)
        }
        if let osxDeclared = UTType("com.apple.provisionprofile") {
            types.insert(osxDeclared)
        }
        return Array(types)
    }

    /// Content types for tweak and dynamic library pickers (`.deb` / `.dylib`).
    static var tweakContentTypes: [UTType] {
        var types: Set<UTType> = [.data, .item, .archive]
        for ext in ["deb", "dylib"] {
            if let dynamic = UTType(filenameExtension: ext) {
                types.insert(dynamic)
            }
            if let dynamicData = UTType(filenameExtension: ext, conformingTo: .data) {
                types.insert(dynamicData)
            }
        }
        if let deb = UTType("org.debian.deb-archive") {
            types.insert(deb)
        }
        return Array(types)
    }
}

/// Stabilizes external or picker-provided file URLs into an application-owned
/// temporary staging directory while security-scoped access is active.
enum PickedDocumentStaging {

    static func stabilize(_ url: URL) -> URL {
        guard url.isFileURL else { return url }
        let fileManager = FileManager.default
        let baseRoot = fileManager.temporaryDirectory
            .appendingPathComponent("ZynSign-PickedDocuments", isDirectory: true)
        if url.path.hasPrefix(baseRoot.path) {
            return url
        }

        let scopeAcquired = url.startAccessingSecurityScopedResource()
        defer {
            if scopeAcquired {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let slot = baseRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileName = url.lastPathComponent.isEmpty ? "ImportedItem" : url.lastPathComponent
        let destination = slot.appendingPathComponent(fileName, isDirectory: false)
        do {
            try fileManager.createDirectory(at: slot, withIntermediateDirectories: true)
            try fileManager.copyItem(at: url, to: destination)
            return destination
        } catch {
            return url
        }
    }

    static func stabilizeAll(_ urls: [URL]) -> [URL] {
        pruneExpired()
        return urls.map(stabilize)
    }

    static func pruneExpired(maxAge: TimeInterval = 3_600) {
        let fileManager = FileManager.default
        let baseRoot = fileManager.temporaryDirectory
            .appendingPathComponent("ZynSign-PickedDocuments", isDirectory: true)
        guard let children = try? fileManager.contentsOfDirectory(
            at: baseRoot,
            includingPropertiesForKeys: [.creationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        let cutoff = Date().addingTimeInterval(-maxAge)
        for child in children {
            let created = (try? child.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            if created < cutoff {
                try? fileManager.removeItem(at: child)
            }
        }
    }
}

#if canImport(UIKit)
/// Native UIKit document picker configured with `asCopy: true`.
///
/// Opening with `asCopy: true` delegates copying and iCloud materialization to
/// the out-of-process system document manager, then stabilizes each copy into
/// `ZynSign-PickedDocuments` before returning from the delegate callback so
/// downstream async tasks never encounter expired security scopes or reaped
/// picker inbox files.
struct ZDocumentPicker: UIViewControllerRepresentable {

    let contentTypes: [UTType]
    var allowsMultipleSelection: Bool = false
    let onPick: @MainActor ([URL]) -> Void
    var onCancel: (@MainActor () -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick, onCancel: onCancel)
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let types = contentTypes.isEmpty ? [.item, .data] : contentTypes
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: true)
        picker.allowsMultipleSelection = allowsMultipleSelection
        picker.shouldShowFileExtensions = true
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {
        context.coordinator.onPick = onPick
        context.coordinator.onCancel = onCancel
    }

    @MainActor
    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        var onPick: @MainActor ([URL]) -> Void
        var onCancel: (@MainActor () -> Void)?

        init(
            onPick: @escaping @MainActor ([URL]) -> Void,
            onCancel: (@MainActor () -> Void)?
        ) {
            self.onPick = onPick
            self.onCancel = onCancel
        }

        func documentPicker(
            _ controller: UIDocumentPickerViewController,
            didPickDocumentsAt urls: [URL]
        ) {
            let stabilized = PickedDocumentStaging.stabilizeAll(urls)
            onPick(stabilized)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onCancel?()
        }
    }
}
#endif
