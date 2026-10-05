import SwiftUI

/// The active segment in the combined Certificates & Profiles area.
enum SigningMaterialsSection: String, CaseIterable, Hashable, Identifiable, Sendable {
    case certificates
    case profiles

    var id: Self { self }

    var title: String {
        switch self {
        case .certificates: return "Certificates"
        case .profiles: return "Profiles"
        }
    }
}

/// A single signing-material destination for Home, Settings, and incoming
/// certificate/profile files. The segmented control keeps both workflows in
/// one place without nesting navigation stacks.
struct SigningMaterialsView: View {
    @Environment(\.applicationEnvironment) private var environment
    @State private var selection: SigningMaterialsSection
    @Binding private var incomingURL: URL?

    var embedsNavigationStack: Bool

    init(
        initialSelection: SigningMaterialsSection = .certificates,
        incomingURL: Binding<URL?> = .constant(nil),
        embedsNavigationStack: Bool = true
    ) {
        self.embedsNavigationStack = embedsNavigationStack
        _selection = State(initialValue: initialSelection)
        _incomingURL = incomingURL
    }

    var body: some View {
        Group {
            if embedsNavigationStack {
                NavigationStack { content }
            } else {
                content
            }
        }
    }

    private var content: some View {
        VStack(spacing: 0) {
            Picker("Signing material", selection: $selection) {
                ForEach(SigningMaterialsSection.allCases) { section in
                    Text(section.title).tag(section)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("Signing material section")
            .padding(.horizontal, ZSpacing.md)
            .padding(.vertical, ZSpacing.sm)

            Divider()

            Group {
                switch selection {
                case .certificates:
                    CertificateManagerView(
                        store: environment.identityStore,
                        annotations: environment.identityAnnotations,
                        importer: environment.pkcs12Importer,
                        initialImportURL: incomingURL,
                        onInitialImportConsumed: { incomingURL = nil }
                    )
                case .profiles:
                    ProfilesView(
                        profiles: environment.provisioningProfiles,
                        importer: environment.provisioningProfileImporter,
                        compatibility: environment.profileCompatibility,
                        selections: environment.profileSelections,
                        recordEvent: { name, succeeded in
                            environment.recordAnalyticsEvent(
                                category: .intake,
                                name: name,
                                succeeded: succeeded
                            )
                        },
                        embedsNavigationStack: false,
                        initialImportURL: incomingURL,
                        onInitialImportConsumed: { incomingURL = nil }
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle(selection.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
