import AppKit
import NotchPalCore
import SwiftUI

/// Which surface the notch is drawing on, because it changes how type should be coloured.
///
/// On a notched Mac the panel is opaque black and text is always light. On every
/// other Mac `DynamicNotchKit` floats a `.popover` material that follows the
/// system appearance, so the same hard-coded white would be unreadable.
enum Chrome {
    case notch, floating

    /// Asks the same question of the same screen as `NotchController`, so the
    /// colour ramp can never disagree with the style actually being drawn.
    static var current: Chrome {
        (NSScreen.screens.first?.hasCameraHousing ?? false) ? .notch : .floating
    }
}

/// The full read-out: what the agent is doing, the detail behind it, and how long.
///
/// Three pieces of information and nothing else. The mark says which agent it is,
/// so naming it again is redundant; the mark's motion says it is alive, so a
/// progress bar is redundant; and a tool counter is a number nobody acts on.
/// What is left is the sentence you actually looked up to read.
struct ExpandedView: View {
    let model: AppModel

    @Namespace private var glass
    private let cardWidth: CGFloat = 336

    var body: some View {
        let chrome = Chrome.current
        let hero = model.focus
        let others = model.liveSessions.filter { $0.key != hero?.key }

        GlassEffectContainer(spacing: 18) {
            VStack(alignment: .leading, spacing: 9) {
                if let hero {
                    Row(
                        session: hero, chrome: chrome, glass: glass,
                        size: 34, font: 13,
                        dismiss: { model.dismiss(hero.key) }
                    )
                    ForEach(others) { session in
                        Row(
                            session: session, chrome: chrome, glass: glass,
                            size: 22, font: 11,
                            dismiss: { model.dismiss(session.key) }
                        )
                        .opacity(0.72)
                    }
                } else {
                    IdleRow(chrome: chrome, banner: model.banner, listening: model.isListening)
                }
            }
            .frame(width: cardWidth, alignment: .leading)
        }
        .animation(.smooth(duration: 0.35), value: model.liveSessions.map(\.key))
        .animation(.snappy(duration: 0.28), value: hero?.phase)
    }
}

// MARK: - Rows

