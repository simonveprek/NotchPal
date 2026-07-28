import Foundation
import NotchPalCore
import Observation
import SwiftUI

/// The single source of truth the notch views read from.
///
/// Events arrive from the socket, get folded into per-session state here, and the
/// views recompute. Nothing in this type knows about windows or animation — that
/// belongs to `NotchController`.
@MainActor
@Observable
final class AppModel {
    /// Sessions, most recently active first.
    private(set) var sessions: [AgentSession] = []
    /// Set when the last event is worth interrupting the user for.
    private(set) var attention: Attention?
    private(set) var lastEventAt: Date?
    private(set) var isListening = false
    private(set) var listenError: String?
    /// Shown on the idle card. An agent with no window needs some way to say
    /// "I started, and here is what to do next".
    var banner: String?

    /// A finished turn stays on screen this long before the notch lets go.
    nonisolated static let finishedLinger: TimeInterval = 6
    /// Sessions with no events for this long are forgotten.
    static let sessionTimeout: TimeInterval = 30 * 60

    struct Attention: Equatable {
        var key: SessionKey
        var reason: Reason
        var at: Date

        enum Reason: Equatable {
            case started, prompted, needsInput, finished(ok: Bool), toolChanged
        }
    }

    // MARK: - Derived state

    /// Sessions the notch should be narrating: busy, waiting, or freshly finished.
    var liveSessions: [AgentSession] {
        let now = Date()
        return sessions.filter { session in
            switch session.phase {
            case .finished:
                (session.turnEndedAt.map { now.timeIntervalSince($0) } ?? .infinity) < Self.finishedLinger
            case .idle:
                false
            default:
                true
            }
        }
    }

    /// The one session the compact view speaks for — busy beats waiting beats done.
    var focus: AgentSession? {
        let live = liveSessions
        return live.first { $0.phase.demandsAttention }
            ?? live.first { $0.phase.isBusy }
            ?? live.first
    }

    /// Distinct agents currently live, in a stable order, for the paired mark.
    var liveAgents: [Agent] {
        var seen: [Agent] = []
        for session in liveSessions where !seen.contains(session.agent) {
            seen.append(session.agent)
        }
        return seen
    }

    var isIdle: Bool { liveSessions.isEmpty }

    // MARK: - Event intake

    func apply(_ event: AgentEvent) {
        lastEventAt = event.at
        let key = SessionKey(agent: event.agent, id: event.sessionID)

        if event.kind == .sessionEnd {
            sessions.removeAll { $0.key == key }
            if attention?.key == key { attention = nil }
            return
        }

        var session = sessions.first { $0.key == key } ?? AgentSession(key: key)
        session.lastEventAt = event.at
        if let cwd = event.cwd { session.cwd = cwd }
        if let model = event.model { session.model = model }

        var reason: Attention.Reason?

        switch event.kind {
        case .sessionStart:
            session.phase = .idle
            session.turnStartedAt = nil
            session.turnEndedAt = nil
            session.toolsThisTurn = 0
            session.activity = nil
            reason = .started

        case .promptSubmit:
            session.phase = .thinking
            session.turnStartedAt = event.at
            session.turnEndedAt = nil
            session.toolsThisTurn = 0
            session.lastActivity = nil
            session.message = event.message
            reason = .prompted

        case .toolStart:
            let previousCategory = session.activity?.category ?? session.lastActivity?.category
            session.phase = .working
            session.activity = event.activity
            session.activityStartedAt = event.at
            session.activityToolUseID = event.toolUseID
            session.toolsThisTurn += 1
            if session.turnStartedAt == nil { session.turnStartedAt = event.at }
            session.turnEndedAt = nil
            if previousCategory != event.activity?.category { reason = .toolChanged }

        case .toolEnd:
            // Tool calls can overlap; only the one we are showing closes the timer.
            let matches = event.toolUseID == nil || event.toolUseID == session.activityToolUseID
            if matches {
                session.lastActivity = session.activity ?? event.activity
                session.lastActivityDuration = session.activityStartedAt.map { event.at.timeIntervalSince($0) }
                session.lastActivityFailed = event.ok == false
                session.activity = nil
                session.activityStartedAt = nil
                session.activityToolUseID = nil
                session.phase = .continuing
            }
            if event.ok == false { session.message = event.message }

        case .permissionRequest:
            session.phase = .awaitingInput
            session.message = event.message ?? event.subtype
            reason = .needsInput

        case .notification:
            // Only some notifications actually want the user; the rest are chatter.
            let wantsUser = ["permission_prompt", "idle_prompt", "agent_needs_input", "elicitation_dialog"]
            if let subtype = event.subtype, wantsUser.contains(subtype) {
                session.phase = .awaitingInput
                session.message = event.message ?? subtype
                reason = .needsInput
            } else if let message = event.message {
                session.message = message
            }

        case .turnEnd:
            session.phase = .finished(ok: true)
            session.turnEndedAt = event.at
            session.activity = nil
            session.activityStartedAt = nil
            session.message = event.message
            reason = .finished(ok: true)

        case .turnFailed:
            session.phase = .finished(ok: false)
            session.turnEndedAt = event.at
            session.activity = nil
            session.activityStartedAt = nil
            session.message = event.message
            reason = .finished(ok: false)

        case .subagentStart:
            session.subagentsRunning += 1

        case .subagentStop:
            session.subagentsRunning = max(0, session.subagentsRunning - 1)

        case .compactStart:
            session.phase = .compacting

        case .compactEnd:
            session.phase = .continuing

        case .sessionEnd:
            break // Handled above.
        }

        upsert(session)
        if let reason { attention = Attention(key: key, reason: reason, at: event.at) }
        prune()
    }

