import Foundation

/// The team an Apple developer certificate declares about its owner.
///
/// Apple issues code-signing certificates with the team encoded in the
/// certificate's own subject: the ten-character **Team ID** appears as an
/// organizational-unit (OU) attribute, and the **team name** — the account
/// or organization the certificate belongs to — appears as the organization
/// (O) attribute. Some certificates, in particular ones crafted outside
/// Apple's tooling, carry the Team ID only inside the common name as a
/// trailing `(TEAMID)` group.
///
/// This type extracts what the subject actually declares and nothing else.
/// It does not contact Apple, does not evaluate whether the team still
/// exists, and does not treat an absent value as an error: a certificate
/// with no recognisable team information is a certificate with `teamID`
/// and `teamName` both `nil`, shown as such rather than invented.
struct CertificateTeamIdentity: Equatable, Hashable {

    /// The team identifier as declared by the certificate, upper-cased to
    /// the canonical form, or `nil` when the subject declares none ZynSign
    /// can recognise.
    let teamID: String?

    /// The team name as declared by the certificate — the organization
    /// attribute, or, failing that, the name before a valid `(TEAMID)`
    /// group in the common name — or `nil` when the subject declares none.
    let teamName: String?

    /// Whether the subject declared any recognisable team information.
    var hasTeamInformation: Bool { teamID != nil || teamName != nil }

    /// Extracts the team identity a subject declares.
    ///
    /// The rules, in order:
    /// 1. Team ID — the first organizational-unit attribute whose value
    ///    reads as a valid Team ID. When none does, a trailing `(TEAMID)`
    ///    group in the common name, when it reads as a valid Team ID.
    /// 2. Team name — the organization attribute. When absent, the name
    ///    before a valid trailing `(TEAMID)` group in the common name, so a
    ///    certificate that names its team only in the common name still
    ///    shows a name. A bare common name that declares neither is not a
    ///    team name: the identity is shown by its certificate name instead.
    static func from(_ subject: CertificateDistinguishedName) -> CertificateTeamIdentity {
        var teamID: String?
        for attribute in subject.attributes where attribute.recognition == .organizationalUnit {
            if let text = attribute.text,
               let candidate = normalizedCandidate(text),
               isValidTeamID(candidate) {
                teamID = candidate
                break
            }
        }

        var teamName: String?
        if let organization = subject.organization, !organization.isEmpty {
            teamName = organization
        }
        if teamName == nil, let commonName = subject.commonName,
           let (name, token) = trailingTeamIDGroup(in: commonName) {
            let candidate = token.uppercased()
            if isValidTeamID(candidate) {
                if teamID == nil {
                    teamID = candidate
                }
                teamName = name.isEmpty ? nil : name
            }
        }

        return CertificateTeamIdentity(teamID: teamID, teamName: teamName)
    }

    /// Whether `candidate` reads as an Apple Team ID: exactly ten
    /// alphanumeric characters. The check is deliberately conservative —
    /// it recognises the shape, and nothing more; shape is all a
    /// certificate can offer without contacting Apple.
    static func isValidTeamID(_ candidate: String) -> Bool {
        let value = candidate.uppercased()
        guard value.count == 10 else { return false }
        return value.allSatisfy { $0.isLetter || $0.isNumber }
    }

    /// Trims and upper-cases a candidate Team ID, or returns `nil` for a
    /// value that is empty after trimming.
    private static func normalizedCandidate(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.uppercased()
    }

    /// Splits `text` on a trailing `(token)` group. Returns the name before
    /// the group (trimmed) and the token, or `nil` when `text` does not
    /// end with a non-empty parenthesised group.
    static func trailingTeamIDGroup(in text: String) -> (name: String, token: String)? {
        guard let open = text.lastIndex(of: "(") else { return nil }
        guard text.hasSuffix(")") else { return nil }
        guard text.index(after: open) < text.endIndex else { return nil }
        let token = text[text.index(after: open)..<text.index(before: text.endIndex)]
        guard !token.isEmpty else { return nil }
        let name = text[..<open].trimmingCharacters(in: .whitespaces)
        return (name, String(token))
    }
}
