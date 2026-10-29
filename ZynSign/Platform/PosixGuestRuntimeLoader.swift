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

    func activateSandboxEnvironment(
        guest: HostedGuestDescriptor,
        containerRoot: URL,
        guestBundleURL: URL,
        activeDataDirectory: URL
    ) throws {
        let tmpPath = activeDataDirectory.appendingPathComponent("tmp", isDirectory: true).path
        setenv("ZYNSIGN_GUEST_BUNDLE_ID", guest.bundleIdentifier, 1)
        setenv("ZYNSIGN_GUEST_BUNDLE_PATH", guestBundleURL.path, 1)
        setenv("ZYNSIGN_GUEST_CONTAINER_ROOT", containerRoot.path, 1)
        setenv("ZYNSIGN_GUEST_DATA_ROOT", activeDataDirectory.path, 1)
        setenv("ZYNSIGN_GUEST_TMPDIR", tmpPath, 1)
    }

    func probeGuestExecutable(at executableURL: URL, entrySymbol: String) -> GuestRuntimeProbeReport {
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
                : "Guest MH_DYLIB mapped cleanly; entry symbol '\(entrySymbol)' uses LC_MAIN offset."
        )
    }

    private func guestSummary(_ inspection: GuestMachOPatcher.GuestBinaryInspection) -> String {
        "MH_DYLIB · arm64"
    }
}
