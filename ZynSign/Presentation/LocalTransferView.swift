import SwiftUI
import UIKit

/// Local transfer: a short-lived, token-gated way to put a file on this device
/// from another machine on the same network.
///
/// The screen is a control and a statement in equal measure. It starts and
/// stops the session, shows the address and the token the session is actually
/// using, and then says — in the same breath — what the session is not: it is
/// not WebDAV, it does not browse this device, it holds nothing in the
/// background, and a file it receives is bytes in a workspace rather than an
/// imported application.
///
/// The session stops when the screen goes away. That is the honest lifecycle
/// for a listener iOS will not keep alive in the background, and it is visible
/// here rather than implied.
struct LocalTransferView: View {

    /// Settings pushes this screen, so it does not add a stack of its own
    /// unless it is the root of a context that has none.
    var embedsNavigationStack: Bool = true

    @StateObject private var model: LocalTransferModel
    @State private var copiedNotice: String?

    init(service: LocalTransferService, embedsNavigationStack: Bool = true) {
        _model = StateObject(wrappedValue: LocalTransferModel(service: service))
        self.embedsNavigationStack = embedsNavigationStack
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
        List {
            statusSection
            if model.token != nil {
                credentialSection
            }
            instructionsSection
            receivedSection
            boundariesSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Local Transfer")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.refresh() }
        .onDisappear {
            // A listener that outlives its screen would be a background
            // server nobody is watching. It is stopped instead.
            Task { await model.stop() }
        }
    }

    /// Whether a session is open, as the screen renders it.
    private var isListening: Bool {
        if case .listening = model.phase { return true }
        return false
    }

    // MARK: - Status

    private var statusSection: some View {
        Section {
            HStack(spacing: ZSpacing.xs) {
                ZStatusBadge(badgeText, systemImage: badgeSymbol, kind: badgeKind)
                Spacer()
            }
            switch model.phase {
            case .stopped:
                Text("Nothing is listening. Starting a session opens one port on this device for thirty minutes, or until you stop it.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            case .starting:
                Text("Opening the listener…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            case .listening(let address, let expiresAt):
                VStack(alignment: .leading, spacing: ZSpacing.xxs) {
                    Text(address)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                    Text("Closes at \(expiresAt.formatted(date: .omitted, time: .shortened)), or when you stop it.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            case .failed(let message):
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if let notice = model.notice {
                HStack(alignment: .top, spacing: ZSpacing.xs) {
                    Text(notice)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Button("Dismiss") { model.clearNotice() }
                        .font(.footnote)
                        .buttonStyle(.borderless)
                }
            }
            if isListening {
                Button(role: .destructive) {
                    Task { await model.stop() }
                } label: {
                    Label("Stop listening", systemImage: "stop.circle")
                }
                .disabled(model.isBusy)
            } else {
                Button {
                    Task { await model.start() }
                } label: {
                    Label("Start listening", systemImage: "wifi")
                }
                .disabled(model.isBusy)
            }
            if let copiedNotice {
                Text(copiedNotice)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Session")
        } footer: {
            Text("The session answers on the network this device is joined to. It is not reachable from another network, and ZynSign does not ask any server to relay it.")
        }
        .accessibilityIdentifier("localTransfer.status")
    }

    private var badgeText: String {
        switch model.phase {
        case .stopped: return "Not listening"
        case .starting: return "Starting"
        case .listening: return "Listening"
        case .failed: return "Failed"
        }
    }

    private var badgeSymbol: String {
        switch model.phase {
        case .stopped: return "wifi.slash"
        case .starting: return "clock"
        case .listening: return "wifi"
        case .failed: return "exclamationmark.triangle"
        }
    }

    private var badgeKind: ZStatusBadge.Kind {
        switch model.phase {
        case .stopped: return .neutral
        case .starting: return .info
        case .listening: return .success
        case .failed: return .error
        }
    }

    // MARK: - Credential

    private var credentialSection: some View {
        Section {
            if let token = model.token {
                Text(token)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                Button {
                    UIPasteboard.general.string = token
                    copiedNotice = "Token copied."
                } label: {
                    Label("Copy session token", systemImage: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .font(.footnote)
            }
        } header: {
            Text("Token")
        } footer: {
            Text("Anyone who has this address and this token can send files while the session is open. The token is generated when the session starts and is discarded when it stops.")
        }
    }

    // MARK: - Instructions

    private var instructionsSection: some View {
        Section {
            if let command = model.uploadCommand {
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(command)
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(.vertical, ZSpacing.xxs)
                }
                Button {
                    UIPasteboard.general.string = command
                    copiedNotice = "Command copied."
                } label: {
                    Label("Copy upload command", systemImage: "terminal")
                }
                .buttonStyle(.borderless)
                .font(.footnote)
            } else {
                Text("Start a session to see the command for another machine.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Text("Accepted: \(model.acceptedExtensions). Each upload is one request body; there is no browsing, no listing, and no multipart form.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        } header: {
            Text("Send a file")
        }
    }

    // MARK: - Received

    private var receivedSection: some View {
        Section {
            if model.received.isEmpty {
                Text("No files received in this session.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ForEach(model.received) { file in
                HStack(spacing: ZSpacing.xs) {
                    VStack(alignment: .leading, spacing: ZSpacing.xxs) {
                        Text(file.name)
                            .font(.subheadline)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(file.formattedSize)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    ShareLink(item: file.url) {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .accessibilityLabel("Share \(file.name)")
                }
            }
            .onDelete { offsets in
                let files = model.received
                Task {
                    for offset in offsets where files.indices.contains(offset) {
                        await model.discard(files[offset])
                    }
                }
            }
            if model.received.count > 1 {
                Button("Remove all received files", role: .destructive) {
                    Task { await model.discardAll() }
                }
                .font(.footnote)
            }
        } header: {
            Text("Received")
        } footer: {
            Text("A received file is bytes in ZynSign's workspace. It is not imported, not inspected, and not signed — import it from the Import Hub to find out what it is. Requests answered: \(model.requestCount), refused: \(model.rejectionCount).")
        }
    }

    // MARK: - Boundaries

    private var boundariesSection: some View {
        Section("What this is not") {
            Label("Not WebDAV. There is no file-system browse, no listing, and no rename or delete over the network.", systemImage: "xmark.circle")
                .font(.footnote)
            Label("Not a background service. The listener stops when this screen closes or the app leaves the foreground.", systemImage: "xmark.circle")
                .font(.footnote)
            Label("Not an installer. Receiving a package does not install it, and nothing here marks it as installed.", systemImage: "xmark.circle")
                .font(.footnote)
        }
    }
}
