import SwiftUI

/// About — what this build is, and the documents that come with it.
///
/// Everything here is a fact about the application or a document the user can
/// read: the version, the build, the copyright, the licence, the privacy
/// policy, the terms, and the acknowledgements. Nothing here describes how the
/// application was made — no release stages, no internal tooling, no
/// development workflow. Those are the maintainers' business; this page is the
/// user's.
struct AboutSettingsSection: View {

    @Environment(\.applicationEnvironment) private var environment

    static let descriptor = SettingsSectionDescriptor(
        identifier: .about,
        title: "About",
        symbolName: "info.circle",
        summary: "Version, build, licence, privacy, and acknowledgements.",
        footer: "ZynSign is original software. It links no third-party code into the application binary."
    )

    var body: some View {
        List {
            identitySection
            documentsSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle(Self.descriptor.title)
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Identity

    private var identitySection: some View {
        Section {
            HStack(spacing: ZSpacing.md) {
                ZynSignAppMark(size: 60)
                VStack(alignment: .leading, spacing: 2) {
                    Text(environment.applicationInfo.displayName)
                        .font(.headline)
                    Text("Sign and keep applications on your own device.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)

            ZSettingsValueRow(title: "Version", symbol: "number", subtitle: nil) {
                Text(environment.applicationInfo.marketingVersion)
                    .foregroundStyle(.secondary)
            }
            ZSettingsValueRow(title: "Build", symbol: "hammer", subtitle: nil) {
                Text(environment.applicationInfo.buildVersion)
                    .foregroundStyle(.secondary)
            }
            ZSettingsValueRow(title: "Copyright", symbol: "c.circle", subtitle: nil) {
                Text("© 2026 ZynSign")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("ZynSign")
        } footer: {
            Text("The mark above is ZynSign's own. Alternate app icons arrive with a later release; this build ships one icon, provided by the build itself.")
        }
    }

    // MARK: - Documents

    private var documentsSection: some View {
        Section {
            NavigationLink { AboutDocumentView(document: .license) } label: {
                ZSettingsLabel(title: AboutDocument.Document.license.title, symbol: "doc.text")
            }
            NavigationLink { AboutDocumentView(document: .privacyPolicy) } label: {
                ZSettingsLabel(title: AboutDocument.Document.privacyPolicy.title, symbol: "hand.raised")
            }
            NavigationLink { AboutDocumentView(document: .terms) } label: {
                ZSettingsLabel(title: AboutDocument.Document.terms.title, symbol: "list.bullet.rectangle")
            }
            NavigationLink { AboutDocumentView(document: .acknowledgements) } label: {
                ZSettingsLabel(title: AboutDocument.Document.acknowledgements.title, symbol: "heart")
            }
            Link(destination: URL(string: "https://github.com/raynmahbub/ZynSign")!) {
                ZSettingsLabel(title: "ZynSign on GitHub", symbol: "link")
            }
        } header: {
            Text("Documents")
        } footer: {
            Text("These documents ship with ZynSign. Nothing here links to a server that learns you read it.")
        }
    }
}

// MARK: - App mark

/// ZynSign's own mark.
///
/// This is the application's mark, drawn from the design system's own tokens —
/// not an extracted icon from a package, and not a claim about the icon the
/// system shows on the Home Screen.
struct ZynSignAppMark: View {

    var size: CGFloat = 60

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.2237, style: .continuous)
                .fill(LinearGradient(
                    colors: [Color.accentColor, Color.accentColor.opacity(0.65)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ))
            Image(systemName: "signature")
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

// MARK: - Documents

/// One document that ships with ZynSign.
private struct AboutDocumentView: View {

    let document: AboutDocument.Document

    var body: some View {
        List {
            Section {
                Text(document.body)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            } header: {
                Text(document.subtitle)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(document.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// The documents About links to.
///
/// Each is a value with fixed text, so the words the user reads are the words
/// in this repository — no page that can change under them, and no link that
/// can rot.
private enum AboutDocument {

    enum Document {
        case license
        case privacyPolicy
        case terms
        case acknowledgements

        var title: String {
            switch self {
            case .license: return "Open-Source Licences"
            case .privacyPolicy: return "Privacy Policy"
            case .terms: return "Terms of Use"
            case .acknowledgements: return "Acknowledgements"
            }
        }

        var subtitle: String {
            switch self {
            case .license: return "What ZynSign links, and under what terms"
            case .privacyPolicy: return "What ZynSign collects: nothing"
            case .terms: return "What ZynSign is for, and is not"
            case .acknowledgements: return "What ZynSign was built on"
            }
        }

        var body: String {
            switch self {
            case .license: return Self.license
            case .privacyPolicy: return Self.privacyPolicy
            case .terms: return Self.terms
            case .acknowledgements: return Self.acknowledgements
            }
        }

        static let license = """
        ZynSign is released under the MIT License.

        Copyright (c) 2026 ZynSign

        Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

        The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

        THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

        ZynSign links no third-party code into the application binary. No analytics kit, no crash reporter, no networking library, and no signing toolkit are linked in. OpenSSL is used only by the repository's host-side validation scripts, and never by the application.
        """

        static let privacyPolicy = """
        ZynSign collects nothing.

        There is no account, no telemetry, no crash reporting, and no measurement of any kind that leaves the device. There is no identifier — no advertising identifier, no vendor identifier, and no custom one — collected for measurement. There is no endpoint to send anything to.

        What ZynSign reads — the packages you import, the certificates and private keys you add, and the provisioning profiles you import — is read on the device and kept inside the application's container. Private keys are held by the system Keychain with non-extractable protection and are never read out by ZynSign, never exported, and never logged.

        The optional activity journal and the optional technical log are on-device records you can read and clear in Settings. A diagnostic report is written to a file only when you export it, and it leaves the device only if you share it yourself.
        """

        static let terms = """
        ZynSign is provided as-is, without warranty of any kind. Use it at your own risk.

        ZynSign helps you sign applications you already hold, with certificates and provisioning profiles you already own. It does not install applications, does not bypass any platform restriction, and does not make any statement about whether a signed application will be accepted anywhere. A signed application's validity is decided by whoever receives it.

        You are responsible for the certificates you use, the applications you sign, and everything you do with them. ZynSign has no knowledge of your accounts, your devices, or your intentions, and keeps no record of them off your device.

        The MIT License above is the licence that applies to the software. These terms describe what the software is for; they do not replace or limit that licence.
        """

        static let acknowledgements = """
        ZynSign is original software, written from scratch for this project.

        It is built on Apple's platforms: Foundation, SwiftUI, Security, LocalAuthentication, CryptoKit, Compression, Network, and the code-signing architecture documented by Apple. The signing implementation follows the published structure of code signatures, code directories, and CMS containers rather than any third-party tool.

        Thanks to everyone who reported a problem, tested a build, or read a document and said what was wrong. ZynSign is better for it.
        """
    }
}

#Preview {
    NavigationStack {
        AboutSettingsSection()
    }
    .environment(\.applicationEnvironment, CompositionRoot.makeApplicationEnvironment())
}
