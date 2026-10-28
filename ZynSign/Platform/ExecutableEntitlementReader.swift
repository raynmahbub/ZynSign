import Foundation

/// Reads what this build was granted from the executable's own embedded
/// signature.
///
/// The only route that works on iOS. `SecTask` — the API that answers this
/// question on macOS — is not exposed by the iOS Security overlay at all, so a
/// build cannot ask the system "what am I entitled to?" and must instead read
/// the answer it already carries: the entitlements blob inside its own code
/// signature. That is the same data the system would consult, read with the
/// parser the rest of the app already trusts.
///
/// Reading is bounded and read-only. Nothing is written, no hash is computed,
/// and no signature is judged — the bytes are parsed for one dictionary of
/// claims and the file handle is closed.
///
/// **The four states it can report.**
///
/// | Executable | Result |
/// | --- | --- |
/// | readable, signature carries claims | `isMeasured == true`, keys recorded |
/// | readable, no entitlements slot | `.unmeasured` — absence is not evidence here |
/// | readable, not a Mach-O | `.unmeasured` |
/// | unreadable, oversized, or missing | `.unmeasured` |
///
/// The middle two are deliberate. A simulator build carries a signature whose
/// claims say nothing about what a distribution build would be granted, and a
/// file this reader cannot parse is not a file that grants nothing. Both are
/// "not established", which the screen states in words.
struct ExecutableEntitlementReader: ProcessEntitlementReading {

    /// The bound on how much of the executable is read. Larger than any real
    /// application binary this app inspects, and the same order as the
    /// Entitlements Studio's read bound.
    static let maximumExecutableBytes = 64 * 1_024 * 1_024

    /// The executable to read. Defaults to the running application's own.
    private let executableURL: URL?

    init(executableURL: URL? = Bundle.main.executableURL) {
        self.executableURL = executableURL
    }

    func read() -> ProcessEntitlements {
        guard let url = executableURL else { return .unmeasured }
        return EntitlementsReader(url: url).read()
    }

    /// The read itself, split out so the URL policy stays a one-liner.
    private struct EntitlementsReader {
        let url: URL

        func read() -> ProcessEntitlements {
            guard let bytes = executableBytes() else { return .unmeasured }
            guard let image = try? ReadOnlyMachOParser().parse(bytes) else { return .unmeasured }

            // Any slice that carries claims speaks for the build. A universal
            // binary's slices are signed together and must agree; the first one
            // that decodes is enough to answer this question, and a slice that
            // does not decode is not evidence about the others.
            var claims: CodeSigningEntitlements?
            for slice in image.slices {
                let metadata = EmbeddedSigningMetadataInspector().inspect(slice: slice, artifact: bytes)
                if case .present(let decoded) = metadata.entitlements {
                    claims = decoded
                    break
                }
            }
            guard let claims else { return .unmeasured }
            return ProcessEntitlements(claims: claims)
        }

        private func executableBytes() -> Data? {
            guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  size > 0, size <= ExecutableEntitlementReader.maximumExecutableBytes else {
                return nil
            }
            return try? Data(contentsOf: url, options: .mappedIfSafe)
        }
    }
}

private extension ProcessEntitlements {
    /// Translates a decoded claim set into the four facts the screen shows.
    ///
    /// A claim set this build carries is `isMeasured`, even when none of the
    /// probed keys is among it: the signature was read, and the answer "none of
    /// these four" is a real answer.
    init(claims: CodeSigningEntitlements) {
        var granted: Set<String> = []
        for key in ProcessEntitlements.probedKeys where claims[key] != nil {
            granted.insert(key)
        }
        self.init(
            isMeasured: true,
            grantedKeys: granted,
            applicationIdentifier: claims.string(for: ProcessEntitlements.applicationIdentifierKey),
            teamIdentifier: claims.string(for: ProcessEntitlements.teamIdentifierKey)
        )
    }
}

private extension CodeSigningEntitlements {
    /// One claim's text value, or `nil` when it is absent or not a string.
    func string(for key: String) -> String? {
        guard case .string(let value)? = self[key] else { return nil }
        return value
    }
}
