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
        let fallbackSourceName: String = {
            if let existing = (root["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !existing.isEmpty {
                return existing
            }
            if let identifier = (root["identifier"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !identifier.isEmpty {
                return identifier
            }
            return "Community Repository"
        }()
        if (root["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            root["name"] = fallbackSourceName
            changed = true
        }

        var seenBundles = Set<String>()
        var normalizedApps: [[String: Any]] = []
        normalizedApps.reserveCapacity(apps.count)

        for index in apps.indices {
            var app = apps[index]
            if app["bundleIdentifier"] == nil, let bundleID = app["bundleID"] as? String {
                app["bundleIdentifier"] = bundleID
                changed = true
            }
            if app["downloadURL"] == nil, let down = app["down"] as? String {
                app["downloadURL"] = down
                changed = true
            }
            if app["iconURL"] == nil, let icon = app["icon"] as? String {
                app["iconURL"] = icon
                changed = true
            }
            if app["developerName"] == nil, let dev = app["dev"] as? String {
                app["developerName"] = dev
                changed = true
            }
            if (app["developerName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                app["developerName"] = fallbackSourceName
                changed = true
            }
            if normalizeByteSizeField(&app, key: "size") {
                changed = true
            }
            if (app["versionDate"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true,
               app["versionDate"] != nil {
                app.removeValue(forKey: "versionDate")
                changed = true
            }
            if app["screenshotURLs"] == nil, let altScreenshots = extractAltStoreScreenshots(from: app["screenshots"]) {
                app["screenshotURLs"] = altScreenshots
                changed = true
            }
            if var versions = app["versions"] as? [[String: Any]] {
                var seenVersions = Set<String>()
                var cleanedVersions: [[String: Any]] = []
                for var ver in versions {
                    if ver["downloadURL"] == nil, let down = ver["down"] as? String {
                        ver["downloadURL"] = down
                        changed = true
                    }
                    if normalizeByteSizeField(&ver, key: "size") {
                        changed = true
                    }
                    if (ver["date"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true,
                       ver["date"] != nil {
                        ver.removeValue(forKey: "date")
                        changed = true
                    }
                    if let vStr = ver["version"] as? String {
                        if seenVersions.insert(vStr).inserted {
                            cleanedVersions.append(ver)
                        } else {
                            changed = true
                        }
                    } else {
                        cleanedVersions.append(ver)
                    }
                }
                if cleanedVersions.count != versions.count || changed {
                    versions = cleanedVersions
                    app["versions"] = versions
                }
            } else if let version = app["version"] as? String,
                      let downloadURL = app["downloadURL"] as? String {
                var entry: [String: Any] = [
                    "version": version,
                    "downloadURL": downloadURL
                ]
                if let date = (app["versionDate"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !date.isEmpty {
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

            if let bundleID = (app["bundleIdentifier"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !bundleID.isEmpty {
                if seenBundles.insert(bundleID).inserted {
                    normalizedApps.append(app)
                } else {
                    changed = true
                }
            } else {
                normalizedApps.append(app)
            }
        }

        if let featured = root["featuredApps"] as? [String] {
            let validFeatured = featured.filter { seenBundles.contains($0) }
            if validFeatured.count != featured.count {
                root["featuredApps"] = validFeatured
                changed = true
            }
        }

        if changed {
            apps = normalizedApps
            root["apps"] = apps
        }
        return changed
    }

    private static func normalizeByteSizeField(_ dict: inout [String: Any], key: String) -> Bool {
        guard let raw = dict[key] else { return false }
        if let intVal = raw as? Int64 {
            if intVal <= 0 {
                dict.removeValue(forKey: key)
                return true
            }
            return false
        }
        if let num = raw as? NSNumber {
            let intVal = num.int64Value
            if intVal <= 0 {
                dict.removeValue(forKey: key)
                return true
            }
            return false
        }
        if let str = raw as? String {
            let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
            if let parsed = Int64(trimmed), parsed > 0 {
                dict[key] = parsed
            } else {
                dict.removeValue(forKey: key)
            }
            return true
        }
        return false
    }

    private static func extractAltStoreScreenshots(from value: Any?) -> [String]? {
        if let list = value as? [Any] {
            let urls = list.compactMap { item -> String? in
                if let str = item as? String { return str }
                if let dict = item as? [String: Any] { return dict["imageURL"] as? String }
                return nil
            }
            return urls.isEmpty ? nil : urls
        }
        if let grouped = value as? [String: Any] {
            var collected: [String] = []
            for key in ["iphone", "ipad"] {
                if let nested = extractAltStoreScreenshots(from: grouped[key]) {
                    collected.append(contentsOf: nested)
                }
            }
            return collected.isEmpty ? nil : collected
        }
        return nil
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
