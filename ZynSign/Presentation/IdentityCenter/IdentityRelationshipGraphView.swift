import SwiftUI

/// The Identity Center's relationship graph.
///
/// A read-only visualization of how the user's signing identities relate:
/// teams as groups, certificates on the left of each group, the profiles
/// they are named by or share a team with on the right, and a line for
/// every relationship the snapshot established. The graph draws exactly
/// the snapshot's facts — it adds no inference, hides no identity, and
/// offers no action beyond looking.
///
/// Rendering is lazy in the way that matters here: only expanded teams lay
/// out their nodes, so a large identity collection still scrolls
/// instantly. The nodes are ordinary SwiftUI views, so VoiceOver reads
/// each relationship; the connecting lines are drawn on a Canvas behind
/// them and are decorative, so nothing visual is inaccessible.
struct IdentityRelationshipGraphView: View {

    let snapshot: IdentityCenterSnapshot

    @State private var collapsedTeamKeys: Set<String> = []

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: ZSpacing.lg) {
                summary
                if snapshot.teams.isEmpty {
                    ContentUnavailableView(
                        "No Relationships",
                        systemImage: "point.3.connected.trianglepath.dotted",
                        description: Text("Import a certificate and a profile and their relationships appear here.")
                    )
                } else {
                    ForEach(snapshot.teams) { team in
                        teamGraph(team)
                    }
                }
                legend
            }
            .padding(ZSpacing.md)
        }
        .navigationTitle("Relationship Graph")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var summary: some View {
        Text(spokenSummary)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .accessibilityAddTraits(.isStaticText)
    }

    private var spokenSummary: String {
        let certificates = snapshot.certificates.count
        let profiles = snapshot.profiles.count
        if snapshot.teams.isEmpty { return "No identities to relate yet." }
        return "\(certificates) certificate\(certificates == 1 ? "" : "s") and \(profiles) profile\(profiles == 1 ? "" : "s") across \(snapshot.teams.count) team\(snapshot.teams.count == 1 ? "" : "s")."
    }

    // MARK: One team

    private func teamGraph(_ team: DeveloperTeam) -> some View {
        let isExpanded = !collapsedTeamKeys.contains(team.id)
        let certificates = snapshot.certificates.filter { $0.teamKey == team.id }
        let profiles = snapshot.profiles.filter { $0.teamKey == team.id }
        let maxRows = max(certificates.count, profiles.count, 1)

        return ZCard {
            VStack(alignment: .leading, spacing: ZSpacing.sm) {
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                        toggle(team.id)
                    }
                } label: {
                    HStack {
                        Label(team.displayName, systemImage: isExpanded ? "folder.fill" : "folder")
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Text("\(team.memberCount)")
                            .font(.caption.weight(.semibold))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                        Image(systemName: "chevron.down")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(isExpanded ? 0 : -90))
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Team \(team.displayName), \(team.memberCount) members")
                .accessibilityHint(isExpanded ? "Collapses the team." : "Expands the team.")

                if isExpanded {
                    // Nodes are positioned absolutely with the same math
                    // the Canvas uses for its edge endpoints, so a line
                    // always meets its chip. Only expanded teams lay out
                    // their nodes at all.
                    GeometryReader { proxy in
                        let layout = GraphLayout(width: proxy.size.width, rows: maxRows)
                        ZStack {
                            Canvas { context, size in
                                drawEdges(
                                    layout: layout,
                                    certificates: certificates,
                                    profiles: profiles,
                                    in: &context,
                                    size: size
                                )
                            }
                            .allowsHitTesting(false)
                            ForEach(Array(certificates.enumerated()), id: \.element.id) { index, certificate in
                                GraphNode(
                                    title: certificate.displayName,
                                    symbol: "signature",
                                    color: IdentityCenterPalette.color(for: certificate.health.status)
                                )
                                .frame(width: layout.nodeWidth)
                                .position(layout.centerOfLeftNode(at: index, height: proxy.size.height))
                            }
                            if certificates.isEmpty {
                                GraphNode(title: "No certificates", symbol: "signature", color: .secondary)
                                    .frame(width: layout.nodeWidth)
                                    .position(layout.centerOfLeftNode(at: 0, height: proxy.size.height))
                            }
                            ForEach(Array(profiles.enumerated()), id: \.element.id) { index, profile in
                                GraphNode(
                                    title: profile.displayName,
                                    symbol: "person.text.rectangle",
                                    color: IdentityCenterPalette.color(for: profile.health.status)
                                )
                                .frame(width: layout.nodeWidth)
                                .position(layout.centerOfRightNode(at: index, height: proxy.size.height))
                            }
                            if profiles.isEmpty {
                                GraphNode(title: "No profiles", symbol: "person.text.rectangle", color: .secondary)
                                    .frame(width: layout.nodeWidth)
                                    .position(layout.centerOfRightNode(at: 0, height: proxy.size.height))
                            }
                        }
                    }
                    .frame(height: layoutHeight(rows: maxRows))
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel(teamSpokenSummary(certificates: certificates, profiles: profiles))
                }
            }
        }
    }

    private func toggle(_ key: String) {
        if collapsedTeamKeys.contains(key) {
            collapsedTeamKeys.remove(key)
        } else {
            collapsedTeamKeys.insert(key)
        }
    }

    private func layoutHeight(rows: Int) -> CGFloat {
        let rowHeight: CGFloat = 30
        let spacing: CGFloat = 10
        return CGFloat(max(rows, 1)) * rowHeight + CGFloat(max(rows - 1, 0)) * spacing
    }

    private func drawEdges(
        layout: GraphLayout,
        certificates: [IdentityCenterCertificate],
        profiles: [IdentityCenterProfile],
        in context: inout GraphicsContext,
        size: CGSize
    ) {
        for (certificateIndex, certificate) in certificates.enumerated() {
            for (profileIndex, profile) in profiles.enumerated() {
                guard areLinked(certificate: certificate, profile: profile) else { continue }
                let start = layout.centerOfLeftNode(at: certificateIndex, height: size.height)
                let end = layout.centerOfRightNode(at: profileIndex, height: size.height)
                var path = Path()
                path.move(to: start)
                path.addCurve(
                    to: end,
                    control1: CGPoint(x: (start.x + end.x) / 2, y: start.y),
                    control2: CGPoint(x: (start.x + end.x) / 2, y: end.y)
                )
                context.stroke(
                    path,
                    with: .color(Color.accentColor.opacity(0.45)),
                    lineWidth: 1.5
                )
            }
        }
    }

    /// Whether the graph draws a line between the two: the profile names
    /// the certificate among its embedded fingerprints, or the two declare
    /// the same team — the same linkage the workspace and health engine
    /// use, so the graph can never disagree with the lists.
    private func areLinked(certificate: IdentityCenterCertificate, profile: IdentityCenterProfile) -> Bool {
        if profile.facts.certificateFingerprints.contains(certificate.facts.fingerprintHex) {
            return true
        }
        guard let certificateTeam = certificate.facts.teamID,
              let profileTeam = profile.facts.teamID else { return false }
        return certificateTeam.caseInsensitiveCompare(profileTeam) == .orderedSame
    }

    private func teamSpokenSummary(
        certificates: [IdentityCenterCertificate],
        profiles: [IdentityCenterProfile]
    ) -> String {
        var summary = "\(certificates.count) certificates, \(profiles.count) profiles. "
        for certificate in certificates {
            summary += "Certificate \(certificate.displayName). "
        }
        for profile in profiles {
            summary += "Profile \(profile.displayName). "
        }
        return summary
    }

    /// The geometry of one team's two-column layout.
    private struct GraphLayout {
        let width: CGFloat
        let rows: Int

        var gutter: CGFloat { 48 }
        var nodeWidth: CGFloat { max(0, (width - gutter) / 2) }

        /// The vertical center of the node at `index` in a column of
        /// `rows` rows filling `height`.
        private func centerY(at index: Int, height: CGFloat) -> CGFloat {
            guard rows > 0 else { return height / 2 }
            let slot = height / CGFloat(rows)
            return slot * (CGFloat(index) + 0.5)
        }

        func centerOfLeftNode(at index: Int, height: CGFloat) -> CGPoint {
            CGPoint(x: nodeWidth * 0.9, y: centerY(at: index, height: height))
        }

        func centerOfRightNode(at index: Int, height: CGFloat) -> CGPoint {
            CGPoint(x: nodeWidth + gutter + nodeWidth * 0.1, y: centerY(at: index, height: height))
        }
    }

    /// One node: a rounded chip naming an identity.
    private struct GraphNode: View {
        let title: String
        let symbol: String
        let color: Color

        var body: some View {
            HStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(color)
                Text(title)
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title)
        }
    }

    /// What the line colors mean.
    private var legend: some View {
        VStack(alignment: .leading, spacing: ZSpacing.xxs) {
            Text("A line connects a certificate to every profile that embeds it or shares its team.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            HStack(spacing: ZSpacing.sm) {
                Label("Healthy", systemImage: "circle.fill")
                    .foregroundStyle(.green)
                Label("Warning", systemImage: "circle.fill")
                    .foregroundStyle(.orange)
                Label("Blocked", systemImage: "circle.fill")
                    .foregroundStyle(.red)
            }
            .font(.caption2)
        }
        .accessibilityElement(children: .combine)
    }
}
