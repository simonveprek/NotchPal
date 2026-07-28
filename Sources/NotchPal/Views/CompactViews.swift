import NotchPalCore
import SwiftUI

/// Left of the notch: who is working.
///
/// One mark when a single agent is active. When both are, they sit as a pair —
/// the trailing one tucked behind — so you can tell at a glance that two things
/// are happening without the notch growing.
struct CompactLeadingView: View {
    let model: AppModel

    var body: some View {
        let agents = model.liveAgents

        HStack(spacing: -5) {
            ForEach(agents.prefix(2), id: \.self) { agent in
                AgentMarkView(
                    agent: agent,
                    accent: accent(for: agent),
                    size: 15,
                    isBusy: model.sessions.contains { $0.agent == agent && $0.phase.isBusy },
                    pulse: model.sessions.first { $0.agent == agent }?.toolsThisTurn ?? 0,
                    showsHalo: false
                )
                .zIndex(agent == agents.first ? 1 : 0)
                .transition(.blurReplace.combined(with: .scale(0.6)))
            }
        }
        .animation(.bouncy(duration: 0.4), value: agents)
        .padding(.leading, 6)
    }

    private func accent(for agent: Agent) -> Color {
        model.sessions.first { $0.agent == agent }?.accent ?? .white
    }
}

/// Right of the notch: what is happening, and for how long.
///
/// The word and the number are deliberately the same colour. Tinting the clock
/// by state made the time look like an alert; the state already has a colour, in
/// the mark on the other side of the notch.
struct CompactTrailingView: View {
    let model: AppModel

    /// The duration sits behind the verb in the hierarchy — it is reference, not
    /// headline. Same hue, less presence.
    private let clockOpacity: Double = 0.5

    var body: some View {
        Group {
            if let session = model.focus {
                content(for: session)
            }
        }
        .padding(.trailing, 6)
        .frame(minHeight: 14)
        .animation(.smooth(duration: 0.3), value: model.focus?.phase)
    }

    @ViewBuilder
    private func content(for session: AgentSession) -> some View {
        switch session.phase {
        case .working, .thinking, .continuing, .compacting:
            TimelineView(.periodic(from: .now, by: 0.1)) { context in
                HStack(spacing: 5) {
                    // "Reading", "Editing", "Running" — keep the latest concrete
                    // action visible between hook events instead of falling back
                    // to a vague "Thinking" label.
                    ShimmerText(text: session.headline?.verb ?? "Working")

                    if let elapsed = elapsed(for: session, at: context.date), elapsed > 0.6 {
                        DurationLabel(seconds: elapsed)
                            .foregroundStyle(.white.opacity(clockOpacity))
                            .transition(.blurReplace)
                    }
                }
            }

        case .awaitingInput:
            HStack(spacing: 5) {
                Image(systemName: "hand.raised.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.orange)
                    .symbolEffect(.bounce, options: .repeating.speed(0.5))
                Text("Waiting")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.72))
            }

        case .finished(let ok):
            HStack(spacing: 5) {
                Image(systemName: ok ? "checkmark" : "exclamationmark.triangle.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(ok ? .white.opacity(0.72) : .orange)
                    .contentTransition(.symbolEffect(.replace))
                if let total = session.turnElapsed(at: session.turnEndedAt ?? .now), total > 1 {
                    DurationLabel(seconds: total)
                        .foregroundStyle(.white.opacity(clockOpacity))
                }
            }

        case .idle:
            EmptyView()
        }
    }

    /// While a tool runs, time the tool. Between tools, keep timing the turn so
    /// the number never resets to zero and back.
    private func elapsed(for session: AgentSession, at now: Date) -> TimeInterval? {
        session.activityElapsed(at: now) ?? session.turnElapsed(at: now)
    }
}
