import Foundation

/// Pure-Swift extractor for downloadable `.ipa` / `.tipa` URLs from direct links,
/// `itms-services://?action=download-manifest&url=...` OTA install links, OTA
/// `manifest.plist` documents, and HTML release / download pages.
enum DownloadLinkExtractor {

    struct DiscoveredLink: Equatable, Hashable, Sendable, Identifiable {
        let id: String
        let title: String
        let url: URL
        let kind: Kind

        init(title: String, url: URL, kind: Kind) {
            self.id = url.absoluteString
            self.title = title
            self.url = url
            self.kind = kind
        }

        enum Kind: String, Equatable, Hashable, Sendable {
            case directPackage = "Direct IPA/TIPA"
            case otaManifest = "OTA Manifest"
        }
    }

    enum ExtractionStep: Equatable, Sendable {
        case directPackage(URL)
        case fetchOTAManifest(URL)
        case scanWebPage(URL)
    }

    /// Classifies user-pasted input into a direct package URL, an OTA manifest
    /// plist fetch, or a web-page HTML scan.
    static func classifyInput(_ raw: String) -> ExtractionStep? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.lowercased().hasPrefix("itms-services://"),
           let components = URLComponents(string: trimmed),
           let manifestParam = components.queryItems?.first(where: { $0.name.lowercased() == "url" })?.value,
           let manifestURL = URL(string: manifestParam),
           manifestURL.scheme?.lowercased() == "https" {
            return .fetchOTAManifest(manifestURL)
        }

        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" else {
            return nil
        }
        let ext = url.pathExtension.lowercased()
        if ext == "ipa" || ext == "tipa" {
            return .directPackage(url)
        }
        if ext == "plist" {
            return .fetchOTAManifest(url)
        }
        return .scanWebPage(url)
    }

    /// Scans free-form text or multi-line snippets for direct `.ipa`/`.tipa` or `itms-services://` links.
    static func extractDirectLinks(from rawText: String) -> [DiscoveredLink] {
        let tokens = rawText.components(separatedBy: CharacterSet.whitespacesAndNewlines)
        var seen: Set<String> = []
        var found: [DiscoveredLink] = []
        for token in tokens {
            let cleaned = token.trimmingCharacters(in: CharacterSet(charactersIn: "\"'<>"))
            guard let step = classifyInput(cleaned) else { continue }
            switch step {
            case .directPackage(let pkgURL):
                if seen.insert(pkgURL.absoluteString).inserted {
                    found.append(DiscoveredLink(title: pkgURL.lastPathComponent, url: pkgURL, kind: .directPackage))
                }
            case .fetchOTAManifest(let manifestURL):
                if seen.insert(manifestURL.absoluteString).inserted {
                    found.append(DiscoveredLink(title: manifestURL.lastPathComponent, url: manifestURL, kind: .otaManifest))
                }
            case .scanWebPage:
                break
            }
        }
        return found
    }

    /// Extracts the `software-package` HTTPS `.ipa` URL from an Apple OTA `manifest.plist`.
    static func extractFromOTAManifest(_ plistData: Data) -> [DiscoveredLink] {
        guard let root = (try? PropertyListSerialization.propertyList(from: plistData, options: [], format: nil)) as? [String: Any],
              let items = root["items"] as? [[String: Any]] else {
            return []
        }
        var results: [DiscoveredLink] = []
        for item in items {
            let meta = item["metadata"] as? [String: Any]
            let title = (meta?["title"] as? String) ?? "OTA Package"
            let assets = (item["assets"] as? [[String: Any]]) ?? []
            for asset in assets {
                let kind = (asset["kind"] as? String) ?? ""
                guard kind == "software-package" || kind.isEmpty,
                      let urlString = asset["url"] as? String,
                      let url = URL(string: urlString),
                      url.scheme?.lowercased() == "https" else { continue }
                results.append(DiscoveredLink(title: title, url: url, kind: .directPackage))
            }
        }
        return results
    }

    /// Scans HTML markup for `.ipa`, `.tipa`, and `itms-services://` href targets.
    static func extractFromHTML(_ html: String, baseURL: URL) -> [DiscoveredLink] {
        let pattern = "href\\s*=\\s*[\"']([^\"']+)[\"']"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return []
        }
        let nsRange = NSRange(html.startIndex..<html.endIndex, in: html)
        let matches = regex.matches(in: html, options: [], range: nsRange)

        var seen: Set<String> = []
        var found: [DiscoveredLink] = []
        for match in matches where match.numberOfRanges >= 2 {
            guard let range = Range(match.range(at: 1), in: html) else { continue }
            let rawHref = String(html[range]).replacingOccurrences(of: "&amp;", with: "&")
            if rawHref.lowercased().hasPrefix("itms-services://"),
               case .fetchOTAManifest(let manifestURL)? = classifyInput(rawHref) {
                if seen.insert(manifestURL.absoluteString).inserted {
                    found.append(DiscoveredLink(
                        title: manifestURL.lastPathComponent,
                        url: manifestURL,
                        kind: .otaManifest
                    ))
                }
                continue
            }
            guard let resolved = URL(string: rawHref, relativeTo: baseURL)?.absoluteURL,
                  resolved.scheme?.lowercased() == "https" else { continue }
            let ext = resolved.pathExtension.lowercased()
            guard ext == "ipa" || ext == "tipa" else { continue }
            if seen.insert(resolved.absoluteString).inserted {
                let name = resolved.lastPathComponent.removingPercentEncoding ?? resolved.lastPathComponent
                found.append(DiscoveredLink(title: name, url: resolved, kind: .directPackage))
            }
        }
        return found
    }
}
