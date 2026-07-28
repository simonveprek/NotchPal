import Foundation
import NotchPalCore
import SwiftUI

/// Identity for one running agent window. Two Claude Code sessions in two
/// terminals are two sessions here, and the notch can narrate either.
struct SessionKey: Hashable, Sendable {
    let agent: Agent
    let id: String
}

/// Everything the notch knows about one agent, right now.
struct AgentSession: Identifiable {
    let key: SessionKey
    var id: SessionKey { key }
    var agent: Agent { key.agent }

    var phase: Phase = .idle
    var cwd: String?
    var model: String?

    /// The tool currently in flight, and when it started — the live duration is
    /// derived from this rather than stored, so it stays honest between events.
    var activity: Activity?
    var activityStartedAt: Date?
    var activityToolUseID: String?

    /// The tool that just finished, kept briefly so a fast tool still registers.
    var lastActivity: Activity?
    var lastActivityDuration: TimeInterval?
    var lastActivityFailed = false

    var turnStartedAt: Date?
    var turnEndedAt: Date?
    var toolsThisTurn = 0
    var subagentsRunning = 0

    /// Notification text, permission request, or the tail of the agent's answer.
    var message: String?
    var lastEventAt = Date()

    enum Phase: Equatable {
        case idle
        /// Between the prompt and the first tool, or between tools.
        case thinking
        /// A tool finished and Codex is processing its result, choosing the next
        /// action, or composing an update. Hooks cannot distinguish those moments,
        /// so this label stays useful without claiming it can see streamed prose.
        case continuing
        case working
        case awaitingInput
        case compacting
        case finished(ok: Bool)

        var isBusy: Bool {
            switch self {
            case .thinking, .continuing, .working, .compacting: true
            case .idle, .awaitingInput, .finished: false
            }
        }

        /// Whether this phase should hold the notch open on its own.
        var demandsAttention: Bool { self == .awaitingInput }

        /// How long this phase may go without any event before NotchPal concludes
        /// the session is gone rather than busy.
        ///
        /// The limits differ a lot because the phases do. A single tool call can
        /// honestly run for many minutes, and high-effort reasoning can be quiet
        /// for just as long. The hook stream has no heartbeat, so retiring either
        /// state early makes a live turn disappear and then pop back in on the
        /// next event. Use the same conservative lifetime as the session cache.
        var stallLimit: TimeInterval? {
            switch self {
            case .thinking, .continuing, .working: 30 * 60
            case .compacting: 15 * 60
            case .awaitingInput: 30 * 60
            case .idle, .finished: nil
            }
        }
    }

    // MARK: - Presentation

    var accent: Color {
        switch agent {
        // Anthropic's Claude coral, and the OpenAI green.
        case .claude: Color(red: 0.851, green: 0.467, blue: 0.341)
        case .codex: Color(red: 0.063, green: 0.639, blue: 0.498)
        }
    }

    var projectName: String? { Format.projectName(cwd) }

    /// How long the current tool has been running, or nil if nothing is.
    func activityElapsed(at now: Date) -> TimeInterval? {
        guard let activityStartedAt, phase == .working else { return nil }
        return now.timeIntervalSince(activityStartedAt)
    }

    func turnElapsed(at now: Date) -> TimeInterval? {
        guard let turnStartedAt else { return nil }
        return (turnEndedAt ?? now).timeIntervalSince(turnStartedAt)
    }

    /// The headline the notch reads out: verb plus subject.
    var headline: (verb: String, subject: String)? {
        switch phase {
        case .working:
            guard let activity else { return nil }
            return (activity.verb, activity.subject)
        case .thinking, .continuing:
            // Hooks cannot see streamed prose or private reasoning. Keeping the
            // latest concrete action on screen is both more useful and more
            // honest than inventing a mental state between lifecycle events.
            if let lastActivity {
                return (lastActivity.verb, lastActivity.subject)
            }
            return ("Starting", projectName ?? agent.displayName)
        case .compacting:
            return ("Compacting", "the conversation")
        case .awaitingInput:
            return ("Waiting for", "you")
        case .finished(let ok):
            return (ok ? "Finished" : "Stopped", projectName ?? agent.displayName)
        case .idle:
            return nil
        }
    }

    var symbol: String {
        switch phase {
        case .working: activity?.category.symbol ?? "gearshape"
        case .thinking, .continuing: lastActivity?.category.symbol ?? "sparkles"
        case .compacting: "arrow.down.right.and.arrow.up.left"
        case .awaitingInput: "hand.raised"
        case .finished(let ok): ok ? "checkmark" : "exclamationmark.triangle"
        case .idle: "moon.zzz"
        }
    }
}
