import SwiftUI
import UIKit

/// The delivery hand-off screen — ZynSign's honest answer to "install".
///
/// The screen takes a pipeline-signed IPA and produces the artifacts an
/// operator needs to deliver it themselves: an `itms-services` manifest, a
/// ready-to-paste install link, a QR code, and the steps for the three
/// delivery channels (OTA, MDM, host tooling). ZynSign performs none of
/// the delivery: it never uploads, hosts, contacts a server, or claims an
/// installation outcome — the capability assessment stays
/// `noDeliveryMechanism`, and this screen says so in its own words.
struct InstallationDeliveryView: View {

    let package: InstallationDeliveryPackage

    @Environment(\.applicationEnvironment) private var environment
    @State private var hostingText = ""
    @State private var manifest: InstallationDeliveryManifest?
    @State private var manifestFileURL: URL?
    @State private var qrImage: CGImage?
    @State private var errorMessage: String?
    @State private var shareItem: DeliveryShareItem?
    @State private var copiedLink = false

    private let service = InstallationDeliveryService()
    private let qrRenderer = DeliveryQRCodeRenderer()

    var body: some View {
        List {
            packageSection
            hostingSection
            if let manifest { linkSection(manifest) }
            channelSection
            honestySection
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Deliver")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $shareItem) { item in DeliveryShareSheet(url: item.url) }
    }

    // MARK: - Sections

    private var packageSection: some View {
        Section {
            HStack(spacing: ZSpacing.xs) {
                ZStatusBadge("Hand-off", systemImage: "tray.and.arrow.up", kind: .info)
                ZStatusBadge("ZynSign does not install", systemImage: "xmark.shield", kind: .warning)
            }
            LabeledContent("Package", value: package.fileName)
            LabeledContent("Name", value: package.displayName)
            LabeledContent("Identifier", value: package.bundleIdentifier)
            LabeledContent("Version", value: package.bundleVersion)
            if let size = package.fileSizeBytes {
                LabeledContent("Size", value: ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
            }
        } header: { Text("Signed Package") } footer: {
            Text("The signed container is in Documents/Signed. Delivery moves a copy of it — ZynSign never uploads or transmits anything.")
        }
    }

    private var hostingSection: some View {
        Section {
            TextField("https://your.host/path/App_signed.ipa", text: $hostingText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
            if let error = errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .font(.footnote)
            }
            Button {
                generate()
            } label: {
                Label("Build Delivery Manifest", systemImage: "doc.badge.gearshape")
            }
            Text("Enter the HTTPS address where you will publish the signed IPA. ZynSign derives the manifest address beside it (…/manifest.plist) and builds the over-the-air artifacts.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: { Text("1 · Host the IPA") } footer: {
            Text("Over-the-air installation accepts only HTTPS. A local file address is refused — the installing device could never reach it.")
        }
    }

    private func linkSection(_ manifest: InstallationDeliveryManifest) -> some View {
        Section {
            if let link = manifest.installLink {
                VStack(alignment: .leading, spacing: ZSpacing.xxs) {
                    Text(link.absoluteString)
                        .font(.caption2.monospaced())
                        .textSelection(.enabled)
                        .foregroundStyle(.secondary)
                    Button {
                        UIPasteboard.general.string = link.absoluteString
                        copiedLink = true
                    } label: {
                        Label(copiedLink ? "Copied" : "Copy Install Link", systemImage: copiedLink ? "checkmark" : "doc.on.doc")
                    }
                }
            }
            if let qrImage {
                HStack {
                    Spacer()
                    Image(uiImage: UIImage(cgImage: qrImage))
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 200, height: 200)
                        .accessibilityLabel("QR code for the install link")
                    Spacer()
                }
                .listRowBackground(Color.clear)
            }
            Button { shareManifest() } label: {
                Label("Share manifest.plist…", systemImage: "square.and.arrow.up")
            }
            .disabled(manifestFileURL == nil)
            DisclosureGroup("Preview manifest") {
                if let data = try? manifest.xmlData(), let text = String(data: data, encoding: .utf8) {
                    Text(text)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        } header: { Text("2 · Install Link & Manifest") } footer: {
            Text("Publish manifest.plist at the manifest address, the IPA at the package address, then open the link or scan the code on the device. The device — not ZynSign — performs the install.")
        }
    }

    private var channelSection: some View {
        Section("3 · Delivery Channels") {
            ForEach(InstallationDeliveryChannel.allCases, id: \.self) { channel in
                VStack(alignment: .leading, spacing: ZSpacing.xxs) {
                    Text(channel.title).font(.subheadline.weight(.semibold))
                    Text(channel.summary).font(.caption).foregroundStyle(.secondary)
                    ForEach(channel.steps, id: \.self) { step in
                        Label(step, systemImage: "circle.fill")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .listRowInsets(EdgeInsets(top: 2, leading: 24, bottom: 2, trailing: 16))
                    }
                    Text(channel.requirement).font(.caption2).foregroundStyle(.orange)
                }
                .padding(.vertical, 2)
            }
        }
    }

    private var honestySection: some View {
        Section {
            let assessment = InstallationCapabilityAssessment.assess(
                InstallationEvidence(profileStatus: .indeterminate)
            )
            Label(assessment.limitations.first?.message ?? assessment.summary, systemImage: "xmark.shield")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text("ZynSign signs and verifies; the install prompt, the profile trust step, and the launch are the device's and the operator's. ZynSign never sees whether an install happened.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        } header: { Text("Why This Is a Hand-off") } footer: {
            Text("`InstallationCapabilityAssessment.deliveryMechanismAvailable == false` on every path. See docs/architecture/installation-compatibility.md.")
        }
    }

    // MARK: - Actions

    private func shareManifest() {
        guard let manifestFileURL else { return }
        shareItem = DeliveryShareItem(url: manifestFileURL)
    }

    private func generate() {
        errorMessage = nil
        manifest = nil
        manifestFileURL = nil
        qrImage = nil
        copiedLink = false
        do {
            let packageURL = try service.validateHostingURL(hostingText)
            let manifestURL = packageURL.deletingLastPathComponent()
                .appendingPathComponent("manifest.plist")
            let built = try service.manifest(
                for: package,
                packageURL: packageURL,
                manifestURL: manifestURL
            )
            manifest = built
            manifestFileURL = try service.writeManifest(built)
            qrImage = try? qrRenderer.cgImage(for: built.installLink?.absoluteString ?? "")
            environment.recordAnalyticsEvent(category: .delivery, name: "delivery.manifestGenerated", succeeded: true)
        } catch let error as InstallationDeliveryError {
            errorMessage = error.userMessage
            environment.recordAnalyticsEvent(category: .delivery, name: "delivery.manifestGenerated", succeeded: false)
        } catch {
            errorMessage = "The delivery manifest could not be built."
            environment.recordAnalyticsEvent(category: .delivery, name: "delivery.manifestGenerated", succeeded: false)
        }
    }
}

private struct DeliveryShareItem: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

private struct DeliveryShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
