import SwiftUI

/// The in-app version history: every stop on the release train this build
/// knows about, with what each stop switched on. The complete record lives
/// in `CHANGELOG.md`; this screen is the readable digest.
struct VersionHistoryView: View {

    private var entries: [VersionHistoryEntry] {
        VersionHistoryCatalog.entries(currentTag: ReleaseTrain.current.tag)
    }

    var body: some View {
        List {
            Section {
                Text("Every release stop ZynSign has cut, newest first. The repository's changelog remains the complete record; this digest carries what each stop switched on.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(entries, id: \.tag) { entry in
                Section {
                    VStack(alignment: .leading, spacing: ZSpacing.xs) {
                        HStack {
                            Text(entry.tag)
                                .font(.headline.monospaced())
                            if entry.isCurrent {
                                ZStatusBadge("This Build", systemImage: "arrow.down.circle.fill", kind: .info)
                            }
                        }
                        Text(entry.headline)
                            .font(.subheadline)
                        ForEach(entry.highlights, id: \.self) { highlight in
                            HStack(alignment: .top, spacing: ZSpacing.xs) {
                                Circle()
                                    .fill(.secondary)
                                    .frame(width: 4, height: 4)
                                    .padding(.top, 8)
                                Text(highlight)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.vertical, ZSpacing.xxs)
                } header: {
                    HStack {
                        Text(Self.dateText(entry.releasedAt))
                        Spacer()
                        Text("Market \(entry.marketingVersion) · Build \(entry.buildNumber)")
                            .font(.caption).foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .navigationTitle("Version History")
    }

    private static func dateText(_ components: DateComponents) -> String {
        let calendar = Calendar(identifier: .gregorian)
        guard let date = calendar.date(from: components) else { return "—" }
        return date.formatted(date: .long, time: .omitted)
    }
}
