import SwiftUI
import UniformTypeIdentifiers

/// The observable model behind the Tweak Library screen.
///
/// The model owns the list the screen renders and the import pipeline from
/// the file picker; the service owns the rules. Nothing here touches the
/// payload bytes except to hand them to the service.
@MainActor
final class TweakLibraryModel: ObservableObject {

    @Published private(set) var tweaks: [TweakDescriptor] = []
    @Published private(set) var groups: [String] = []
    @Published var errorMessage: String?
    @Published var selection: Set<UUID> = []
    @Published var importResultMessage: String?

    private let service: TweakLibraryService

    init(service: TweakLibraryService) {
        self.service = service
        refresh()
    }

    func refresh() {
        tweaks = (try? service.all()) ?? []
        groups = (try? service.groups()) ?? []
        selection = Set(tweaks.filter(\.enabledByDefault).map(\.id))
    }

    func importFiles(at urls: [URL]) {
        errorMessage = nil
        var imported = 0
        for url in urls {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else {
                errorMessage = "The file could not be read."
                continue
            }
            do {
                switch try service.importPayload(data, fileName: url.lastPathComponent) {
                case .success:
                    imported += 1
                case .failure(let refusal):
                    errorMessage = refusal.message
                }
            } catch {
                errorMessage = "The tweak library could not store the import."
            }
        }
        refresh()
        if imported > 0 {
            importResultMessage = imported == 1 ? "1 tweak imported." : "\(imported) tweaks imported."
        }
    }

    func rename(_ tweak: TweakDescriptor, to name: String) {
        _ = try? service.rename(id: tweak.id, to: name)
        refresh()
    }

    func setGroup(_ tweak: TweakDescriptor, group: String?) {
        try? service.setGroup(id: tweak.id, group: group)
        refresh()
    }

    func toggleEnabled(_ tweak: TweakDescriptor) {
        try? service.setEnabled(id: tweak.id, enabled: !tweak.enabledByDefault)
        refresh()
    }

    func remove(_ tweak: TweakDescriptor) {
        try? service.remove(id: tweak.id)
        selection.remove(tweak.id)
        refresh()
    }

    /// The plan the current selection produces, when it produces one.
    func currentPlan() -> TweakInjectionPlan? {
        guard case .success(let plan)? = try? service.makePlan(selectionIDs: selection) else { return nil }
        return plan
    }

    /// The refusal the current selection produces, when it refuses.
    func currentRefusal() -> TweakInjectionPlan.Refusal? {
        guard let result = try? service.makePlan(selectionIDs: selection),
              case .failure(let refusal) = result else { return nil }
        return refusal
    }
}

/// The Tweak Library: import payloads, organize them into groups, and
/// select which ones a signing session stages.
///
/// The library stores and manages; staging is prepared here as a plan the
/// signing session can attach. Payloads are kept exactly as imported —
/// ZynSign never executes, interprets, or modifies them.
struct TweakLibraryView: View {
    @StateObject private var model: TweakLibraryModel
    @State private var isImporting = false
    @State private var renamingTweak: TweakDescriptor?
    @State private var renameText = ""

    /// When presented from a signing session, the confirmed selection is
    /// handed back through this closure.
    let onConfirmSelection: ((TweakInjectionPlan) -> Void)?

    init(service: TweakLibraryService, onConfirmSelection: ((TweakInjectionPlan) -> Void)? = nil) {
        self.onConfirmSelection = onConfirmSelection
        _model = StateObject(wrappedValue: TweakLibraryModel(service: service))
    }

    var body: some View {
        List {
            planSection
            if model.tweaks.isEmpty {
                Section {
                    ContentUnavailableView(
                        "No Tweaks Yet",
                        systemImage: "puzzlepiece.extension",
                        description: Text("Import .dylib, .deb, .framework, .bundle, or .appex payloads to keep them ready for signing sessions.")
                    )
                    Button {
                        isImporting = true
                    } label: {
                        Label("Import Tweaks", systemImage: "plus")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            } else {
                ForEach(model.tweaks) { tweak in
                    tweakRow(tweak)
                }
            }
        }
        .navigationTitle("Tweak Library")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    isImporting = true
                } label: {
                    Label("Import", systemImage: "plus")
                }
            }
            if onConfirmSelection != nil {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Use Selection") {
                        if let plan = model.currentPlan() {
                            onConfirmSelection?(plan)
                        }
                    }
                    .disabled(model.currentPlan() == nil)
                }
            }
        }
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: [.data, .item],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result {
                model.importFiles(at: urls)
            }
        }
        .alert("Import", isPresented: Binding(
            get: { model.importResultMessage != nil },
            set: { if !$0 { model.importResultMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.importResultMessage ?? "")
        }
        .alert("Cannot Import", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
        .alert("Rename Tweak", isPresented: Binding(
            get: { renamingTweak != nil },
            set: { if !$0 { renamingTweak = nil } }
        )) {
            TextField("Name", text: $renameText)
            Button("Save") {
                if let tweak = renamingTweak {
                    model.rename(tweak, to: renameText)
                }
                renamingTweak = nil
            }
            Button("Cancel", role: .cancel) { renamingTweak = nil }
        }
        .zThemeTint()
    }

    private var planSection: some View {
        Section {
            if let plan = model.currentPlan() {
                LabeledContent("Selected", value: "\(plan.entries.count)")
                LabeledContent("Payload", value: StorageGaugeReading.humanReadable(plan.totalBytes))
                if !plan.isFullyStageable {
                    Label(
                        "\(plan.unstageableEntries.count) selected payload(s) have no bundle location and are recorded in the manifest only.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.caption).foregroundStyle(.orange)
                }
            } else if let refusal = model.currentRefusal() {
                Label(refusal.message, systemImage: "exclamationmark.triangle")
                    .font(.footnote).foregroundStyle(.orange)
            } else {
                Text("Select the tweaks a signing session should stage. Selections are validated against the plan limits before signing.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        } header: {
            Text("Staging Plan")
        }
    }

    private func tweakRow(_ tweak: TweakDescriptor) -> some View {
        let isSelected = model.selection.contains(tweak.id)
        return Button {
            if isSelected {
                model.selection.remove(tweak.id)
            } else {
                model.selection.insert(tweak.id)
            }
        } label: {
            HStack(spacing: ZSpacing.sm) {
                Image(systemName: tweak.kind.symbolName)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(tweak.name).font(.body).foregroundStyle(.primary)
                    Text("\(tweak.kind.displayName) · \(StorageGaugeReading.humanReadable(tweak.byteSize))")
                        .font(.caption).foregroundStyle(.secondary)
                    if let group = tweak.group {
                        Text(group).font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                Spacer()
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary.opacity(0.5))
            }
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                model.remove(tweak)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .swipeActions(edge: .leading) {
            Button {
                renamingTweak = tweak
                renameText = tweak.name
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            .tint(.indigo)
        }
        .contextMenu {
            Button {
                renamingTweak = tweak
                renameText = tweak.name
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            Menu("Group") {
                Button("No Group") { model.setGroup(tweak, group: nil) }
                ForEach(model.groups, id: \.self) { group in
                    Button(group) { model.setGroup(tweak, group: group) }
                }
            }
            Button(role: .destructive) {
                model.remove(tweak)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }
}
