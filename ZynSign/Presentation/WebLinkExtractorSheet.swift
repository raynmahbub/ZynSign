import SwiftUI
import UIKit

/// Web Page & OTA `itms-services` Link Scanner for `.ipa` & `.tipa`
/// downloads without requiring an embedded `WKWebView` (keeping Presentation free of `WebKit`).
struct WebLinkExtractorSheet: View {
    let onQueueURL: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var inputText = ""
    @State private var isScanning = false
    @State private var candidates: [DownloadLinkExtractor.DiscoveredLink] = []
    @State private var statusMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $inputText)
                        .font(ZTypography.codeCaption)
                        .frame(minHeight: 90)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    HStack(spacing: ZSpacing.sm) {
                        Button {
                            if let clip = UIPasteboard.general.string { inputText = clip }
                        } label: {
                            Label("Paste", systemImage: "doc.on.clipboard")
                                .frame(minHeight: 44)
                        }
                        Spacer()
                        Button {
                            Task { await scanInput() }
                        } label: {
                            Label(isScanning ? "Scanning…" : "Scan Links", systemImage: "magnifyingglass.circle.fill")
                                .frame(minHeight: 44)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isScanning)
                    }
                } header: {
                    Text("Web Page URL, OTA Link, or HTML Snippet")
                } footer: {
                    Text("Extracts .ipa, .tipa, and Apple OTA manifest.plist download links from release pages, itms-services:// URLs, or pasted text.")
                }

                if let statusMessage {
                    Section {
                        Text(statusMessage).font(ZTypography.caption).foregroundStyle(.secondary)
                    }
                }

                if !candidates.isEmpty {
                    Section("Discovered Packages (\(candidates.count))") {
                        ForEach(candidates) { item in
                            HStack(spacing: ZSpacing.sm) {
                                Image(systemName: item.kind == .otaManifest ? "doc.badge.gearshape" : "app.badge")
                                    .foregroundStyle(Color.accentColor)
                                VStack(alignment: .leading, spacing: ZSpacing.xxs) {
                                    Text(item.title).font(ZTypography.subheadline).lineLimit(1)
                                    Text(item.url.absoluteString)
                                        .font(ZTypography.codeCaption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                                Spacer()
                                Button("Queue") {
                                    onQueueURL(item.url.absoluteString)
                                    ZHaptics.success()
                                }
                                .buttonStyle(.bordered)
                                .frame(minHeight: 44)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Link Scanner")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func scanInput() async {
        let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isScanning = true
        statusMessage = nil
        defer { isScanning = false }

        var found = DownloadLinkExtractor.extractDirectLinks(from: trimmed)

        if found.isEmpty,
           let pageURL = URL(string: trimmed),
           pageURL.scheme?.lowercased() == "https" {
            do {
                var request = URLRequest(url: pageURL, timeoutInterval: 15)
                request.setValue("ZynSign/3.0", forHTTPHeaderField: "User-Agent")
                let (data, _) = try await URLSession.shared.data(for: request)
                let bounded = Data(data.prefix(2 * 1_024 * 1_024))
                let manifestPackages = DownloadLinkExtractor.extractFromOTAManifest(bounded)
                if !manifestPackages.isEmpty {
                    found = manifestPackages
                } else if let html = String(data: bounded, encoding: .utf8) {
                    found = DownloadLinkExtractor.extractFromHTML(html, baseURL: pageURL)
                }
            } catch {
                statusMessage = error.localizedDescription
            }
        }

        var expanded: [DownloadLinkExtractor.DiscoveredLink] = []
        for item in found {
            if item.kind == .otaManifest,
               let data = try? await URLSession.shared.data(from: item.url).0 {
                let pkgs = DownloadLinkExtractor.extractFromOTAManifest(data)
                if !pkgs.isEmpty {
                    expanded.append(contentsOf: pkgs)
                    continue
                }
            }
            expanded.append(item)
        }

        candidates = expanded
        if expanded.isEmpty && statusMessage == nil {
            statusMessage = "No .ipa, .tipa, or OTA manifest links were found."
        }
    }
}
