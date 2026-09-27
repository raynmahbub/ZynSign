import SwiftUI

/// The four bespoke empty-state illustrations, drawn as a single line in
/// the Z·Pen language: one stroke weight, rounded caps, the brand's diagonal
/// as the recurring gesture. Vector, so they scale with Dynamic Type and
/// stay crisp on every device; monochrome in the tint, so they read in
/// high-contrast and colour-blind settings without depending on hue.
///
/// Each case is a `Shape`, which means no bitmaps in the asset catalog and
/// nothing to re-export when the accent changes.
enum ZEmptyIllustration: CaseIterable, Sendable {

    /// A stack of app tiles, the top one empty, the Z·Pen diagonal in front.
    case noApps
    /// A certificate card with a seal — the seal's ribbon is the Z diagonal.
    case noCertificates
    /// A tray with a dotted arrow that never arrived.
    case noDownloads
    /// Two nodes waiting for a connection.
    case noSources

    /// The line-art drawn at a given size. `lineWidth` scales with size so
    /// the drawing keeps the same weight at 88 pt and at 160 pt.
    @ViewBuilder
    func view(size: CGFloat, tint: Color) -> some View {
        let line = max(2, size * 0.028)
        ZStack {
            shape
                .stroke(tint.opacity(0.9), style: StrokeStyle(lineWidth: line, lineCap: .round, lineJoin: .round))
            accentShape
                .stroke(tint, style: StrokeStyle(lineWidth: line * 1.35, lineCap: .round, lineJoin: .round))
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private var shape: some Shape {
        switch self {
        case .noApps: return AnyShape(NoAppsShape())
        case .noCertificates: return AnyShape(NoCertificatesShape())
        case .noDownloads: return AnyShape(NoDownloadsShape())
        case .noSources: return AnyShape(NoSourcesShape())
        }
    }

    /// The single heavier stroke every illustration carries: the Z·Pen diagonal.
    private var accentShape: some Shape {
        AnyShape(ZDiagonalShape(kind: self))
    }
}

// MARK: - Shapes (all in a 0…1 unit square)

private extension CGRect {
    func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(x: minX + width * x, y: minY + height * y)
    }
    func sub(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
        CGRect(x: minX + width * x, y: minY + height * y, width: width * w, height: height * h)
    }
}

private struct NoAppsShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let r = rect.width * 0.07
        // Three stacked tiles, offset like a fanned deck.
        p.addRoundedRect(in: rect.sub(0.30, 0.10, 0.44, 0.44), cornerSize: CGSize(width: r, height: r))
        p.addRoundedRect(in: rect.sub(0.22, 0.24, 0.44, 0.44), cornerSize: CGSize(width: r, height: r))
        p.addRoundedRect(in: rect.sub(0.14, 0.38, 0.44, 0.44), cornerSize: CGSize(width: r, height: r))
        // A dotted "add" hint in the front tile.
        p.move(to: rect.point(0.36, 0.53)); p.addLine(to: rect.point(0.36, 0.67))
        p.move(to: rect.point(0.29, 0.60)); p.addLine(to: rect.point(0.43, 0.60))
        return p
    }
}

private struct NoCertificatesShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let r = rect.width * 0.06
        p.addRoundedRect(in: rect.sub(0.12, 0.20, 0.76, 0.52), cornerSize: CGSize(width: r, height: r))
        // Two text lines.
        p.move(to: rect.point(0.24, 0.36)); p.addLine(to: rect.point(0.56, 0.36))
        p.move(to: rect.point(0.24, 0.46)); p.addLine(to: rect.point(0.48, 0.46))
        // The seal.
        p.addEllipse(in: rect.sub(0.62, 0.50, 0.20, 0.20))
        p.addEllipse(in: rect.sub(0.665, 0.545, 0.11, 0.11))
        // Ribbon tails.
        p.move(to: rect.point(0.67, 0.69)); p.addLine(to: rect.point(0.64, 0.84))
        p.move(to: rect.point(0.77, 0.69)); p.addLine(to: rect.point(0.80, 0.84))
        return p
    }
}

private struct NoDownloadsShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        // Tray.
        p.move(to: rect.point(0.16, 0.60))
        p.addLine(to: rect.point(0.16, 0.80))
        p.addQuadCurve(to: rect.point(0.22, 0.86), control: rect.point(0.16, 0.86))
        p.addLine(to: rect.point(0.78, 0.86))
        p.addQuadCurve(to: rect.point(0.84, 0.80), control: rect.point(0.84, 0.86))
        p.addLine(to: rect.point(0.84, 0.60))
        // Dotted descent that stops short.
        for i in 0..<4 {
            let y = 0.16 + CGFloat(i) * 0.10
            p.move(to: rect.point(0.50, y)); p.addLine(to: rect.point(0.50, y + 0.04))
        }
        return p
    }
}

private struct NoSourcesShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.addEllipse(in: rect.sub(0.10, 0.34, 0.24, 0.24))
        p.addEllipse(in: rect.sub(0.66, 0.34, 0.24, 0.24))
        // The link that isn't there yet, drawn as two short dashes.
        p.move(to: rect.point(0.38, 0.46)); p.addLine(to: rect.point(0.44, 0.46))
        p.move(to: rect.point(0.56, 0.46)); p.addLine(to: rect.point(0.62, 0.46))
        // Antenna arcs above the right node.
        p.addArc(center: rect.point(0.78, 0.46), radius: rect.width * 0.20, startAngle: .degrees(-120), endAngle: .degrees(-60), clockwise: false)
        p.addArc(center: rect.point(0.78, 0.46), radius: rect.width * 0.28, startAngle: .degrees(-118), endAngle: .degrees(-62), clockwise: false)
        return p
    }
}

/// The brand diagonal, placed where each drawing wants its emphasis.
private struct ZDiagonalShape: Shape {
    let kind: ZEmptyIllustration
    func path(in rect: CGRect) -> Path {
        var p = Path()
        switch kind {
        case .noApps:
            p.move(to: rect.point(0.62, 0.90)); p.addLine(to: rect.point(0.92, 0.60))
        case .noCertificates:
            p.move(to: rect.point(0.24, 0.60)); p.addLine(to: rect.point(0.40, 0.44))
        case .noDownloads:
            p.move(to: rect.point(0.40, 0.56)); p.addLine(to: rect.point(0.50, 0.66)); p.addLine(to: rect.point(0.60, 0.56))
        case .noSources:
            p.move(to: rect.point(0.42, 0.70)); p.addLine(to: rect.point(0.58, 0.24))
        }
        return p
    }
}
