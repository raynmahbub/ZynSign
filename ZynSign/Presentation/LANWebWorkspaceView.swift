import SwiftUI
import UIKit

/// Foreground Wi-Fi Browser Upload & WebDAV Workspace screen.
struct LANWebWorkspaceView: View {
    @ObservedObject var service: LANWebWorkspaceService
    @Environment(\.applicationEnvironment) private var environment
    @Environment(\.importPresentation) private var importPresentation

    @State private var portText = "8088"
    @State private var showCopiedToast = false

    private var baseURLString: String {
        service.endpoint?.displayAddress ?? "http://localhost:\(service.endpoint?.port ?? service.port)"
    }

    var body: some View {
        List {
            Section {
                statusRow
                if service.isRunning {
                    LabeledContent("Browser Dashboard") {
                        Text(baseURLString)
                            .font(ZTypography.codeCaption)
                            .textSelection(.enabled)
                    }
                    if service.webdavEnabled {
                        LabeledContent("WebDAV Mount URL") {
                            Text(baseURLString + "/dav/")
                                .font(ZTypography.codeCaption)
                                .textSelection(.enabled)
                        }
                    }
                    Button {
                        UIPasteboard.general.string = baseURLString
                        ZHaptics.tap()
                        showCopiedToast = true
                    } label: {
                        Label("Copy Browser & WebDAV URL", systemImage: "doc.on.doc")
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    }
                    Button(role: .destructive) {
                        Task { await service.stopServer() }
                    } label: {
                        Label("Stop LAN Server", systemImage: "stop.circle.fill")
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    }
                } else {
                    Button {
                        if let parsed = UInt16(portText.trimmingCharacters(in: .whitespaces)) {
                            service.port = parsed
                        }
                        Task { await service.startServer() }
                    } label: {
                        Label("Start LAN Web & WebDAV Server", systemImage: "wifi.circle.fill")
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    }
                }
            } header: {
                Text("Foreground LAN Server")
            } footer: {
                Text("Exposes your ZynSign WebWorkspace over local Wi-Fi as both an HTML5 drag-and-drop dashboard and a macOS Finder / Windows Explorer WebDAV drive.")
            }

            Section("Configuration") {
                TextField("Preferred Port", text: $portText)
                    .keyboardType(.numberPad)
                Toggle("Enable WebDAV Drive (/dav/)", isOn: $service.webdavEnabled)
                Toggle("Require HTTP Basic Authentication", isOn: $service.requiresAuthentication)
                if service.requiresAuthentication {
                    TextField("Username", text: $service.username)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    SecureField("Password", text: $service.password)
                }
            }

            if !service.items.isEmpty {
                Section("Uploaded Workspace Files (\(service.items.count))") {
                    ForEach(service.items) { item in
                        HStack(spacing: ZSpacing.sm) {
                            VStack(alignment: .leading, spacing: ZSpacing.xxs) {
                                Text(item.fileName).font(ZTypography.subheadline).lineLimit(1)
                                Text("\(item.category) · \(ByteCountFormatter.string(fromByteCount: item.byteSize, countStyle: .file))")
                                    .font(ZTypography.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if ["ipa", "tipa"].contains(item.fileURL.pathExtension.lowercased()) {
                                Button("Import") {
                                    _ = environment.importHub.receive([item.fileURL], origin: .documentPicker)
                                    importPresentation.present()
                                }
                                .buttonStyle(.bordered)
                                .frame(minHeight: 44)
                            }
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                service.deleteItem(item)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Wi-Fi & WebDAV Server")
        .navigationBarTitleDisplayMode(.inline)
        .zToast(isPresented: $showCopiedToast, message: "LAN URL copied.", style: .info)
        .onAppear {
            portText = String(service.port)
            if service.password.isEmpty {
                service.password = String(UUID().uuidString.prefix(8)).lowercased()
            }
            service.refreshItems()
        }
    }

    @ViewBuilder
    private var statusRow: some View {
        if service.isRunning {
            ZStatusBadge("Running · \(baseURLString)", systemImage: "checkmark.circle.fill", kind: .success)
        } else if let msg = service.statusMessage {
            VStack(alignment: .leading, spacing: ZSpacing.xxs) {
                ZStatusBadge("Error", systemImage: "exclamationmark.triangle.fill", kind: .error)
                Text(msg).font(ZTypography.caption).foregroundStyle(.secondary)
            }
        } else {
            ZStatusBadge("Stopped", systemImage: "pause.circle", kind: .neutral)
        }
    }
}
