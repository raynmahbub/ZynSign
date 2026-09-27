import SwiftUI

/// The Installation History: every event across every installed record,
/// newest first, lightweight and paged.
///
/// The history is derived from the records' events — never stored
/// separately — so a row can never disagree with the record it came from.
/// Opening a row shows what ZynSign knew at the time: the app, the
/// version, the timestamp, the verification result, and the artifact used.
struct InstallationHistoryView: View {

    @ObservedObject var model: InstallationWorkspaceModel

    var body: some View {
        Group {
            if model.historyEntries.isEmpty {
                VStack(spacing: ZSpacing.sm) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("No installation history yet").font(.headline)
                    Text("Confirmed deliveries and recorded installations appear here, newest first.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding()
            } else {
                list
            }
        }
        .navigationTitle("History")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var list: some View {
        List {
            Section {
                ForEach(model.historyEntries) { entry in
                    NavigationLink {
                        InstallationHistoryEntryDetail(entry: entry)
                    } label: {
                        HistoryEntryRow(entry: entry)
                    }
                }
                if !model.showsAllHistory {
                    Button {
                        Task { await model.loadMoreHistory() }
                    } label: {
                        Label("Show More", systemImage: "chevron.down")
                    }
                }
            } footer: {
                Text("\(model.historyEntries.count) shown. Each row is one confirmed delivery or recorded installation — ZynSign did not observe any of them.")
            }
        }
        .listStyle(.plain)
    }
}

/// What one history entry says when opened: the app, version, timestamp,
/// verification result at the time, and the artifact used — plus the line
/// that keeps the entry honest.
struct InstallationHistoryEntryDetail: View {

    let entry: InstallationHistoryEntry

    var body: some View {
        List {
            Section {
                LabeledContent("App", value: entry.appName)
                LabeledContent("Bundle ID", value: entry.bundleIdentifier)
                LabeledContent("Action", value: entry.event.kind.displayName)
                LabeledContent("Version", value: entry.event.versionDisplay)
                LabeledContent("When", value: InstallationPresentation.timestamp(entry.event.at))
            } header: {
                Text("Event")
            }

            Section {
                if let status = entry.event.verificationStatus {
                    HStack(spacing: ZSpacing.xs) {
                        Text("Verification at confirmation")
                        Spacer()
                        ZStatusBadge(
                            status.displayName,
                            kind: status.isPassing ? .success : (status.isFailing ? .error : .warning)
                        )
                    }
                    Text(status.explanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    LabeledContent("Verification", value: "Not recorded")
                }
            } header: {
                Text("Verification Result")
            } footer: {
                Text("This is what verification said when the delivery was confirmed. The artifact may have changed since; Verify Again in the workspace re-checks the bytes as they are now.")
            }

            Section {
                if let exportName = entry.event.exportFileName {
                    LabeledContent("Artifact", value: exportName)
                } else {
                    LabeledContent("Artifact", value: "Not linked")
                }
                if entry.event.exportIdentifier != nil && entry.event.exportFileName == nil {
                    Text("The export this event named is no longer held, so its file name is gone with it. The event stays.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Channel", value: entry.event.channel.displayName)
                Text(entry.event.channel.explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Artifact Used")
            }

            Section {
                Text(InstallationPresentation.historyHonestyLine)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Details")
        .navigationBarTitleDisplayMode(.inline)
    }
}
