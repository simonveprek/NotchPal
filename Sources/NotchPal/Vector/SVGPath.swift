import CoreGraphics
import Foundation

/// A small, complete SVG path-data parser.
///
/// The brand marks NotchPal draws are published as single `<path d="…">` elements.
/// Re-tracing them by hand would put the logos subtly wrong, and shipping PNGs
/// would put them softly wrong at Retina sizes and in dark mode. Parsing the real
/// path data keeps them exact at any size, in any tint, with no binary assets.
///
/// Supports the full grammar: `M m L l H h V v C c S s Q q T t A a Z z`, implicit
/// repeated argument sets, and unseparated negative numbers (`4.71-2.64`).
enum SVGPath {
    static func path(from data: String) -> CGPath {
        var parser = Parser(data)
        return parser.run()
    }

    private struct Parser {
        private let bytes: [UInt8]
        private var index = 0

        private let path = CGMutablePath()
        private var current = CGPoint.zero
        private var subpathStart = CGPoint.zero
        /// Reflection anchors for the smooth-curve commands.
        private var lastCubicControl: CGPoint?
        private var lastQuadControl: CGPoint?

        init(_ string: String) {
            bytes = Array(string.utf8)
        }

        mutating func run() -> CGPath {
            var command: UInt8 = 0
            while true {
                skipSeparators()
                guard index < bytes.count else { break }

                if isCommand(bytes[index]) {
                    command = bytes[index]
                    index += 1
                } else if command == 0 {
                    break // Data before any command; nothing sensible to do.
                } else if command == UInt8(ascii: "M") {
                    command = UInt8(ascii: "L") // Extra pairs after M are implicit line-tos.
                } else if command == UInt8(ascii: "m") {
                    command = UInt8(ascii: "l")
                }

                guard apply(command) else { break }
            }
            return path.copy() ?? path
        }

        // MARK: Commands

        private mutating func apply(_ command: UInt8) -> Bool {
            let relative = command >= UInt8(ascii: "a")
            switch command | 0x20 { // lowercase
            case UInt8(ascii: "m"):
                guard let p = point(relative) else { return false }
                path.move(to: p)
                current = p
                subpathStart = p
                lastCubicControl = nil
                lastQuadControl = nil

            case UInt8(ascii: "l"):
                guard let p = point(relative) else { return false }
                path.addLine(to: p)
                current = p
                lastCubicControl = nil
                lastQuadControl = nil

            case UInt8(ascii: "h"):
                guard let x = number() else { return false }
                let p = CGPoint(x: relative ? current.x + x : x, y: current.y)
                path.addLine(to: p)
                current = p
                lastCubicControl = nil
                lastQuadControl = nil

            case UInt8(ascii: "v"):
                guard let y = number() else { return false }
                let p = CGPoint(x: current.x, y: relative ? current.y + y : y)
                path.addLine(to: p)
                current = p
                lastCubicControl = nil
                lastQuadControl = nil

            case UInt8(ascii: "c"):
                guard let c1 = point(relative), let c2 = point(relative), let end = point(relative) else { return false }
                path.addCurve(to: end, control1: c1, control2: c2)
                current = end
                lastCubicControl = c2
                lastQuadControl = nil

            case UInt8(ascii: "s"):
                guard let c2 = point(relative), let end = point(relative) else { return false }
                let c1 = reflect(lastCubicControl)
                path.addCurve(to: end, control1: c1, control2: c2)
                current = end
                lastCubicControl = c2
                lastQuadControl = nil

            case UInt8(ascii: "q"):
                guard let c = point(relative), let end = point(relative) else { return false }
                path.addQuadCurve(to: end, control: c)
                current = end
                lastQuadControl = c
                lastCubicControl = nil

            case UInt8(ascii: "t"):
                guard let end = point(relative) else { return false }
                let c = reflect(lastQuadControl)
                path.addQuadCurve(to: end, control: c)
                current = end
                lastQuadControl = c
                lastCubicControl = nil

            case UInt8(ascii: "a"):
                guard
                    let rx = number(), let ry = number(), let rotation = number(),
                    let largeArc = flag(), let sweep = flag(),
                    let end = point(relative)
                else { return false }
                addArc(to: end, rx: rx, ry: ry, rotation: rotation, largeArc: largeArc, sweep: sweep)
                current = end
                lastCubicControl = nil
                lastQuadControl = nil

            case UInt8(ascii: "z"):
                path.closeSubpath()
                current = subpathStart
                lastCubicControl = nil
                lastQuadControl = nil

            default:
                return false
            }
            return true
        }

        private func reflect(_ control: CGPoint?) -> CGPoint {
            // With no previous curve the control point coincides with the current point.
            guard let control else { return current }
            return CGPoint(x: 2 * current.x - control.x, y: 2 * current.y - control.y)
        }

