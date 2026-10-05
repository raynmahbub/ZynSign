import SwiftUI

/// Browse Apple device firmware and the signing status reported by IPSW.me.
///
/// The view can own a navigation stack when presented from Home, or embed in
/// the Settings navigation stack when opened from Settings → Updates.
struct IPSWBrowserView: View {
    @Environment(\.applicationEnvironment) private var environment

    @State private var devices: [IPSWDevice] = []
    @State private var searchText = ""
    @State private var isLoading = false
    @State private var loadError: String?

    var embedsNavigationStack: Bool
    private let catalogOverride: (any IPSWFirmwareCatalog)?

    init(
        embedsNavigationStack: Bool = true,
        catalog: (any IPSWFirmwareCatalog)? = nil
    ) {
        self.embedsNavigationStack = embedsNavigationStack
        catalogOverride = catalog
    }

    private var catalog: (any IPSWFirmwareCatalog)? {
        catalogOverride ?? environment.ipswFirmwareCatalog
    }

    var body: some View {
        Group {
            if embedsNavigationStack {
                NavigationStack { browserContent }
            } else {
                browserContent
            }
        }
    }

    @ViewBuilder
    private var browserContent: some View {
        if let catalog {
            deviceList(using: catalog)
        } else {
            ContentUnavailableView(
                "Firmware Browser Unavailable",
                systemImage: "wifi.slash",
                description: Text("This build has no firmware catalog service configured.")
            )
            .navigationTitle("IPSW Browser")
        }
    }

