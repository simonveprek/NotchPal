import NotchPalCore
import SwiftUI

/// Monotonic "time spent working", which pauses and resumes without jumping.
///
/// Every motion below is a pure function of this clock, so stopping mid-gesture
/// freezes rather than snapping back, and starting again picks up where it left.
struct MotionClock: Equatable {
    private var accumulated: TimeInterval = 0
    private var startedAt: Date?

    func elapsed(at date: Date) -> TimeInterval {
        accumulated + (startedAt.map { max(0, date.timeIntervalSince($0)) } ?? 0)
    }

    mutating func setRunning(_ running: Bool, at date: Date = .now) {
        guard running != (startedAt != nil) else { return }
        if running {
            startedAt = date
        } else {
            accumulated = elapsed(at: date)
            startedAt = nil
        }
    }
}

/// How a mark behaves while its agent is working.
///
/// The two agents move differently on purpose. You should be able to tell which
/// one is running out of the corner of your eye, before you have read anything —
/// so the motion is derived from each mark's own geometry rather than a shared
/// spinner dropped behind both.
private struct MarkMotion {
    var angle: Double = 0
    var scale: CGFloat = 1

    /// **Claude — pulse.** The radial burst nearly disappears, then expands past
    /// its resting size. The large range makes Claude unmistakably alive even in
    /// the compact notch, where the old subtle breath was easy to miss.
    static func breathe(at t: TimeInterval) -> MarkMotion {
        let period = 1.45
        let phase = t.truncatingRemainder(dividingBy: period) / period
        // A full cosine cycle is continuous at the seam: collapsed → expanded
        // → collapsed, with a soft turn at both extremes.
        let eased = 0.5 - 0.5 * cos(2 * .pi * phase)

        return MarkMotion(
            angle: t * 6,
            scale: 0.06 + 1.22 * eased
        )
    }

    /// **Codex — ratchet.** The knot has six-fold symmetry, so a sixth of a turn
    /// lands it exactly back on itself. Instead of sliding, it advances one notch
    /// at a time and rests: a mechanism stepping forward, not a wheel spinning.
    static func ratchet(at t: TimeInterval) -> MarkMotion {
        let interval = 0.95
        let step = floor(t / interval)
        let travel = interval * 0.55 // The remainder is the rest between steps.
        let progress = min(1, t.truncatingRemainder(dividingBy: interval) / travel)

        return MarkMotion(
            angle: (step + easeOutBack(progress)) * 60,
            scale: 1 - 0.055 * sin(.pi * progress)
        )
    }

    /// Overshoots slightly and settles, so each notch lands with weight.
    private static func easeOutBack(_ t: Double) -> Double {
        let c1 = 1.70158
        let c3 = c1 + 1
        return 1 + c3 * pow(t - 1, 3) + c1 * pow(t - 1, 2)
    }
}

/// The agent's mark, alive while it works.
struct AgentMarkView: View {
    let agent: Agent
    let accent: Color
    var size: CGFloat = 18
    var isBusy: Bool = false
    /// Bumped by the caller on every new tool call, to trigger the pop.
    var pulse: Int = 0
    var showsHalo: Bool = true

    @State private var clock = MotionClock()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: !isBusy || reduceMotion)) { context in
            let motion = motion(at: context.date)

            ZStack {
                if showsHalo {
                    Circle()
                        .fill(accent.opacity(0.16))
                        .frame(width: size * haloScale(motion), height: size * haloScale(motion))
                        .blur(radius: size * 0.22)
                }
                mark(motion)
            }
            .frame(width: size * 1.6, height: size * 1.6)
        }
        .keyframeAnimator(initialValue: 1.0, trigger: pulse) { view, scale in
            view.scaleEffect(scale)
        } keyframes: { _ in
            KeyframeTrack {
                CubicKeyframe(0.84, duration: 0.11)
                SpringKeyframe(1.0, duration: 0.44, spring: .bouncy(duration: 0.44, extraBounce: 0.2))
            }
        }
        .onChange(of: isBusy, initial: true) { _, busy in
            clock.setRunning(busy && !reduceMotion)
        }
        .accessibilityLabel(agent.displayName)
    }

    /// OpenAI's knot stays white for maximum contrast in the black notch. The
    /// surrounding glass/halo retains the agent tint, so identity is not lost.
    private func mark(_ motion: MarkMotion) -> some View {
        BrandMarkShape(agent: agent)
            .fill(agent == .codex ? Color.white : accent)
            .frame(width: size, height: size)
            .scaleEffect(motion.scale)
            .rotationEffect(.degrees(motion.angle))
    }

    private func motion(at date: Date) -> MarkMotion {
        guard isBusy, !reduceMotion else { return MarkMotion() }
        let t = clock.elapsed(at: date)
        return switch agent {
        case .claude: .breathe(at: t)
        case .codex: .ratchet(at: t)
        }
    }

    /// A slow breath under the mark, so a long-running tool still reads as running.
    private func haloScale(_ motion: MarkMotion) -> CGFloat {
        isBusy && !reduceMotion ? 1.05 * motion.scale + 0.1 : 1.05
    }
}
