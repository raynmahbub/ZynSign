import SwiftUI

/// Something the shell asks the Import Hub to do as it presents it.
enum ImportHubRequest: Equatable {
    case none
    case chooseFiles
    case history
}

/// The Smart Import Hub: the one screen every import arrives at.
///
/// From top to bottom:
///
/// - **Drop zone** — choose files, or drop them here on iPad.
/// - **Summary** — Imported, Skipped, Replaced, Failed, once anything has
///   finished, with Retry Failed and Open Library.
/// - **Needs Your Choice** — archives holding packages: extract the single
///   app, or choose from several.
/// - **Ready to Import** — the preview: icon, name, bundle ID, version and
///   build, size, contents, signing state, and any conflict with the
///   library. Deselect anything you don't want.
/// - **In Progress** — each item's stage, progress, remaining work, and
///   Cancel.
/// - **Finished** — outcomes, with reasons, Retry, and Details for anything
///   that failed.
///
/// The bottom bar imports the selected apps, or — while any selected app
/// conflicts with the library — opens the Duplicate Resolution Center
/// first. Nothing is stored without that confirmation.
@MainActor
struct ImportHubView: View {

    @ObservedObject var hub: ImportHub
    @Binding var request: ImportHubRequest
    var onOpenLibrary: () -> Void = {}
    var onDone: (() -> Void)? = nil

    @Environment(\.applicationEnvironment) private var environment
    @Environment(\.signingQueuePresentation) private var signingQueuePresentation

    /// The imported applications awaiting a signing-queue configuration,
    /// when the user asked to queue them straight from the Import Hub.
    @State private var queueConfiguration: SigningQueueConfigurationRequest?
    @State private var queueFailure: String?
    @State private var isShowingPicker = false
    /// A request queued until the picker has actually appeared.
    @State private var wantsFilePickerOnAppear = false
    /// Keeps the `.task`, shell request, and button action from presenting the
    /// same picker concurrently.
    @State private var isPresentingFilePicker = false
    /// Whether the hub's own sheet has finished appearing, reported by the
    /// sheet's controller rather than assumed after a delay.
    /// `presentPendingFilePick` is driven by `.task` before this turns true,
    /// and by the request itself after — a request that lands while the sheet
    /// is still animating in has nowhere to go otherwise, and the picker is
    /// simply never raised.
    ///
    /// It is also what lets the hub's own *Choose Files* button open the
    /// picker immediately: by the time the user can tap it the sheet is
    /// settled, so there is no transition left to wait out and no reason to
    /// make the user pay the settle beat again.
    @State private var hasSettled = false
    @State private var pickerFailure: String?
    @State private var isShowingResolutionCenter = false
    @State private var archiveSelection: ItemToken?
    @State private var detailItem: ItemToken?
    @State private var isShowingHistory = false
    @State private var openedEntry: LibraryEntry?
    @State private var missingRecordName: String?
    @State private var availableCapacity: Int?

