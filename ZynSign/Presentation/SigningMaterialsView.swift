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
    @State private var showArchiveSheet = false
    @State private var showP12RecoverySheet = false
    @State private var showBundledAssetsSheet = false
    @State private var showAppleAccountHub = false

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
                        onInitialImportConsumed: { incomingURL = nil },
                        releaseImportedFile: { environment.droppedFiles?.release($0) }
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle(selection.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { showAppleAccountHub = true } label: {
                        Label("Apple ID Provisioning (Free & Paid)", systemImage: "person.badge.key")
                    }
                    Button { showArchiveSheet = true } label: {
                        Label(".zcert Identity Archive Import / Export", systemImage: "shippingbox")
                    }
                    Button { showP12RecoverySheet = true } label: {
                        Label("P12 Password Recovery", systemImage: "key.viewfinder")
                    }
                    Button { showBundledAssetsSheet = true } label: {
                        Label("Bundled signing-assets Import", systemImage: "tray.and.arrow.down")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("Certificate tools")
            }
        }
        .sheet(isPresented: $showAppleAccountHub) {
            NavigationStack {
                UnifiedSigningHubView(initialTab: .appleID)
            }
        }
        .sheet(isPresented: $showArchiveSheet) {
            ZynIdentityArchiveSheet()
        }
        .sheet(isPresented: $showP12RecoverySheet) {
            P12PasswordRecoverySheet()
        }
        .sheet(isPresented: $showBundledAssetsSheet) {
            BundledSigningAssetsSheet()
        }
    }
}
