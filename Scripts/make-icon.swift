#!/usr/bin/env swift
//
// Draws NotchPal's app icon and writes Resources/AppIcon.icns.
//
//   swift Scripts/make-icon.swift
//
// The icon is code, not a binary asset, for the same reason the brand marks are:
// it stays crisp at every size, it can be re-rendered when the palette changes,
// and a reviewer can see what it is from the diff.
//
// The composition is the product in one glance — a notch, with one agent dot for
// Claude and one for Codex sitting inside it. At 16pt the silhouette and the two
// colours are all that survive, which is exactly the information that matters.

import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Palette

let bodyTop = CGColor(red: 0.176, green: 0.184, blue: 0.212, alpha: 1) // graphite, lit
let bodyBottom = CGColor(red: 0.070, green: 0.075, blue: 0.094, alpha: 1) // graphite, shadowed
let claude = CGColor(red: 0.851, green: 0.467, blue: 0.341, alpha: 1)
let codex = CGColor(red: 0.063, green: 0.639, blue: 0.498, alpha: 1)

// MARK: - Geometry

/// Apple's rounded rectangle is a squircle, not a circular-cornered rect. The
/// superellipse below (n = 5) is the standard approximation, and the difference
/// is obvious once the icon sits next to a system one.
func squircle(in rect: CGRect, n: Double = 5) -> CGPath {
    let path = CGMutablePath()
    let a = rect.width / 2, b = rect.height / 2
    let steps = 512

    for step in 0 ... steps {
        let t = Double(step) / Double(steps) * 2 * .pi
        let cosT = cos(t), sinT = sin(t)
        let x = a * copysign(pow(abs(cosT), 2 / n), cosT)
        let y = b * copysign(pow(abs(sinT), 2 / n), sinT)
        let point = CGPoint(x: rect.midX + x, y: rect.midY + y)
        step == 0 ? path.move(to: point) : path.addLine(to: point)
    }
    path.closeSubpath()
    return path
}

/// The notch glyph, identical in construction to `NotchGlyph` in the app: a menu
/// bar line that dips into a notch and comes back out. This is drawn as an open
/// path and stroked, not filled — the icon and the menu bar mark are the same
/// drawing at two sizes, which is the whole point of having a mark.
func notchGlyph(in rect: CGRect) -> CGPath {
    let path = CGMutablePath()
    let inset = rect.width * 0.24 // half the notch's width
    let depth = rect.height * 0.82
    // The shoulder stays tight and the base stays generous. Even radii turned the
    // glyph into a wave; a notch needs a fast drop and a flat floor.
    let shoulder = rect.height * 0.16
    let base = rect.height * 0.27

    // Corners of the bare polyline; `addArc(tangent1End:tangent2End:)` fillets
    // each one for us. Rolling the curves by hand is what produced the lumps —
    // the tangent form guarantees the arc actually meets both segments cleanly.
    let a = CGPoint(x: rect.minX, y: rect.minY)
    let b = CGPoint(x: rect.midX - inset, y: rect.minY)
    let c = CGPoint(x: rect.midX - inset, y: rect.minY + depth)
    let d = CGPoint(x: rect.midX + inset, y: rect.minY + depth)
    let e = CGPoint(x: rect.midX + inset, y: rect.minY)
    let f = CGPoint(x: rect.maxX, y: rect.minY)

    path.move(to: a)
    path.addArc(tangent1End: b, tangent2End: c, radius: shoulder)
    path.addArc(tangent1End: c, tangent2End: d, radius: base)
    path.addArc(tangent1End: d, tangent2End: e, radius: base)
    path.addArc(tangent1End: e, tangent2End: f, radius: shoulder)
    path.addLine(to: f)
    return path
}

// MARK: - Drawing

func drawIcon(size: CGFloat) -> CGImage {
    let scale = size / 1024
    let context = CGContext(
        data: nil,
        width: Int(size),
        height: Int(size),
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!

    // Work in a y-down space so the geometry above reads like the screen does.
    context.translateBy(x: 0, y: size)
    context.scaleBy(x: 1, y: -1)
    context.setAllowsAntialiasing(true)
    context.interpolationQuality = .high

    func s(_ value: CGFloat) -> CGFloat { value * scale }

    // macOS icon grid: the body fills 824 of the 1024pt canvas.
    let body = CGRect(x: s(100), y: s(100), width: s(824), height: s(824))
    let shape = squircle(in: body)

    // Body, lit from above.
    context.saveGState()
    context.addPath(shape)
    context.clip()
    let gradient = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
        colors: [bodyTop, bodyBottom] as CFArray,
        locations: [0, 1]
    )!
    context.drawLinearGradient(
        gradient,
        start: CGPoint(x: body.midX, y: body.minY),
        end: CGPoint(x: body.midX, y: body.maxY),
        options: []
    )
    context.restoreGState()

    // One element, centred: the glyph. Optically it sits a touch above the
    // geometric centre, because the notch hangs downward and carries the weight.
    let glyph = CGRect(
        x: body.midX - body.width * 0.58 / 2,
        y: body.midY - body.height * 0.28 / 2 - body.height * 0.04,
        width: body.width * 0.58,
        height: body.height * 0.28
    )

    context.saveGState()
    context.addPath(notchGlyph(in: glyph))
    context.setLineWidth(body.width * 0.040)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.replacePathWithStrokedPath()
    context.clip()

    // Monochrome. A coral-to-green stroke was tried — it names both agents, but
    // the two hues cross through a muddy olive at the midpoint, which is exactly
    // where the glyph's most important detail sits. Colour lives in the notch at
    // runtime, where it belongs; the icon stays quiet.
    context.setFillColor(CGColor(red: 0.95, green: 0.95, blue: 0.97, alpha: 1))
    context.fill(glyph.insetBy(dx: -glyph.width, dy: -glyph.height))
    context.restoreGState()

    // Edge light. Enough to separate the icon from a dark desktop, no more.
    context.saveGState()
    context.addPath(shape)
    context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.12))
    context.setLineWidth(max(1, s(2)))
    context.strokePath()
    context.restoreGState()

    return context.makeImage()!
}

// MARK: - Output

func write(_ image: CGImage, to url: URL) {
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
}

let root = URL(filePath: FileManager.default.currentDirectoryPath)
let resources = root.appending(path: "Resources")
let iconset = resources.appending(path: "AppIcon.iconset")
try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

// Every size is drawn from the vector routine rather than downsampled, so the
// small ones stay sharp instead of turning to mush.
for base in [16, 32, 64, 128, 256, 512] {
    write(drawIcon(size: CGFloat(base)), to: iconset.appending(path: "icon_\(base)x\(base).png"))
    write(drawIcon(size: CGFloat(base * 2)), to: iconset.appending(path: "icon_\(base)x\(base)@2x.png"))
}
// A 1024 master for the README, the App Store, and anywhere else it is needed.
write(drawIcon(size: 1024), to: resources.appending(path: "AppIcon.png"))

let iconutil = Process()
iconutil.executableURL = URL(filePath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path(percentEncoded: false),
                      "-o", resources.appending(path: "AppIcon.icns").path(percentEncoded: false)]
try iconutil.run()
iconutil.waitUntilExit()

print(iconutil.terminationStatus == 0
    ? "Wrote Resources/AppIcon.icns and Resources/AppIcon.png"
    : "iconutil failed with status \(iconutil.terminationStatus)")
