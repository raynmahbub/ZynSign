import CommonCrypto
import Foundation

/// Normalizes Base64-wrapped JSON catalogs, `$...` / `source[...]` encoded
/// source tokens, AES-128-CBC encrypted repository feeds, and compact `down`
/// app records into ZynSign's canonical repository JSON schema before
/// `StoreManifestValidator` validates them.
enum EncodedCatalogPayloadDecoder {

    private static let primaryCipherKey: [UInt8] = [
        0x65, 0x73, 0x69, 0x67, 0x6E, 0x5F, 0x73, 0x6F,
        0x75, 0x72, 0x63, 0x65, 0x5F, 0x6B, 0x65, 0x79
    ]
    private static let secondaryCipherKey: [UInt8] = [
        0x47, 0x61, 0x79, 0x31, 0x31, 0x34, 0x35, 0x31,
        0x34, 0x31, 0x39, 0x31, 0x39, 0x38, 0x31, 0x30
    ]

    /// Decodes a raw manifest payload into canonical UTF-8 catalog JSON when
    /// Base64/AES-encoded or structured with compact `down` app entries.
    static func normalizeManifestPayload(_ raw: Data) -> Data {
        let unwrapped = unwrapEncodedBytes(raw) ?? raw
        guard let object = try? JSONSerialization.jsonObject(with: unwrapped, options: []),
              var root = object as? [String: Any] else {
            return unwrapped
        }
        guard normalizeCompactCatalogSchemaIfNeeded(&root),
              let reencoded = try? JSONSerialization.data(withJSONObject: root, options: []) else {
            return unwrapped
        }
        return reencoded
    }

    /// Decodes a single URL, multi-line URL list, or encoded `source[...]` token into HTTPS URLs.
    static func decodeSourceListText(_ text: String) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        if trimmed.lowercased().hasPrefix("https://") {
            return trimmed
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { $0.lowercased().hasPrefix("https://") }
        }

        var candidate = trimmed
        if candidate.hasPrefix("source["), candidate.hasSuffix("]source") {
            candidate = String(candidate.dropFirst(7).dropLast(7))
        } else if candidate.hasPrefix("source["), candidate.hasSuffix("]") {
            candidate = String(candidate.dropFirst(7).dropLast())
        } else if candidate.hasPrefix("$") {
            candidate = String(candidate.dropFirst())
        }

        if let data = Data(base64Encoded: candidate) {
            if let plain = String(data: data, encoding: .utf8), plain.contains("https://") {
                return extractHTTPSLines(from: plain)
            }
            for key in [secondaryCipherKey, primaryCipherKey] {
                if let dec = aes128CBCDecrypt(data, key: key, iv: key),
                   let plain = String(data: dec, encoding: .utf8),
                   plain.contains("https://") {
                    return extractHTTPSLines(from: plain)
                }
            }
        }
        return extractHTTPSLines(from: trimmed)
    }

    // MARK: - Internal Helpers

    private static func unwrapEncodedBytes(_ raw: Data) -> Data? {
        let trimmedText = String(data: raw, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let first = trimmedText?.first, first == "{" || first == "[" {
            return raw
        }
        guard var encoded = trimmedText, !encoded.isEmpty else { return nil }
        if encoded.hasPrefix("$") {
            encoded.removeFirst()
        }
        guard let cipher = Data(base64Encoded: encoded, options: [.ignoreUnknownCharacters]),
              !cipher.isEmpty else { return nil }
        if let directUTF8 = String(data: cipher, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           directUTF8.hasPrefix("{") {
            return cipher
        }
        for key in [secondaryCipherKey, primaryCipherKey] {
            if let decrypted = aes128CBCDecrypt(cipher, key: key, iv: key),
               let check = String(data: decrypted, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               check.hasPrefix("{") {
                return decrypted
            }
        }
        return nil
    }

    private static func normalizeCompactCatalogSchemaIfNeeded(_ root: inout [String: Any]) -> Bool {
        guard var apps = root["apps"] as? [[String: Any]] else { return false }
        var changed = false
        for index in apps.indices {
            var app = apps[index]
            if app["downloadURL"] == nil, let down = app["down"] as? String {
                app["downloadURL"] = down
                changed = true
            }
            if app["versions"] == nil,
               let version = app["version"] as? String,
               let downloadURL = app["downloadURL"] as? String {
                var entry: [String: Any] = [
                    "version": version,
                    "downloadURL": downloadURL
                ]
                if let date = app["versionDate"] as? String {
                    entry["date"] = date
                }
                if let desc = app["versionDescription"] as? String {
                    entry["localizedDescription"] = desc
                }
                if let size = app["size"] {
                    entry["size"] = size
                }
                app["versions"] = [entry]
                changed = true
            }
            apps[index] = app
        }
        if changed {
            root["apps"] = apps
        }
        return changed
    }

    private static func extractHTTPSLines(from text: String) -> [String] {
        let separators = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",;|\"'"))
        var seen: Set<String> = []
        var urls: [String] = []
        for token in text.components(separatedBy: separators) {
            let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.lowercased().hasPrefix("https://"),
                  URL(string: trimmed) != nil else { continue }
            if seen.insert(trimmed).inserted {
                urls.append(trimmed)
            }
        }
        return urls
    }

    private static func aes128CBCDecrypt(_ cipher: Data, key: [UInt8], iv: [UInt8]) -> Data? {
        guard key.count == kCCKeySizeAES128, iv.count == kCCBlockSizeAES128, !cipher.isEmpty else {
            return nil
        }
        let capacity = cipher.count + kCCBlockSizeAES128
        var buffer = Data(count: capacity)
        var decryptedLength: size_t = 0
        let status = buffer.withUnsafeMutableBytes { outPtr in
            cipher.withUnsafeBytes { inPtr in
                CCCrypt(
                    CCOperation(kCCDecrypt),
                    CCAlgorithm(kCCAlgorithmAES),
                    CCOptions(kCCOptionPKCS7Padding),
                    key,
                    key.count,
                    iv,
                    inPtr.baseAddress,
                    cipher.count,
                    outPtr.baseAddress,
                    capacity,
                    &decryptedLength
                )
            }
        }
        guard status == kCCSuccess else { return nil }
        buffer.count = decryptedLength
        return buffer
    }
}
