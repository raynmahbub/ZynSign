import SwiftUI

/// The Home command center's building blocks.
///
/// These are the pieces the dashboard is assembled from, kept apart from the
/// screen that decides what goes on it. Each takes plain values — a count, a
/// title, a closure — and never a domain type, so the same parts serve the
/// Home screen, a future widget, and previews.
///
/// The layout follows a fixed vertical order: a wordmark, a row of counts, an
/// attention row when something needs it, the import target, a direct-link
/// field, and the action rows. Everything below is optional and appears only
/// when it has something to say.

// MARK: - Counts

/// One square in the counts row: a tinted symbol, the number, and its name.
///
/// The number is what the screen is read for, so it takes the strong type
/// and the label takes the quiet one. A value that has not been read yet
/// shows a skeleton rather than a zero, so "none" and "not loaded" never look
/// the same.
struct ZHomeStatTile: View {

    let symbol: String
    let title: String
    let value: Int?
    let tint: Color
    var action: () -> Void = {}

    var body: some View {
        Button(action: action) {
            VStack(spacing: ZSpacing.xs) {
                Image(systemName: symbol)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(tint)
                    .frame(width: 44, height: 44)
                    .background(tint.opacity(0.16), in: RoundedRectangle(cornerRadius: ZRadius.card, style: .continuous))
                    .accessibilityHidden(true)
                Group {
                    if let value {
                        Text("\(value)")
                            .font(.system(.title, design: .rounded).weight(.bold))
                            .monospacedDigit()
                    } else {
                        // Not loaded yet. A neutral block rather than a zero,
                        // so "none" and "not read yet" never look alike.
                        RoundedRectangle(cornerRadius: ZRadius.xs, style: .continuous)
                            .fill(Color.secondary.opacity(0.18))
                            .frame(width: 34, height: 22)
                    }
                }
                .frame(height: 28)
                Text(title)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, ZSpacing.md)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .zComfortableHitTarget()
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityTitle)
    }

    private var accessibilityTitle: String {
        guard let value else { return "\(title), not loaded" }
        return "\(title): \(value)"
    }
}

// MARK: - Attention row

/// The one row that may want the user: work waiting, updates ready, a
/// problem worth surfacing. It is the only element on the screen with a
/// tinted border, so it reads as a prompt rather than as another card.
struct ZHomeAttentionRow: View {

    let symbol: String
    let title: String
    let subtitle: String
    let count: Int?
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: ZSpacing.md) {
                Image(systemName: symbol)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(tint)
                    .frame(width: 44, height: 44)
                    .background(tint.opacity(0.16), in: RoundedRectangle(cornerRadius: ZRadius.card, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: ZSpacing.sm)
                if let count, count > 0 {
                    Text("\(count)")
                        .font(.subheadline.weight(.bold))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .frame(minWidth: 30, minHeight: 30)
                        .background(tint, in: Circle())
                        .accessibilityHidden(true)
                }
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .padding(ZSpacing.md)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .zComfortableHitTarget()
        .background(ZColors.cardBackground, in: RoundedRectangle(cornerRadius: ZRadius.lg, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: ZRadius.lg, style: .continuous)
                .stroke(tint.opacity(0.55), lineWidth: 1.5)
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens the download center.")
    }
}

// MARK: - Import target

/// The primary import target: a dashed field with a circular add button.
///
/// The dashed border is the affordance and the hit target is the whole
/// field, so a tap anywhere in it opens the picker — the button is the
/// focus of it, not a separate, smaller target.
struct ZHomeImportTarget: View {

    let onImport: () -> Void

    @State private var isTargeted = false

    var body: some View {
        Button(action: onImport) {
            VStack(spacing: ZSpacing.sm) {
                Image(systemName: "plus")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(ZHomeTint.accent)
                    .frame(width: 64, height: 64)
                    .background(ZHomeTint.accent.opacity(0.14), in: Circle())
                    .overlay {
                        Circle().stroke(ZHomeTint.accent.opacity(0.35), lineWidth: 1)
                    }
                    .accessibilityHidden(true)
                Text("Import IPA / TIPA")
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text("Tap to browse or drag & drop files")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, ZSpacing.xl)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .zComfortableHitTarget()
        .background {
            RoundedRectangle(cornerRadius: ZRadius.lg, style: .continuous)
                .fill(isTargeted ? ZHomeTint.accent.opacity(0.08) : Color.clear)
        }
        .overlay {
            RoundedRectangle(cornerRadius: ZRadius.lg, style: .continuous)
                .strokeBorder(
                    isTargeted ? ZHomeTint.accent : Color.secondary.opacity(0.45),
                    style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])
                )
        }
        .importDropTarget(.none, isTargeted: $isTargeted)
        .animation(ZMotion.fast, value: isTargeted)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Import IPA or TIPA")
        .accessibilityHint("Opens the file picker. Files can also be dropped here.")
    }
}