    /// Identifies an item for a sheet, so the sheet always reads the item's
    /// live state from the hub.
    private struct ItemToken: Identifiable, Hashable {
        let id: ImportJobIdentifier
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Import Hub")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbarContent }
                .safeAreaInset(edge: .bottom) { actionBar }
                .navigationDestination(item: $openedEntry) { entry in
                    ApplicationDetailView(
                        entry: entry,
                        bundleInspection: environment.bundleInspection,
                        detailsInspection: environment.applicationDetailsInspection
                    )
                }
                .navigationDestination(isPresented: $isShowingHistory) {
                    ImportHistoryView(
                        hub: hub,
                        library: environment.library,
                        bundleInspection: environment.bundleInspection,
                        detailsInspection: environment.applicationDetailsInspection
                    )
                }
        }
        .fileImporter(
            isPresented: $isShowingPicker,
            allowedContentTypes: ImportablePackage.contentTypes,
            allowsMultipleSelection: true
        ) { result in
            handlePickerResult(result)
        }
        .alert(
            "Couldn't Open Files",
            isPresented: Binding(
                get: { pickerFailure != nil },
                set: { if !$0 { pickerFailure = nil } }
            ),
            presenting: pickerFailure
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { message in
            Text(message)
        }
        .alert(
            "App Not in Library",
            isPresented: Binding(
                get: { missingRecordName != nil },
                set: { if !$0 { missingRecordName = nil } }
            ),
            presenting: missingRecordName
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { name in
            Text("\(name) is no longer in the library.")
        }
        .sheet(isPresented: $isShowingResolutionCenter) {
            DuplicateResolutionCenterView(hub: hub, onImport: { importSelected() })
        }
        .sheet(item: $archiveSelection) { token in
            archiveSheet(for: token.id)
        }
        .sheet(item: $detailItem) { token in
            detailSheet(for: token.id)
        }
        .alert(
            "Nothing to Queue",
            isPresented: Binding(
                get: { queueFailure != nil },
                set: { if !$0 { queueFailure = nil } }
            ),
            presenting: queueFailure
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { message in
            Text(message)
        }
        .sheet(item: $queueConfiguration) { request in
            SigningQueueConfigurationView(
                entries: request.entries,
                origin: request.origin,
                onOpenQueue: { signingQueuePresentation.present() },
                onDone: { queueConfiguration = nil }
            )
        }
        .importDropTarget()
            .onChange(of: request, initial: true) { _, newValue in
                handle(newValue)
            }
            .task {
                // The pending request waits the sheet out; starting this task
                // also means a request that arrives later can present straight
                // away.
                await presentPendingFilePick(waitingForSheet: true)
            }
            .background {
                // The sheet reports its own appearance: a picker asked for
                // before this fires would be asked for inside the sheet's
                // transition, where UIKit drops it without an error.
                SheetPresentationReporter { hasSettled = true }
                    .frame(width: 0, height: 0)
                    .accessibilityHidden(true)
            }
        .onChange(of: hub.lastFinishedBatch) { _, entry in
            announce(entry)
        }
        .task {
            availableCapacity = hub.availableCapacity()
        }
    }

    // MARK: - Content

    private var archiveItems: [ImportHub.Item] {
        hub.items.filter(\.isAwaitingSelection)
    }

    private var activeItems: [ImportHub.Item] {
        hub.items.filter(\.isActive)
    }

    private var finishedItems: [ImportHub.Item] {
        Array(hub.items.filter(\.isFinished).reversed())
    }

    private var retryableCount: Int {
        hub.items.filter { hub.canRetry($0.id) }.count
    }

    private var needsStorage: Bool {
        hub.items.contains { $0.settlement?.failure?.recovery == .freeStorage }
    }

    private var content: some View {
        List {
            Section {
                ImportDropZone(receivingCount: hub.receivingDropCount) {
                    requestFilePicker()
                }
                .listRowInsets(EdgeInsets(top: ZSpacing.xs, leading: 0, bottom: ZSpacing.xs, trailing: 0))
                .listRowBackground(Color.clear)
            } footer: {
                if hub.items.isEmpty {
                    howItWorks
                }
            }

            if hub.isPaused {
                Section {
                    Label(ImportQueueRendering.pausedExplanation, systemImage: "pause.circle")
                        .font(.footnote)
                }
            }

            if needsStorage {
                Section {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Not enough free space for some imports. Nothing was copied for them.")
                            if let text = ImportQueueRendering.storageText(available: availableCapacity) {
                                Text(text).foregroundStyle(.secondary)
                            }
                        }
                    } icon: {
                        Image(systemName: "externaldrive.badge.exclamationmark")
                            .foregroundStyle(.orange)
                    }
                    .font(.footnote)
                }
            }

            if hub.summary.settledCount > 0 {
                Section {
                    ImportSummaryCard(
                        summary: hub.summary,
                        retryableCount: retryableCount,
                        onRetryFailed: { withAnimation(ZMotion.fast) { hub.retryAllFailed() } },
                        onOpenLibrary: onOpenLibrary,
                        onClear: { withAnimation(ZMotion.fast) { hub.clearFinished() } },
                        onQueueImported: importedRecords.isEmpty ? nil : {
                            queueForSigning(importedRecords)
                        }
                    )
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }
            }

            if !archiveItems.isEmpty {
                Section("Needs Your Choice") {
                    ForEach(archiveItems) { item in
                        archiveRow(for: item)
                    }
                }
            }

            if !hub.readyItems.isEmpty {
                Section {
                    ForEach(hub.readyItems) { item in
                        previewRow(for: item)
                    }
                } header: {
                    previewHeader
                } footer: {
                    previewFooter
                }
            }

            if !activeItems.isEmpty {
                Section("In Progress") {
                    ForEach(activeItems) { item in
                        queueRow(for: item)
                    }
                }
            }

            if !finishedItems.isEmpty {
                Section("Finished") {
                    ForEach(finishedItems) { item in
                        VStack(alignment: .leading, spacing: ZSpacing.xs) {
                            queueRow(for: item)
                            if let settlement = item.settlement, settlement.kind.isAccepted, let record = settlement.record {
                                ImportReadyToSignOffer(record: record)
                            }
                        }
                    }
                }
            }

            if !hub.items.isEmpty {
                Section {
                    Text(ImportQueueRendering.backgroundExplanation)
                    if let text = ImportQueueRendering.storageText(available: availableCapacity) {
                        Text(text)
                    }
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        }
        .listStyle(.insetGrouped)
        // Items arriving and leaving animate once. Phase changes animate the
        // same way: an item moving from In Progress to the preview settles
        // into place instead of jumping between sections, and the finished
        // summary arrives rather than appearing. Progress within a phase is
        // deliberately not part of the trigger — a copying item reports ten
        // times a second, and animating that would be motion without meaning.
        .animation(ZMotion.fast, value: hub.items.map(\.id))
        .animation(ZMotion.fast, value: hub.items.map(\.phase))
    }

    private var howItWorks: some View {
        VStack(alignment: .leading, spacing: ZSpacing.xs) {
            Label("Add as many .ipa, .tipa, or .zip files as you like, from Files, the share sheet, Open In, or by dropping them here.", systemImage: "1.circle")
            Label("Each one is checked on ZynSign's own copy — its icon, identity, signing state, and contents are read.", systemImage: "2.circle")
            Label("Review what's inside, settle any conflicts with your library, then import. Your original files are never changed.", systemImage: "3.circle")
        }
        .font(.footnote)
        .padding(.top, ZSpacing.xs)
    }

    // MARK: - Rows

    @ViewBuilder
    private func archiveRow(for item: ImportHub.Item) -> some View {
        if case .awaitingSelection(let candidates) = item.phase {
            ArchiveOfferRow(
                item: item,
                candidates: candidates,
                onExtractSingle: {
                    withAnimation(ZMotion.fast) { hub.extract(candidates, from: item.id) }
                },
                onChoose: { archiveSelection = ItemToken(id: item.id) },
                onDecline: {
                    withAnimation(ZMotion.fast) { hub.declineArchive(item.id) }
                }
            )
        }
    }

    private func previewRow(for item: ImportHub.Item) -> some View {
        ImportPreviewRow(
            item: item,
            onToggle: {
                ZHaptics.tap()
                withAnimation(ZMotion.fast) { hub.setSelected(!item.isSelected, for: item.id) }
            },
            onResolve: { resolution in hub.resolve(item.id, with: resolution) },
            onOpenResolutionCenter: { isShowingResolutionCenter = true },
            onCancel: { withAnimation(ZMotion.fast) { hub.cancel(item.id) } }
        )
    }

    private func queueRow(for item: ImportHub.Item) -> some View {
        ImportItemRow(
            item: item,
            canRetry: hub.canRetry(item.id),
            onCancel: { withAnimation(ZMotion.fast) { hub.cancel(item.id) } },
            onRetry: { withAnimation(ZMotion.fast) { hub.retry(item.id) } },
            onRemove: { withAnimation(ZMotion.fast) { hub.remove(item.id) } },
            onShowDetails: { detailItem = ItemToken(id: item.id) },
            onOpenRecord: { record in openRecord(record) },
            onQueueForSigning: signingQueuePresentation.isAvailable
                ? { record in queueForSigning([record]) }
                : nil
        )
    }

    // MARK: - Signing queue

    /// The records the finished imports stored, one per record, in the order
    /// they settled — what "sign what I just imported" means. Empty where
    /// the signing queue is not exposed.
    private var importedRecords: [ApplicationRecord] {
        guard signingQueuePresentation.isAvailable else { return [] }
        var seen = Set<ApplicationRecordIdentifier>()
        return hub.items.compactMap { item -> ApplicationRecord? in
            guard let settlement = item.settlement, settlement.kind.isAccepted,
                  let record = settlement.record,
                  seen.insert(record.id).inserted else { return nil }
            return record
        }
    }

    /// Opens the queue configuration for `records`, resolved through the
    /// library at the moment of asking: an application replaced or deleted
    /// since its import settled is never queued from a stale record, and one
    /// whose package file is missing is skipped.
    private func queueForSigning(_ records: [ApplicationRecord]) {
        Task {
            var entries: [LibraryEntry] = []
            for record in records {
                if let entry = try? await environment.library.entry(withID: record.id),
                   entry.isArtifactAvailable {
                    entries.append(entry)
                }
            }
            guard !entries.isEmpty else {
                queueFailure = records.count == 1
                    ? "\(records[0].identity.displayName ?? records[0].identity.bundleIdentifier.rawValue) is no longer in the library, or its package file is missing."
                    : "None of the imported applications is still in the library with its package file."
                return
            }
            queueConfiguration = SigningQueueConfigurationRequest(entries: entries, origin: .importHub)
        }
    }

    private var previewHeader: some View {
        HStack {
            Text("Ready to Import (\(hub.readyItems.count))")
            Spacer()
            let allSelected = hub.readyItems.allSatisfy(\.isSelected)
            Button(allSelected ? "Select None" : "Select All") {
                withAnimation(ZMotion.fast) {
                    if allSelected { hub.deselectAllReady() } else { hub.selectAllReady() }
                }
            }
            .font(.footnote.weight(.semibold))
            .textCase(nil)
        }
    }

    @ViewBuilder
    private var previewFooter: some View {
        let unresolved = hub.unresolvedConflictCount
        VStack(alignment: .leading, spacing: ZSpacing.xxs) {
            if unresolved > 0 {
                Button {
                    isShowingResolutionCenter = true
                } label: {
                    Label(
                        unresolved == 1 ? "1 conflict needs a choice before importing" : "\(unresolved) conflicts need a choice before importing",
                        systemImage: "square.on.square"
                    )
                }
                .font(.footnote.weight(.semibold))
            } else if !hub.conflictItems.isEmpty {
                Button("Review Conflict Choices") { isShowingResolutionCenter = true }
                    .font(.footnote.weight(.semibold))
            }
            Text("Selecting a file only previews it. Tap Add to Library below to finish importing. Deselected apps are skipped; your original files are never changed.")
        }
    }

    // MARK: - Action bar

    @ViewBuilder
    private var actionBar: some View {
        if !hub.readyItems.isEmpty {
            VStack(spacing: ZSpacing.xxs) {
                if hub.unresolvedConflictCount > 0 {
                    Button {
                        isShowingResolutionCenter = true
                    } label: {
                        Label(resolveTitle, systemImage: "square.on.square")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                    .controlSize(.large)
                    .keyboardShortcut("r", modifiers: .command)
                } else {
                    Button(action: importSelected) {
                        Text(importTitle)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!hub.canImportSelected)
                    .keyboardShortcut(.return, modifiers: .command)
                }
                if let caption = actionCaption {
                    Text(caption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.horizontal, ZSpacing.md)
            .padding(.vertical, ZSpacing.sm)
            .background(.bar)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private var importTitle: String {
        let count = hub.selectedReadyItems.count
        switch count {
        case 0: return "Select Apps to Add to Library"
        case 1: return "Add 1 App to Library"
        default: return "Add \(count) Apps to Library"
        }
    }

    private var resolveTitle: String {
        let count = hub.unresolvedConflictCount
        return count == 1 ? "Resolve 1 Conflict" : "Resolve \(count) Conflicts"
    }

    private var actionCaption: String? {
        let preparing = hub.items.filter(\.isPreparing).count + hub.items.filter { $0.phase == .waiting }.count
        guard preparing > 0 else { return nil }
        return preparing == 1
            ? "1 more file is still being checked and will appear here when it's ready."
            : "\(preparing) more files are still being checked and will appear here when they're ready."
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if let onDone {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done", action: onDone)
                    .keyboardShortcut(.cancelAction)
            }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                requestFilePicker()
            } label: {
                Label("Add Files", systemImage: "plus")
            }
            .help("Choose files to import (⌘O)")
            Menu {
                Button {
                    isShowingHistory = true
                } label: {
                    Label("Import History", systemImage: "clock.arrow.circlepath")
                }
                if retryableCount > 0 {
                    Button {
                        withAnimation(ZMotion.fast) { hub.retryAllFailed() }
                    } label: {
                        Label("Retry All Failed", systemImage: "arrow.clockwise")
                    }
                }
                if hub.items.contains(where: \.canCancel) {
                    Button(role: .destructive) {
                        withAnimation(ZMotion.fast) { hub.cancelAll() }
                    } label: {
                        Label("Cancel All", systemImage: "xmark.circle")
                    }
                }
                if hub.items.contains(where: \.isFinished) {
                    Button {
                        withAnimation(ZMotion.fast) { hub.clearFinished() }
                    } label: {
                        Label("Clear Finished", systemImage: "checkmark.circle.badge.xmark")
                    }
                }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
        }
    }

    // MARK: - Sheets

    @ViewBuilder
    private func archiveSheet(for id: ImportJobIdentifier) -> some View {
        if let item = hub.items.first(where: { $0.id == id }),
           case .awaitingSelection(let candidates) = item.phase {
            ArchiveSelectionView(
                archiveName: item.fileName,
                candidates: candidates,
                onExtract: { chosen in
                    withAnimation(ZMotion.fast) { hub.extract(chosen, from: id) }
                },
                onDecline: {
                    withAnimation(ZMotion.fast) { hub.declineArchive(id) }
                }
            )
        } else {
            ContentUnavailableView("Nothing to Choose", systemImage: "doc.zipper", description: Text("This archive is no longer waiting for a choice."))
        }
    }

    @ViewBuilder
    private func detailSheet(for id: ImportJobIdentifier) -> some View {
        if let item = hub.items.first(where: { $0.id == id }) {
            ImportItemDetailView(item: item, canRetry: hub.canRetry(id)) {
                withAnimation(ZMotion.fast) { hub.retry(id) }
            }
        } else {
            ContentUnavailableView("Item Removed", systemImage: "tray", description: Text("This import is no longer in the hub."))
        }
    }

    // MARK: - Actions

    private func importSelected() {
        guard hub.canImportSelected else { return }
        ZHaptics.tap()
        withAnimation(ZMotion.fast) {
            hub.importSelected()
        }
    }

    private func handlePickerResult(_ result: Result<[URL], any Error>) {
        isShowingPicker = false
        wantsFilePickerOnAppear = false
        switch result {
        case .success(let urls):
            guard !urls.isEmpty else { return }
            Task { @MainActor in
                guard await PresentationSettle.waitForIdle(cap: .seconds(8)) else {
                    pickerFailure = "The system file picker is still closing. Wait a moment, then choose the files again."
                    return
                }
                withAnimation(ZMotion.fast) {
                    _ = hub.receive(urls, origin: .documentPicker)
                }
                availableCapacity = hub.availableCapacity()
            }
        case .failure(let error):
            guard !ImportQueueRendering.isCancellation(error) else { return }
            let failureMessage = ImportQueueRendering.pickerFailureMessage(for: error)
            Task { @MainActor in
                _ = await PresentationSettle.waitForIdle(cap: .seconds(8))
                pickerFailure = failureMessage
            }
        }
    }

    private func handle(_ newRequest: ImportHubRequest) {
        switch newRequest {
        case .none:
            return
        case .chooseFiles:
            pickerFailure = nil
            // The picker cannot be presented until this sheet is itself on
            // screen — asking earlier fails silently, with no picker and no
            // error. Record the request, then try: `.task` below covers a
            // request that arrived before the hub existed, and this call
            // covers one that arrives while it is already up. Whichever runs
            // first consumes the flag, so the picker opens exactly once.
            wantsFilePickerOnAppear = true
            // Whether the sheet is still settling or long since up, exactly
            // one caller raises the picker: the first to reach it consumes the
            // flag, and the other finds nothing to do.
            Task { await presentPendingFilePick(waitingForSheet: !hasSettled) }
        case .history:
            isShowingHistory = true
        }
        request = .none
    }

    /// Queues a picker request from a control the user can already see.
    private func requestFilePicker() {
        pickerFailure = nil
        wantsFilePickerOnAppear = true
        Task { @MainActor in
            await presentPendingFilePick(waitingForSheet: !hasSettled)
        }
    }

    /// Presents the picker once the hub is on screen and its own transition
    /// has settled.
    ///
    /// `.task` and `handle(_:)` may both notice the same request, and a user
    /// control may ask while the sheet is still settling. The in-flight flag
    /// serializes those callers. `.fileImporter` owns the document picker through
    /// its Boolean binding, so this keeps the request armed instead of cancelling
    /// it based on an unrelated UIKit controller-identity check.
    ///
    /// - Parameter waitingForSheet: Whether the hub's own sheet may still be
    ///   animating in. When it may, the sheet's appearance reporter is awaited;
    ///   the presented-controller chain is allowed to settle before the binding
    ///   is armed.
    private func presentPendingFilePick(waitingForSheet: Bool) async {
        guard wantsFilePickerOnAppear else { return }
        if isShowingPicker {
            wantsFilePickerOnAppear = false
            return
        }
        guard !isPresentingFilePicker else { return }
        isPresentingFilePicker = true
        defer { isPresentingFilePicker = false }

        if waitingForSheet {
            _ = await PresentationSettle.waitUntil { hasSettled }
        }
        _ = await PresentationSettle.waitForIdle()
        guard wantsFilePickerOnAppear, !Task.isCancelled else { return }

        isShowingPicker = true
        wantsFilePickerOnAppear = false
    }

    private func openRecord(_ record: ApplicationRecord) {
        Task {
            if let entry = try? await environment.library.entry(withID: record.id) {
                openedEntry = entry
            } else {
                missingRecordName = record.identity.displayName ?? record.identity.bundleIdentifier.rawValue
            }
        }
    }

    private func announce(_ entry: ImportHistoryEntry?) {
        guard let entry else { return }
        if entry.count(of: .failed) > 0 {
            ZHaptics.warning()
        } else {
            ZHaptics.success()
        }
        AccessibilityNotification.Announcement(ImportQueueRendering.announcement(for: entry)).post()
        availableCapacity = hub.availableCapacity()
    }
}
