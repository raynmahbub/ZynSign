import Foundation

/// Who a package says it comes from, as far as the package itself declares.
///
/// Two optional declarations inside an imported package name its origin:
/// the provisioning profile the package was last signed with
/// (`embedded.mobileprovision`, which names the development team) and the
/// store metadata some packages carry (`iTunesMetadata.plist`, which names
/// the developer). Provenance collects what those declare so the library
/// can search and filter by developer and team.
///
/// Like every other declaration in a package, these values are untrusted.
/// They identify nothing and prove nothing: a package can carry any text
/// here, and ZynSign verifies none of it. They are shown and searched as
/// what the package says, never as a finding. Each field is `nil` when the
/// package does not declare it, which is common — store packages carry no
/// provisioning profile, and packages built for testing carry no store
/// metadata.
struct ApplicationProvenance: Hashable, Sendable, Codable {

    /// The longest declared name kept, in characters.
    static let maximumNameLength = 128

    /// The longest team identifier accepted, in characters.
    static let maximumTeamIdentifierLength = 32

    /// The developer name the store metadata declares, when present.
    let developerName: String?

    /// The development team identifier the embedded profile declares.
    let teamIdentifier: String?

    /// The development team name the embedded profile declares.
    let teamName: String?

    /// Provenance for a package that declares none of the three values.
    static let unknown = ApplicationProvenance(developerName: nil, teamIdentifier: nil, teamName: nil)

    /// Records provenance, sanitising each declared value: names are
    /// trimmed, stripped of control characters, and bounded; a team
    /// identifier must be a short run of letters and digits. A value that
    /// fails its rule is dropped rather than repaired.
    init(developerName: String?, teamIdentifier: String?, teamName: String?) {
        self.developerName = Self.sanitizedName(developerName)
        self.teamIdentifier = Self.sanitizedTeamIdentifier(teamIdentifier)
        self.teamName = Self.sanitizedName(teamName)
    }

    /// Whether the package declared nothing usable.
    var isEmpty: Bool {
        developerName == nil && teamIdentifier == nil && teamName == nil
    }

    /// The name to show for who made the application: the declared
    /// developer, or else the declared team name.
    var displayDeveloper: String? {
        developerName ?? teamName
    }

    /// A declared name made safe to show: surrounding whitespace removed,
    /// line breaks and control characters dropped, bounded in length.
    static func sanitizedName(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let words = raw.split(whereSeparator: { $0.isWhitespace })
        var scalars = String.UnicodeScalarView()
        scalars.append(contentsOf: words.joined(separator: " ").unicodeScalars.filter {
            $0.properties.generalCategory != .control
        })
        let cleaned = String(scalars)
        guard !cleaned.isEmpty else { return nil }
        return String(cleaned.prefix(maximumNameLength))
    }

    /// A declared team identifier, accepted only when it is a short run of
    /// ASCII letters and digits — the shape Apple team identifiers take.
    static func sanitizedTeamIdentifier(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.count <= maximumTeamIdentifierLength,
              trimmed.unicodeScalars.allSatisfy({ $0.isASCII && CharacterSet.alphanumerics.contains($0) })
        else {
            return nil
        }
        return trimmed
    }
}
