import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// POSIX `dlopen` / `dlsym` & sandbox environment coordinator for ZynSign's
/// Host Container runtime.
struct PosixGuestRuntimeLoader: GuestRuntimeLoading {

    var isBundledLoaderPresent: Bool {
        if let frameworksURL = Bundle.main.privateFrameworksURL {
            let candidate = frameworksURL.appendingPathComponent(GuestContainer.Layout.loaderName)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return true
            }
        }
        if let resourceURL = Bundle.main.resourceURL {
            let candidate = resourceURL.appendingPathComponent(GuestContainer.Layout.loaderName)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return true
            }
        }
        return false
    }

    // The host process shares its environment across all threads. This lock
    // serializes ZynSign probes, but cannot isolate guest code or other writers.
    private static let environmentLock = NSRecursiveLock()

    func probeGuestExecutable(
        at executableURL: URL,
        entrySymbol: String,
        guest: HostedGuestDescriptor,
        containerRoot: URL,
        guestBundleURL: URL,
        activeDataDirectory: URL
    ) throws -> GuestRuntimeProbeReport {
        Self.environmentLock.lock()
        defer { Self.environmentLock.unlock() }
        let values = [
            ("ZYNSIGN_GUEST_BUNDLE_ID", guest.bundleIdentifier),
            ("ZYNSIGN_GUEST_BUNDLE_PATH", guestBundleURL.path),
            ("ZYNSIGN_GUEST_CONTAINER_ROOT", containerRoot.path),
            ("ZYNSIGN_GUEST_DATA_ROOT", activeDataDirectory.path),
            ("ZYNSIGN_GUEST_TMPDIR", activeDataDirectory.appendingPathComponent("tmp", isDirectory: true).path),
        ]
        let previous: [(String, String?)] = values.map { key, _ in
            (key, getenv(key).map { String(cString: $0) })
        }
        defer {
            for (key, value) in previous {
                if let value { _ = setenv(key, value, 1) }
                else { _ = unsetenv(key) }
            }
        }
        for (key, value) in values {
            guard setenv(key, value, 1) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
        guard FileManager.default.fileExists(atPath: executableURL.path) else {
            return GuestRuntimeProbeReport(
                imageLoadable: false,
                entrySymbolFound: false,
                diagnosticMessage: "Staged executable was not found at \(executableURL.lastPathComponent)."
            )
        }
        // Validate MH_DYLIB header before invoking dyld so malformed images are refused cleanly.
        guard let bytes = try? Data(contentsOf: executableURL),
              let inspection = GuestMachOPatcher.inspectCandidateBinary(bytes),
              inspection.headerFileType == GuestMachOPatcher.mhDylib else {
            return GuestRuntimeProbeReport(
                imageLoadable: false,
                entrySymbolFound: false,
                diagnosticMessage: "Executable is not patched to MH_DYLIB yet."
            )
        }

        // Probe dlopen in local/lazy mode without taking over UIApplicationMain while the host UI is active.
        guard let handle = dlopen(executableURL.path, RTLD_LAZY | RTLD_LOCAL) else {
            let reason = dlerror().map { String(cString: $0) } ?? "dyld refused image"
            return GuestRuntimeProbeReport(
                imageLoadable: false,
                entrySymbolFound: false,
                diagnosticMessage: "Container staged (\(guestSummary(inspection))), dyld probe: \(reason)"
            )
        }
        defer { dlclose(handle) }

        let sym = dlsym(handle, entrySymbol)
        return GuestRuntimeProbeReport(
            imageLoadable: true,
            entrySymbolFound: sym != nil,
            diagnosticMessage: sym != nil
                ? "Guest MH_DYLIB mapped cleanly and entry symbol '\(entrySymbol)' resolved."
                : "Guest MH_DYLIB mapped, but entry symbol '\(entrySymbol)' was not found; no launch was performed."
        )
    }

    private func guestSummary(_ inspection: GuestMachOPatcher.GuestBinaryInspection) -> String {
        "MH_DYLIB · arm64"
    }
}