private struct Row: View {
    let session: AgentSession
    let chrome: Chrome
    let glass: Namespace.ID
    let size: CGFloat
    let font: CGFloat
    let dismiss: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .center, spacing: 11) {
            AgentAvatar(session: session, glass: glass, size: size)

            VStack(alignment: .leading, spacing: 1) {
                headline
                if let detail {
                    Text(detail)
                        .font(.system(size: font - 2.5))
                        .foregroundStyle(chrome.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer(minLength: 8)

            TimelineView(.periodic(from: .now, by: 0.1)) { context in
                if let elapsed = session.turnElapsed(at: context.date) {
                    DurationLabel(seconds: elapsed, font: .system(size: font, weight: .medium))
                        .foregroundStyle(chrome.secondary)
                }
            }

            DismissButton(chrome: chrome, size: font + 5, action: dismiss)
                // Hidden until you reach for it, so the resting card stays a
                // read-out rather than a control panel. Space is reserved either
                // way so nothing shifts when it appears.
                .opacity(isHovering ? 1 : 0)
                // A zero-opacity view still takes clicks; without this the card
                // would have an invisible button sitting on it.
                .allowsHitTesting(isHovering)
                .animation(.easeOut(duration: 0.16), value: isHovering)
        }
        .contentShape(.rect)
        .onHover { isHovering = $0 }
    }

    @ViewBuilder
    private var headline: some View {
        if let text = headlineText {
            Text(text)
                .font(.system(size: font))
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    /// `Reading` **NotchController.swift** — the verb recedes, the subject leads.
    private var headlineText: AttributedString? {
        guard let line = session.headline else { return nil }

        var verb = AttributedString(line.verb + " ")
        verb.foregroundColor = chrome.secondary

        var subject = AttributedString(line.subject)
        subject.foregroundColor = chrome.primary
        subject.font = .system(size: font, weight: .medium)

        return verb + subject
    }

    /// The line that answers the follow-up question: which lines, which project,
    /// what the agent is waiting for, how long the last thing took.
    private var detail: String? {
        var parts: [String] = []

        switch session.phase {
        case .working:
            if let qualifier = session.activity?.qualifier { parts.append(qualifier) }

        case .awaitingInput:
            parts.append(session.message ?? "Approve or deny in the terminal")

        case .finished:
            if let message = session.message { parts.append(message) }

        case .thinking:
            if session.lastActivity != nil {
                let duration = session.lastActivityDuration.map { " in \(Format.duration($0))" } ?? ""
                parts.append("\(session.lastActivityFailed ? "Failed" : "Completed")\(duration) · preparing the next update")
            } else if let message = session.message {
                parts.append(message)
            } else {
                parts.append("Preparing the first step")
            }

        case .continuing:
            if session.lastActivity != nil {
                let duration = session.lastActivityDuration.map { " in \(Format.duration($0))" } ?? ""
                parts.append("\(session.lastActivityFailed ? "Failed" : "Completed")\(duration) · preparing the next update")
            } else if let message = session.message {
                parts.append(message)
            }

        default:
            if let message = session.message { parts.append(message) }
        }

        if let project = session.projectName { parts.append(project) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// Dismisses one session's card.
///
/// This exists because of a gap NotchPal cannot close on its own: when *you*
/// stop an agent — Escape, Ctrl-C, closing the terminal — no `Stop` and no
/// `SessionEnd` hook is ever fired, so nothing tells NotchPal the work ended.
/// The staleness sweep eventually retires the card, but "eventually" is no help
/// when you are looking at a timer counting up for work you know is over.
///
/// It dismisses the card, not the agent. Hooks are one-way — the agent spawns
/// the reporter, the reporter writes a line and exits — so there is no channel
/// back, and no payload carries a process id. A button labelled "Stop" that
/// cannot stop anything would be worse than no button.
private struct DismissButton: View {
    let chrome: Chrome
    var size: CGFloat
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: size * 0.42, weight: .bold))
                .foregroundStyle(isHovering ? chrome.primary : chrome.tertiary)
                .frame(width: size, height: size)
                .background(Circle().fill(chrome.controlFill(hovering: isHovering)))
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help("Dismiss this card. NotchPal cannot stop the agent itself.")
        .accessibilityLabel("Dismiss this session")
    }
}

/// The card shown when nothing is running — which is also the card shown on
/// launch, so it doubles as proof that the app started.
private struct IdleRow: View {
    let chrome: Chrome
    let banner: String?
    let listening: Bool

    var body: some View {
        HStack(spacing: 11) {
            NotchGlyph()
                .fill(chrome.secondary)
                .frame(width: 22, height: 14)

            VStack(alignment: .leading, spacing: 2) {
                Text(listening ? "NotchPal is listening" : "NotchPal is not listening")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(chrome.primary)
                if let banner {
                    Text(banner)
                        .font(.system(size: 10))
                        .foregroundStyle(chrome.tertiary)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

/// The mark in a tinted glass disc.
///
/// This is the one place NotchPal uses Liquid Glass, and it earns it: the disc is a
/// distinct control-layer object above the panel, it carries the agent's tint,
/// and giving it a `glassEffectID` lets two agents' discs fuse and separate as
/// sessions come and go. Everything else on the card is plain vibrant type,
/// because glass over glass is exactly what Apple tells you not to build.
private struct AgentAvatar: View {
    let session: AgentSession
    let glass: Namespace.ID
    var size: CGFloat

    var body: some View {
        AgentMarkView(
            agent: session.agent,
            accent: session.accent,
            size: size * 0.52,
            isBusy: session.phase.isBusy,
            pulse: session.toolsThisTurn
        )
        .frame(width: size, height: size)
        .glassEffect(.regular.tint(session.accent.opacity(0.34)).interactive(), in: .circle)
        .glassEffectID(session.key, in: glass)
        .overlay {
            // A quiet ring while the agent waits on you.
            if session.phase.demandsAttention {
                Circle().strokeBorder(.orange, lineWidth: 1.5).opacity(0.9)
            }
        }
    }
}

// MARK: - Type colour ramp

private extension Chrome {
    /// On black, semantic hierarchy collapses; explicit white steps keep the
    /// levels distinguishable. On the floating material, defer to the system.
    var primary: Color {
        self == .notch ? .white : .primary
    }

    var secondary: Color {
        self == .notch ? .white.opacity(0.66) : .secondary
    }

    var tertiary: Color {
        self == .notch ? .white.opacity(0.44) : .secondary.opacity(0.65)
    }

    /// Backing for a small round control. Barely there at rest, legible on hover.
    func controlFill(hovering: Bool) -> Color {
        self == .notch
            ? .white.opacity(hovering ? 0.18 : 0.09)
            : .primary.opacity(hovering ? 0.12 : 0.06)
    }
}
