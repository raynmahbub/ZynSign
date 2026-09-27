import Foundation
#if canImport(CoreText) && canImport(CoreGraphics)
import CoreText
import CoreGraphics
#endif

/// Safely registers in-memory font data into the process so SwiftUI can render live previews.
public enum CoreTextFontRegistrar {

    private static let lock = NSLock()
    private static var registeredFonts = Set<String>()

    /// Registers font data dynamically in memory. Returns the registered font name, or nil on failure.
    public static func registerFont(from data: Data) -> String? {
        #if canImport(CoreText) && canImport(CoreGraphics)
        guard !data.isEmpty else { return nil }
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        guard let cgFont = CGFont(provider) else { return nil }

        guard let psName = cgFont.postScriptName as String? else { return nil }

        lock.lock()
        defer { lock.unlock() }

        if registeredFonts.contains(psName) {
            return psName
        }

        var error: Unmanaged<CFError>?
        if CTFontManagerRegisterGraphicsFont(cgFont, &error) {
            registeredFonts.insert(psName)
            return psName
        } else {
            // Might already be registered
            registeredFonts.insert(psName)
            return psName
        }
        #else
        return nil
        #endif
    }
}
