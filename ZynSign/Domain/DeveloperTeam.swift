import Foundation

/// One developer team, as the Identity Center groups identities under it.
///
/// The Team Workspace is the organising principle of the Identity Center:
/// every certificate and profile the user holds belongs to a team — the
/// ten-character Team ID their subject or payload declares — and the
/// workspace shows each team's certificates, its profiles, its summary,
/// and how many library applications its profiles can sign.
///
/// A team whose ID ZynSign could not recognise is still a team: it is
/// grouped under the "Ungrouped" bucket so nothing a user imported is ever
/// hidden or invented into a team it did not declare. The grouping reads
/// declarations only; it never contacts Apple and never decides trust.
struct DeveloperTeam: Equatable, Hashable, Identifiable, Sendable {

    /// The identity key for the bucket that holds certificates and
    /// profiles whose Team ID ZynSign could not recognise.
    static let ungroupedIdentifier = "zynsign.team.ungrouped"

    /// The Team ID the members declare — the first spelling seen — or
    /// `nil` when none of them declared one ZynSign could recognise.
    let teamID: String?

    /// The team name, when any member declared one. When members disagree
    /// the first non-empty name in member order wins, and the conflict
    /// detector reports the disagreement separately.
    let teamName: String?

    /// The fingerprints of the team's certificates, in the order given.
    let certificateFingerprints: [String]

    /// The identifiers of the team's profiles, in the order given.
    let profileIDs: [ProvisioningProfileIdentifier]

    /// The stable identity of the group: the Team ID, or the ungrouped
    /// marker.
    var id: String { teamID ?? Self.ungroupedIdentifier }

    /// Whether this is the bucket for members with no recognisable team.
    var isUngrouped: Bool { teamID == nil }

    /// The name the workspace shows for the team.
    var displayName: String {
        if isUngrouped { return "Ungrouped" }
        if let teamName, !teamName.isEmpty { return teamName }
        return teamID ?? "Team"
    }

    /// How many identities the team holds, certificates and profiles
    /// together. The count a collapsed team row shows.
    var memberCount: Int {
        certificateFingerprints.count + profileIDs.count
    }

    /// Creates a team from its members.
    init(
        teamID: String?,
        teamName: String?,
        certificateFingerprints: [String],
        profileIDs: [ProvisioningProfileIdentifier]
    ) {
        self.teamID = teamID
        self.teamName = teamName
        self.certificateFingerprints = certificateFingerprints
        self.profileIDs = profileIDs
    }
}

/// Groups certificates and profiles into `DeveloperTeam` values.
///
/// The grouper is pure: it reads only the facts handed to it. Team IDs are
/// compared case-insensitively — Apple Team IDs are upper-case, but
/// certificates crafted outside Apple's tooling may spell them otherwise —
/// while the first spelling a member declared is preserved for display.
/// Teams come out sorted by display name with the ungrouped bucket last,
/// so the order is stable across refreshes however the underlying stores
/// list their members.
struct DeveloperTeamGrouper: Sendable {

    /// Groups `certificates` and `profiles` by the Team ID they declare.
    ///
    /// - Returns: One `DeveloperTeam` per distinct Team ID, plus the
    ///   ungrouped bucket when any member declares no recognisable Team
    ///   ID. Named teams sort alphabetically; the ungrouped bucket is last.
    func group(
        certificates: [IdentityCertificateFacts],
        profiles: [IdentityProfileFacts]
    ) -> [DeveloperTeam] {
        var order: [String] = []
        var seenKeys: Set<String> = []
        var displayedTeamIDs: [String: String] = [:]
        var teamNames: [String: String] = [:]
        var fingerprintLists: [String: [String]] = [:]
        var profileIDLists: [String: [ProvisioningProfileIdentifier]] = [:]

        func bucket(forTeamID teamID: String?) -> String {
            let key = teamID?.uppercased() ?? DeveloperTeam.ungroupedIdentifier
            if !seenKeys.contains(key) {
                seenKeys.insert(key)
                order.append(key)
                if let teamID { displayedTeamIDs[key] = teamID }
                fingerprintLists[key] = []
                profileIDLists[key] = []
            }
            return key
        }

        for certificate in certificates {
            let key = bucket(forTeamID: certificate.teamID)
            fingerprintLists[key]?.append(certificate.fingerprintHex)
            if teamNames[key] == nil, let declared = certificate.teamName, !declared.isEmpty {
                teamNames[key] = declared
            }
        }

        for profile in profiles {
            let key = bucket(forTeamID: profile.teamID)
            profileIDLists[key]?.append(profile.id)
            if teamNames[key] == nil, let declared = profile.teamName, !declared.isEmpty {
                teamNames[key] = declared
            }
        }

        let teams = order.map { key in
            DeveloperTeam(
                teamID: displayedTeamIDs[key],
                teamName: teamNames[key],
                certificateFingerprints: fingerprintLists[key] ?? [],
                profileIDs: profileIDLists[key] ?? []
            )
        }

        return teams.sorted { lhs, rhs in
            if lhs.isUngrouped != rhs.isUngrouped { return rhs.isUngrouped }
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName)
                == .orderedAscending
        }
    }
}