    /// Drops the attention flag once its moment has passed, so the notch can settle.
    func clearAttention() { attention = nil }

    /// Called whenever state changes outside of an incoming event, so the notch
    /// can re-evaluate without waiting for the next hook to arrive.
    var onChange: (() -> Void)?

    /// Retires sessions that have gone quiet for longer than their phase allows.
    ///
    /// Agents do not always say goodbye. Interrupting a turn, quitting the CLI,
    /// or closing the terminal fires no `Stop` and no `SessionEnd`, so without
    /// this a session sits in the notch claiming to work for the rest of the day.
    @discardableResult
    func expireStale(now: Date = Date()) -> Bool {
        var changed = false
        for index in sessions.indices {
            if case .finished = sessions[index].phase,
               let endedAt = sessions[index].turnEndedAt,
               now.timeIntervalSince(endedAt) >= Self.finishedLinger
            {
                sessions[index].phase = .idle
                changed = true
                continue
            }

            guard let limit = sessions[index].phase.stallLimit,
                  now.timeIntervalSince(sessions[index].lastEventAt) > limit
            else { continue }

            sessions[index].phase = .idle
            sessions[index].activity = nil
            sessions[index].activityStartedAt = nil
            sessions[index].activityToolUseID = nil
            changed = true
        }

        if changed, let key = attention?.key, sessions.first(where: { $0.key == key })?.phase == .idle {
            attention = nil
        }
        return changed
    }

    /// Dismisses one session from the notch — the manual version of the above.
    func dismiss(_ key: SessionKey) {
        guard let index = sessions.firstIndex(where: { $0.key == key }) else { return }
        sessions[index].phase = .idle
        sessions[index].activity = nil
        if attention?.key == key { attention = nil }
        onChange?()
    }

    func setListening(_ listening: Bool, error: String? = nil) {
        isListening = listening
        listenError = error
    }

    /// Forgets everything. Wired to the menu bar for when hooks and reality diverge.
    func reset() {
        sessions.removeAll()
        attention = nil
    }

    private func upsert(_ session: AgentSession) {
        sessions.removeAll { $0.key == session.key }
        sessions.insert(session, at: 0)
    }

    /// Agents crash, terminals get closed, and `SessionEnd` does not always arrive.
    private func prune() {
        let now = Date()
        sessions.removeAll { now.timeIntervalSince($0.lastEventAt) > Self.sessionTimeout }
        if sessions.count > 12 { sessions.removeLast(sessions.count - 12) }
    }
}
