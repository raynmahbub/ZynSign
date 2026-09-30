import SwiftUI

/// The App Protection panel: per-app lock and the concealed vault.
///
/// Protection is an interface guard, not encryption. A locked app demands
/// authentication before its detail view opens; a concealed app disappears
/// from the library while the vault is closed. Both rely on the system's
/// authentication — ZynSign only learns yes or no.
struct AppProtectionView: View {
    @Environment(\.applicationEnvironment) private var environment
    @State private var entries: [LibraryEntry] = []
    @State private var policies: [String: AppProtectionPolicy] = [:]
    @State private var vaultState: ProtectionVaultState = .closed
    @State private var isAuthenticating = false

    private var service: AppProtectionService? { environment.appProtection }

    var body: some View {
        List {
            Section {
                Label("Interface guard, not encryption", systemImage: "info.circle")
                Text("Locked and concealed records stay in the library exactly like any other record. The guard decides when the interface shows them — it does not encrypt the packages themselves.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if vaultState == .unavailable {
                Section {
                    Label("No biometric capability", systemImage: "exclamationmark.triangle")
                    Text("This device offers no Face ID, Touch ID, or passcode capability the guard could use. Protection is unavailable rather than pretend.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            Section {
                if entries.isEmpty {
                    ContentUnavailableView(
                        "No Applications",
                        systemImage: "square.grid.2x2",
                        description: Text("Import an application first; protection applies to library records.")
                    )
                } else {
                    ForEach(entries, id: \.record.id) { entry in
                        protectionRow(entry)
                    }
                }
            } header: {
                Text("Applications")
            } footer: {
                Text("Lock demands authentication before the app's detail view opens. Conceal also hides the app from the library while the vault is closed.")
            }
        }
        .navigationTitle("App Protection")
        .task { await reload() }
    }

    private func protectionRow(_ entry: LibraryEntry) -> some View {
        let recordID = entry.record.id.rawValue
        let policy = policies[recordID]
        let name = entry.record.identity.displayName ?? entry.record.bundleIdentifier.rawValue
        return VStack(alignment: .leading, spacing: ZSpacing.xs) {
            Text(name).font(.headline)
            Text(entry.record.bundleIdentifier.rawValue)
                .font(.caption).foregroundStyle(.secondary)
            HStack(spacing: ZSpacing.sm) {
                Toggle(isOn: binding(for: recordID, isLocked: true, current: policy)) {
                    Label("Lock", systemImage: "lock")
                        .font(.callout)
                }
                .toggleStyle(.button)
                Toggle(isOn: binding(for: recordID, isLocked: false, current: policy)) {
                    Label("Conceal", systemImage: "eye.slash")
                        .font(.callout)
                }
                .toggleStyle(.button)
            }
        }
        .padding(.vertical, ZSpacing.xxs)
    }

    private func binding(for recordID: String, isLocked: Bool, current: AppProtectionPolicy?) -> Binding<Bool> {
        Binding {
            if isLocked { return current?.requiresUnlock ?? false }
            return current?.concealed ?? false
        } set: { newValue in
            guard let service else { return }
            do {
                if isLocked {
                    if newValue {
                        try service.lock(recordID: recordID)
                    } else if current?.concealed == true {
                        // Unlocking a concealed app keeps it concealed: the
                        // concealment implies the lock.
                        try service.conceal(recordID: recordID)
                    } else {
                        try service.clear(recordID: recordID)
                    }
                } else {
                    if newValue {
                        try service.conceal(recordID: recordID)
                    } else if current?.requiresUnlock == true {
                        try service.lock(recordID: recordID)
                    } else {
                        try service.clear(recordID: recordID)
                    }
                }
            } catch {
                // Storage failures surface as the toggle snapping back on
                // the next reload; the guard is honest either way.
            }
            reloadPolicies()
        }
    }

    private func reload() async {
        entries = (try? await environment.library.entries()) ?? []
        reloadPolicies()
        refreshVaultState()
    }

    private func reloadPolicies() {
        policies = (try? service?.all()) ?? [:]
    }

    private func refreshVaultState() {
        let availability = environment.biometricAuthenticator.availability()
        vaultState = availability.isAvailable ? .closed : .unavailable
    }
}

/// A gate that stands between the library and one record's destination.
///
/// When the record carries a lock, the gate shows a locked placeholder and
/// asks for authentication before revealing the content; an unlocked or
/// unguarded record renders its content immediately. The gate never caches
/// a success beyond the destination's lifetime — each navigation through a
/// locked record asks again.
struct LockedRecordGate<Content: View>: View {
    @Environment(\.applicationEnvironment) private var environment
    let recordID: ApplicationRecordIdentifier
    @ViewBuilder var content: () -> Content

    @State private var unlocked = false
    @State private var isAuthenticating = false
    @State private var failedAttempt = false

    var body: some View {
        Group {
            if requiresUnlock && !unlocked {
                lockedPlaceholder
            } else {
                content()
            }
        }
    }

    /// The record's lock, read through the protection service. The store
    /// keeps an in-memory cache after its first read, so this stays cheap.
    /// An open vault session already authenticated, so the gate steps
    /// aside instead of asking a second time.
    private var requiresUnlock: Bool {
        guard let service = environment.appProtection else { return false }
        if service.session.isOpen { return false }
        guard let policy = try? service.policy(recordID: recordID.rawValue) else { return false }
        return policy.requiresUnlock
    }

    private var lockedPlaceholder: some View {
        VStack(spacing: ZSpacing.md) {
            Image(systemName: "lock.fill")
                .font(.largeTitle)
                .imageScale(.large)
                .foregroundStyle(.secondary)
            Text("This Application Is Locked")
                .font(ZynSignTokens.Typography.title3)
            Text("Authenticate to view, inspect, or sign it.")
                .font(ZynSignTokens.Typography.footnote)
                .foregroundStyle(.secondary)
            if failedAttempt {
                Text("Authentication did not succeed. Try again.")
                    .font(ZynSignTokens.Typography.caption)
                    .foregroundStyle(.orange)
            }
            Button {
                authenticate()
            } label: {
                if isAuthenticating {
                    ProgressView()
                } else {
                    Label("Unlock", systemImage: "faceid")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(isAuthenticating)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ZynSignTokens.Color.groupedBackground)
    }

    private func authenticate() {
        guard !isAuthenticating else { return }
        isAuthenticating = true
        Task {
            let outcome = await environment.biometricAuthenticator.authenticate(
                reason: "Unlock this application to view it."
            )
            if outcome.isAuthenticated {
                unlocked = true
                failedAttempt = false
            } else if outcome != .cancelled {
                failedAttempt = true
            }
            isAuthenticating = false
        }
    }
}
