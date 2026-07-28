import NotchPalCore
import SwiftUI

/// A word with a highlight travelling through it: "Reading", "Editing", "Thinking".
///
/// This replaced a row of pulsing dots. Dots say *something is happening*; the
/// word says *what*, which is the entire point of the app. The shimmer carries
/// the "still going" signal that the dots used to, without spending the space on
/// punctuation.
struct ShimmerText: View {
    let text: String
    var font: Font = .system(size: 11, weight: .medium)
    var base: Color = .white.opacity(0.72)
    var active: Bool = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isAnimating: Bool { active && !reduceMotion }

    var body: some View {
        Text(text)
            .font(font)
            .foregroundStyle(base)
            .overlay { highlight }
            .animation(.smooth(duration: 0.25), value: text)
    }

    @ViewBuilder
    private var highlight: some View {
        if isAnimating {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                // One pass every 1.6s, with a beat of darkness between passes so
                // it reads as a pulse rather than a continuously scrolling band.
                let period = 1.6
                let phase = context.date.timeIntervalSinceReferenceDate
                    .truncatingRemainder(dividingBy: period) / period

                GeometryReader { proxy in
                    let width = proxy.size.width
                    let band = max(18, width * 0.55)

                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0),
                            .init(color: .white.opacity(0.85), location: 0.5),
                            .init(color: .clear, location: 1),
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: band)
                    .offset(x: -band + (width + band) * phase)
                }
                .blendMode(.plusLighter)
            }
            .mask {
                Text(text).font(font)
            }
            .allowsHitTesting(false)
        }
    }
}

/// A monospaced, digit-stable duration that rolls rather than redraws.
struct DurationLabel: View {
    var seconds: TimeInterval
    var font: Font = .system(size: 11, weight: .medium)

    var body: some View {
        Text(Format.duration(seconds))
            .font(font)
            .monospacedDigit()
            .contentTransition(.numericText(countsDown: false))
            .animation(.snappy(duration: 0.22), value: Int(seconds))
    }
}
