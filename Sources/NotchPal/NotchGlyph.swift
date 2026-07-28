import SwiftUI

/// NotchPal's own mark: a menu bar line that dips into a notch and comes back out.
///
/// Drawn rather than borrowed from SF Symbols, so it reads as this app and not as
/// a generic rectangle. The proportions here are identical to the app icon's —
/// `Scripts/make-icon.swift` renders the same construction at 1024pt — so the
/// status item and the icon in the Dock are one mark, not two that resemble each
/// other.
///
/// The shoulders stay tight and the floor stays generous on purpose: even radii
/// turn the glyph into a wave, and a notch needs a fast drop and a flat bottom.
struct NotchGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()

        let inset = rect.width * 0.24 // half the notch's width
        let depth = rect.height * 0.82
        let shoulder = rect.height * 0.16
        let base = rect.height * 0.27

        // The bare polyline; the tangent-arc form fillets each corner so the
        // curves are guaranteed to meet both segments cleanly at any size.
        let start = CGPoint(x: rect.minX, y: rect.minY)
        let leftTop = CGPoint(x: rect.midX - inset, y: rect.minY)
        let leftBottom = CGPoint(x: rect.midX - inset, y: rect.minY + depth)
        let rightBottom = CGPoint(x: rect.midX + inset, y: rect.minY + depth)
        let rightTop = CGPoint(x: rect.midX + inset, y: rect.minY)
        let end = CGPoint(x: rect.maxX, y: rect.minY)

        path.move(to: start)
        path.addArc(tangent1End: leftTop, tangent2End: leftBottom, radius: shoulder)
        path.addArc(tangent1End: leftBottom, tangent2End: rightBottom, radius: base)
        path.addArc(tangent1End: rightBottom, tangent2End: rightTop, radius: base)
        path.addArc(tangent1End: rightTop, tangent2End: end, radius: shoulder)
        path.addLine(to: end)

        // Returned as a filled outline so callers can use `.fill()` and have the
        // menu bar treat it as a template image.
        return path.strokedPath(
            .init(lineWidth: max(1.3, rect.width * 0.075), lineCap: .round, lineJoin: .round)
        )
    }
}