    private func deviceList(using catalog: any IPSWFirmwareCatalog) -> some View {
        List {
            Section {
                Label("Live signing status", systemImage: "checkmark.seal")
                    .font(.headline)
                Text("Firmware details and signing status come from IPSW.me. Apple controls what can be restored, and signing status can change at any time.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let loadError {
                Section {
                    Label("Device list could not be refreshed", systemImage: "wifi.exclamationmark")
                        .font(.headline)
                    Text(loadError)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button("Try Again") {
                        Task { await load(using: catalog) }
                    }
                    .disabled(isLoading)
                }
            }

            if devices.isEmpty, isLoading {
                Section {
                    HStack(spacing: ZSpacing.sm) {
                        ProgressView()
                        Text("Loading Apple devices…")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityLabel("Loading Apple devices")
            } else if devices.isEmpty, loadError == nil {
                ContentUnavailableView(
                    "No Devices Found",
                    systemImage: "iphone",
                    description: Text("Pull down to refresh the firmware catalog.")
                )
            } else if devices.isEmpty {
                EmptyView()
            } else if filteredDevices.isEmpty {
                ContentUnavailableView.search(text: searchText)
            } else {
                Section("Devices · \(filteredDevices.count)") {
                    ForEach(filteredDevices) { device in
                        NavigationLink(value: device) {
                            IPSWDeviceRow(device: device)
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("IPSW Browser")
        .navigationBarTitleDisplayMode(.large)
        .searchable(text: $searchText, prompt: "Search devices")
        .refreshable { await load(using: catalog) }
        .task {
            guard devices.isEmpty, loadError == nil else { return }
            await load(using: catalog)
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await load(using: catalog) }
                } label: {
                    if isLoading {
                        ProgressView()
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .disabled(isLoading)
                .accessibilityLabel("Refresh firmware devices")
            }
        }
        .navigationDestination(for: IPSWDevice.self) { device in
            IPSWFirmwareListView(device: device, catalog: catalog)
        }
        .animation(ZMotion.fast, value: isLoading)
        .animation(ZMotion.fast, value: filteredDevices.map(\.identifier))
    }

    private var filteredDevices: [IPSWDevice] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return devices }
        return devices.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || $0.identifier.localizedCaseInsensitiveContains(query)
        }
    }

    @MainActor
    private func load(using catalog: any IPSWFirmwareCatalog) async {
        guard !isLoading else { return }
        isLoading = true
        loadError = nil
        defer { isLoading = false }

        do {
            devices = try await catalog.devices()
        } catch is CancellationError {
            return
        } catch {
            loadError = error.localizedDescription
        }
    }
}

private struct IPSWDeviceRow: View {
    let device: IPSWDevice

    var body: some View {
        HStack(spacing: ZSpacing.md) {
            Image(systemName: "iphone.gen3")
                .font(.title3.weight(.semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 42, height: 42)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: ZRadius.card, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: ZSpacing.xxs) {
                Text(device.name)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(device.identifier)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: ZSpacing.sm)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .padding(.vertical, ZSpacing.xxs)
        .accessibilityElement(children: .combine)
    }
}

private struct IPSWFirmwareListView: View {
    let device: IPSWDevice
    let catalog: any IPSWFirmwareCatalog

    @State private var firmwares: [IPSWFirmware] = []
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var signedOnly = false

    private var visibleFirmwares: [IPSWFirmware] {
        signedOnly ? firmwares.filter { $0.signed == true } : firmwares
    }

    var body: some View {
        List {
            Section {
                HStack {
                    Label(device.identifier, systemImage: "iphone.gen3")
                        .font(.subheadline.monospaced())
                    Spacer()
                    Text("\(firmwares.filter { $0.signed == true }.count) signed")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(ZColors.success)
                }
                Text("Signed status is a live catalog report, not a guarantee that a restore will succeed. Check again before downloading or restoring.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let loadError {
                Section {
                    Label("Firmware list could not be loaded", systemImage: "wifi.exclamationmark")
                        .font(.headline)
                    Text(loadError)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button("Try Again") {
                        Task { await load() }
                    }
                    .disabled(isLoading)
                }
            }

            if isLoading, firmwares.isEmpty {
                Section {
                    HStack(spacing: ZSpacing.sm) {
                        ProgressView()
                        Text("Loading firmware…")
                            .foregroundStyle(.secondary)
                    }
                }
            } else if firmwares.isEmpty, loadError == nil {
                ContentUnavailableView(
                    "No Firmware Listed",
                    systemImage: "shippingbox",
                    description: Text("No IPSW releases are listed for this device yet.")
                )
            } else if firmwares.isEmpty {
                EmptyView()
            } else {
                Section {
                    Toggle("Show signed releases only", isOn: $signedOnly)
                        .font(.subheadline)
                }
                if visibleFirmwares.isEmpty {
                    ContentUnavailableView(
                        "No Signed Releases",
                        systemImage: "checkmark.seal",
                        description: Text("Turn off the filter to see older unsigned releases.")
                    )
                } else {
                    Section("Firmware · \(visibleFirmwares.count)") {
                        ForEach(visibleFirmwares) { firmware in
                            IPSWFirmwareRow(firmware: firmware)
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(device.name)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task {
            guard firmwares.isEmpty, loadError == nil else { return }
            await load()
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await load() }
                } label: {
                    if isLoading {
                        ProgressView()
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .disabled(isLoading)
                .accessibilityLabel("Refresh firmware list")
            }
        }
        .animation(ZMotion.fast, value: signedOnly)
        .animation(ZMotion.fast, value: visibleFirmwares.map(\.id))
    }

    @MainActor
    private func load() async {
        guard !isLoading else { return }
        isLoading = true
        loadError = nil
        defer { isLoading = false }

        do {
            firmwares = try await catalog.firmwares(for: device)
        } catch is CancellationError {
            return
        } catch {
            loadError = error.localizedDescription
        }
    }
}

private struct IPSWFirmwareRow: View {
    let firmware: IPSWFirmware

    private var statusTitle: String {
        switch firmware.signed {
        case .some(true): return "Signed"
        case .some(false): return "Unsigned"
        case .none: return "Status unavailable"
        }
    }

    private var statusColor: Color {
        firmware.signed == true ? ZColors.success : ZColors.neutral
    }

    private var statusSymbol: String {
        switch firmware.signed {
        case .some(true): return "checkmark.seal.fill"
        case .some(false): return "xmark.seal"
        case .none: return "questionmark.seal"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: ZSpacing.sm) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: ZSpacing.xxs) {
                    Text("Version \(firmware.version)")
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text("Build \(firmware.buildID)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: ZSpacing.sm)
                Label(statusTitle, systemImage: statusSymbol)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(statusColor)
                    .padding(.horizontal, ZSpacing.sm)
                    .padding(.vertical, ZSpacing.xxs)
                    .background(statusColor.opacity(0.12), in: Capsule())
            }

            HStack(spacing: ZSpacing.sm) {
                if let releaseDate = firmware.releaseDate {
                    Text(releaseDate.formatted(date: .abbreviated, time: .omitted))
                }
                if let fileSize = firmware.fileSize {
                    Text(ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file))
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if let url = firmware.appleDownloadURL {
                Link(destination: url) {
                    Label("Download from Apple", systemImage: "arrow.down.to.line")
                        .font(.subheadline.weight(.semibold))
                }
                .accessibilityHint("Opens Apple's firmware download link.")
            } else {
                Text("Apple download link unavailable")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, ZSpacing.xs)
    }
}
