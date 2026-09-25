import SwiftUI
import UIKit

/// The icon of a library application, shown on cards and rows.
///
/// The image is the application's own icon, extracted read-only from the
/// package the library holds (`AppIconExtraction`) and cached, so cards
/// never re-open an archive while scrolling. Until — or unless — the bytes
/// arrive, the view shows a derived mark: the application's initials on a
/// colour pair chosen deterministically from the bundle identifier. The
/// fallback is honest by design — it never pretends to be the real icon,
/// it labels the application while the package's own artwork is being read,
/// and it stays when the package simply carries no readable icon.
///
/// The view is decorative: the row or card it sits in carries the
/// accessibility label.
struct ApplicationIconView: View {

    /// The artifact the icon is extracted from.
    let artifactID: ArtifactIdentifier

    /// The application's display name, for the fallback initials.
    let displayName: String

    /// The declared bundle identifier, which selects the fallback palette.
    let bundleIdentifier: String

    /// The square side length.
    var size: CGFloat = 52

    @Environment(\.applicationEnvironment) private var environment
    @State private var iconData: Data?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(LinearGradient(
                    colors: palette,
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ))
            if let data = iconData, let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Text(initials)
                    .font(.system(size: size * 0.36, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .padding(size * 0.08)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .accessibilityHidden(true)
        .task(id: artifactID) {
            iconData = await environment.appIcons?.iconData(for: artifactID)
        }
    }

    private var cornerRadius: CGFloat {
        size * 0.2237
    }

    /// Up to two initials from the display name; a single initial from the
    /// bundle identifier when the package declared no usable name.
    private var initials: String {
        let words = displayName.split(separator: " ").filter { !$0.isEmpty }
        if let first = words.first, first.count > 0 {
            let firstInitial = first.prefix(1)
            let secondInitial = words.count > 1 ? words[1].prefix(1) : ""
            return (firstInitial + secondInitial).uppercased()
        }
        let components = bundleIdentifier.split(separator: ".")
        if let last = components.last, let character = last.first {
            return String(character).uppercased()
        }
        return "·"
    }

    /// A two-colour pair derived from the bundle identifier, so the same
    /// application always shows the same mark. Derived hues stay in a
    /// band that keeps white initials legible in light and dark mode.
    private var palette: [Color] {
        var hasher = UInt32(0)
        for byte in bundleIdentifier.utf8 {
            hasher = (hasher &* 31) &+ UInt32(byte)
        }
        let hue = Double(hasher % 360) / 360
        let base = Color(hue: hue, saturation: 0.52, brightness: 0.82)
        let companion = Color(hue: (hue + 0.08).truncatingRemainder(dividingBy: 1), saturation: 0.6, brightness: 0.62)
        return [base, companion]
    }
}

#Preview("Monogram") {
    ApplicationIconView(
        artifactID: ArtifactIdentifier(),
        displayName: "Delta Mail",
        bundleIdentifier: "com.example.deltamail"
    )
}
