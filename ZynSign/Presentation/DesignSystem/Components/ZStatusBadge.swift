import SwiftUI

/// Semantic status pill — the only place semantic colors are chosen.
///
/// Never use `.green/.orange/.red` directly in a row; use `ZStatusBadge`.
struct ZStatusBadge: View {
    enum Kind {
        case success, warning, error, neutral, info, unsupported
        var color: Color {
            switch self {
            case .success: return .green
            case .warning: return .orange
            case .error: return .red
            case .neutral: return .secondary
            case .info: return .blue
            case .unsupported: return .purple
            }
        }
        var background: Color {
            switch self {
            case .success: return .green.opacity(0.15)
            case .warning: return .orange.opacity(0.15)
            case .error: return .red.opacity(0.15)
            case .neutral: return Color(.tertiarySystemFill)
            case .info: return .blue.opacity(0.12)
            case .unsupported: return .purple.opacity(0.14)
            }
        }
    }

    let text: String
    let systemImage: String?
    let kind: Kind

    init(_ text: String, systemImage: String? = nil, kind: Kind) {
        self.text = text; self.systemImage = systemImage; self.kind = kind
    }

    var body: some View {
        Label {
            Text(text).font(.caption2.weight(.semibold)).lineLimit(1)
        } icon: {
            if let systemImage { Image(systemName: systemImage).font(.caption2) }
        }
        .labelStyle(.titleAndIcon)
        .foregroundStyle(kind.color)
        .padding(.horizontal, ZSpacing.xs)
        .padding(.vertical, 4)
        .background(kind.background, in: Capsule())
        .accessibilityLabel(text)
    }
}

// Convenience presets for ZynSign domain
extension ZStatusBadge {
    static func ready(_ text: String = "Ready") -> ZStatusBadge { ZStatusBadge(text, systemImage: "checkmark.shield.fill", kind: .success) }
    static func needsAttention(_ text: String = "Needs Attention") -> ZStatusBadge { ZStatusBadge(text, systemImage: "exclamationmark.shield", kind: .warning) }
    static func matched() -> ZStatusBadge { ZStatusBadge("Matched", systemImage: "link", kind: .success) }
    static func mismatch() -> ZStatusBadge { ZStatusBadge("Mismatch", systemImage: "link", kind: .error) }
    static func valid(days: Int? = nil) -> ZStatusBadge {
        if let days { return ZStatusBadge("\(days)d left", systemImage: "calendar", kind: days < 30 ? .warning : .success) }
        return ZStatusBadge("Valid", systemImage: "calendar", kind: .success)
    }
}