        /// Endpoint-to-centre conversion, then a fan of cubics — the W3C
        /// implementation notes (SVG 1.1, F.6.5) transcribed.
        private mutating func addArc(
            to end: CGPoint,
            rx: CGFloat,
            ry: CGFloat,
            rotation: CGFloat,
            largeArc: Bool,
            sweep: Bool
        ) {
            let start = current
            guard start != end else { return }
            var rx = abs(rx), ry = abs(ry)
            guard rx > 0, ry > 0 else {
                path.addLine(to: end)
                return
            }

            let phi = rotation * .pi / 180
            let cosPhi = cos(phi), sinPhi = sin(phi)

            let dx = (start.x - end.x) / 2, dy = (start.y - end.y) / 2
            let x1 = cosPhi * dx + sinPhi * dy
            let y1 = -sinPhi * dx + cosPhi * dy

            // Scale up radii that are too small to span the two endpoints.
            let lambda = (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry)
            if lambda > 1 {
                let scale = sqrt(lambda)
                rx *= scale
                ry *= scale
            }

            let numerator = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1
            let denominator = rx * rx * y1 * y1 + ry * ry * x1 * x1
            let coefficient = (largeArc != sweep ? 1.0 : -1.0) * sqrt(max(0, numerator / denominator))

            let cx1 = coefficient * rx * y1 / ry
            let cy1 = -coefficient * ry * x1 / rx
            let cx = cosPhi * cx1 - sinPhi * cy1 + (start.x + end.x) / 2
            let cy = sinPhi * cx1 + cosPhi * cy1 + (start.y + end.y) / 2

            func angle(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat {
                let dot = ux * vx + uy * vy
                let length = sqrt((ux * ux + uy * uy) * (vx * vx + vy * vy))
                guard length > 0 else { return 0 }
                let value = acos(min(1, max(-1, dot / length)))
                return (ux * vy - uy * vx < 0) ? -value : value
            }

            let ux = (x1 - cx1) / rx, uy = (y1 - cy1) / ry
            let vx = (-x1 - cx1) / rx, vy = (-y1 - cy1) / ry
            var theta = angle(1, 0, ux, uy)
            var sweepAngle = angle(ux, uy, vx, vy)
            if !sweep, sweepAngle > 0 { sweepAngle -= 2 * .pi }
            if sweep, sweepAngle < 0 { sweepAngle += 2 * .pi }

            // A cubic approximates at most a quarter turn well.
            let segments = max(1, Int(ceil(abs(sweepAngle) / (.pi / 2))))
            let delta = sweepAngle / CGFloat(segments)
            let alpha = 4.0 / 3.0 * tan(delta / 4)

            func ellipse(_ t: CGFloat) -> (point: CGPoint, derivative: CGPoint) {
                let cosT = cos(t), sinT = sin(t)
                return (
                    CGPoint(
                        x: cx + rx * cosPhi * cosT - ry * sinPhi * sinT,
                        y: cy + rx * sinPhi * cosT + ry * cosPhi * sinT
                    ),
                    CGPoint(
                        x: -rx * cosPhi * sinT - ry * sinPhi * cosT,
                        y: -rx * sinPhi * sinT + ry * cosPhi * cosT
                    )
                )
            }

            for _ in 0 ..< segments {
                let from = ellipse(theta)
                let to = ellipse(theta + delta)
                path.addCurve(
                    to: to.point,
                    control1: CGPoint(x: from.point.x + alpha * from.derivative.x, y: from.point.y + alpha * from.derivative.y),
                    control2: CGPoint(x: to.point.x - alpha * to.derivative.x, y: to.point.y - alpha * to.derivative.y)
                )
                theta += delta
            }
        }

        // MARK: Lexing

        private func isCommand(_ byte: UInt8) -> Bool {
            switch byte | 0x20 {
            case UInt8(ascii: "m"), UInt8(ascii: "l"), UInt8(ascii: "h"), UInt8(ascii: "v"),
                 UInt8(ascii: "c"), UInt8(ascii: "s"), UInt8(ascii: "q"), UInt8(ascii: "t"),
                 UInt8(ascii: "a"), UInt8(ascii: "z"):
                true
            default:
                false
            }
        }

        private mutating func skipSeparators() {
            while index < bytes.count {
                switch bytes[index] {
                case 0x20, 0x09, 0x0A, 0x0D, UInt8(ascii: ","):
                    index += 1
                default:
                    return
                }
            }
        }

        private mutating func point(_ relative: Bool) -> CGPoint? {
            guard let x = number(), let y = number() else { return nil }
            return relative ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
        }

        /// Arc flags are single characters and may run straight into the next
        /// number — `a5 5 0 0 0-.5-4.9` is five tokens, not three.
        private mutating func flag() -> Bool? {
            skipSeparators()
            guard index < bytes.count else { return nil }
            switch bytes[index] {
            case UInt8(ascii: "0"): index += 1; return false
            case UInt8(ascii: "1"): index += 1; return true
            default: return nil
            }
        }

        private mutating func number() -> CGFloat? {
            skipSeparators()
            let start = index
            if index < bytes.count, bytes[index] == UInt8(ascii: "+") || bytes[index] == UInt8(ascii: "-") {
                index += 1
            }
            var sawDigit = false
            while index < bytes.count, bytes[index] >= 0x30, bytes[index] <= 0x39 {
                index += 1
                sawDigit = true
            }
            if index < bytes.count, bytes[index] == UInt8(ascii: ".") {
                index += 1
                while index < bytes.count, bytes[index] >= 0x30, bytes[index] <= 0x39 {
                    index += 1
                    sawDigit = true
                }
            }
            guard sawDigit else {
                index = start
                return nil
            }
            if index < bytes.count, bytes[index] | 0x20 == UInt8(ascii: "e") {
                let mark = index
                index += 1
                if index < bytes.count, bytes[index] == UInt8(ascii: "+") || bytes[index] == UInt8(ascii: "-") {
                    index += 1
                }
                var sawExponent = false
                while index < bytes.count, bytes[index] >= 0x30, bytes[index] <= 0x39 {
                    index += 1
                    sawExponent = true
                }
                if !sawExponent { index = mark }
            }

            let text = String(decoding: bytes[start ..< index], as: UTF8.self)
            guard let value = Double(text) else {
                index = start
                return nil
            }
            return CGFloat(value)
        }
    }
}