// MARK: - Direct link

/// A single field for a direct `.ipa` link.
///
/// This is not a download button in disguise: submitting hands the link to
/// the Download Center, which is where a transfer lives from then on. The
/// field says so, so nobody expects the package to appear immediately.
struct ZHomeDirectLinkField: View {

    @Binding var text: String
    let isSubmitting: Bool
    let onSubmit: (String) -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: ZSpacing.sm) {
            Image(systemName: "link")
                .font(.callout)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("https://example.com/app.ipa", text: $text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .textContentType(.URL)
                .submitLabel(.go)
                .focused($isFocused)
                .onSubmit(submit)
                .disabled(isSubmitting)
            if isSubmitting {
                ProgressView().controlSize(.small)
            } else if !text.isEmpty {
                Button(action: submit) {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear the link field")
            }
        }
        .padding(.horizontal, ZSpacing.md)
        .frame(minHeight: 44)
        .background(ZColors.cardBackground, in: RoundedRectangle(cornerRadius: ZRadius.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: ZRadius.card, style: .continuous)
                .stroke(isFocused ? ZHomeTint.accent : Color.primary.opacity(0.06), lineWidth: isFocused ? 1.5 : 0.5)
        }
        .animation(ZMotion.fast, value: isFocused)
    }

    private func submit() {
        let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty, !isSubmitting else { return }
        isFocused = false
        onSubmit(raw)
    }
}

// MARK: - Action rows

/// One row of the action list: a tinted symbol well, a title, a hint, and a
/// chevron. The whole row is the target.
struct ZHomeActionRow: View {

    let title: String
    let subtitle: String
    let symbol: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: ZSpacing.md) {
                Image(systemName: symbol)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(tint)
                    .frame(width: 44, height: 44)
                    .background(tint.opacity(0.16), in: RoundedRectangle(cornerRadius: ZRadius.card, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: ZSpacing.sm)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .padding(ZSpacing.md)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .zComfortableHitTarget()
        .zynCardBackground(cornerRadius: ZRadius.lg)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Tints

/// The colors the command center assigns meaning with.
///
/// A tile's color says what kind of thing it is — repositories, identities,
/// applications — and the accent says "this is the thing to do". They are
/// fixed rather than derived so the same subject keeps the same color on
/// every screen, which is the only way the colors can be read as meaning
/// anything.
enum ZHomeTint {
    /// The app's own accent, used for the primary action.
    static let accent = ZynBrand.indigoTop
    /// Repositories and app sources.
    static let sources = Color(red: 1.0, green: 0.23, blue: 0.45)
    /// Signing identities.
    static let certificates = Color(red: 0.61, green: 0.35, blue: 0.95)
    /// Imported applications.
    static let apps = Color(red: 0.13, green: 0.78, blue: 0.51)
    /// Anything that is a problem or needs attention.
    static let attention = Color(red: 1.0, green: 0.23, blue: 0.45)
    /// Provisioning profiles.
    static let profiles = Color(red: 0.35, green: 0.56, blue: 0.98)
}
