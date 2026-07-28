import AppKit
import Combine
import DynamicNotchKit
import NotchPalCore
import SwiftUI

extension NSScreen {
    /// The same test `DynamicNotchKit` uses to resolve `.auto`, so NotchPal's own
    /// decisions can never disagree with the framework's.
    var hasCameraHousing: Bool {
        auxiliaryTopLeftArea != nil && auxiliaryTopRightArea != nil
    }
}

/// Decides what the notch is doing: hidden, compact, or expanded.
///
/// The rule NotchPal tries to honour is that an ambient display earns its place by
/// being quiet. Working is compact. Expansion is reserved for the handful of
/// moments a person actually wants pulled to their attention — a turn starting,
/// a turn ending, and the agent asking for permission — plus hovering, which is
/// the user asking for detail explicitly.
@MainActor
final class NotchController {
    private let model: AppModel
    private let notch: DynamicNotch<ExpandedView, CompactLeadingView, CompactTrailingView>
    private var settleTask: Task<Void, Never>?
    private var hoverObserver: AnyCancellable?
    private var isHovering = false

    /// How long each kind of interruption holds the notch open.
    private enum Dwell {
        static let started: Duration = .milliseconds(2200)
        static let prompted: Duration = .milliseconds(2000)
        /// `AppModel.liveSessions` keeps a completed turn alive for
        /// `finishedLinger`. Never settle before that deadline: doing so sees the
        /// session as still live, compacts it, and leaves no future event to
        /// trigger the final hide.
        static let finished: Duration = .milliseconds(
            Int64(AppModel.finishedLinger * 1_000) + 100
        )
        static let toolChanged: Duration = .milliseconds(1500)
        /// After the last session goes quiet, wait before dismissing entirely.
        static let idle: Duration = .milliseconds(700)
    }

    init(model: AppModel) {
        self.model = model
        notch = DynamicNotch(hoverBehavior: .all, style: .auto) {
            ExpandedView(model: model)
        } compactLeading: {
            CompactLeadingView(model: model)
        } compactTrailing: {
            CompactTrailingView(model: model)
        }
        notch.transitionConfiguration = .init(
            openingAnimation: .bouncy(duration: 0.42, extraBounce: 0.08),
            closingAnimation: .smooth(duration: 0.34),
            conversionAnimation: .snappy(duration: 0.34),
            // Compact and expanded are two readings of the same state, not two
            // separate notifications; blinking through hidden between them looks
            // like a glitch.
            skipIntermediateHides: true
        )

        // Hovering the notch is an explicit request for the whole story.
        hoverObserver = notch.$isHovering
            .removeDuplicates()
            .sink { [weak self] hovering in
                Task { @MainActor in self?.hoverChanged(hovering) }
            }
    }

    /// Called after every applied event.
    func sync() {
        settleTask?.cancel()

        guard !model.isIdle else {
            model.clearAttention()
            scheduleHide()
            return
        }

        guard let attention = model.attention else {
            Task { await rest() }
            return
        }

        switch attention.reason {
        case .needsInput:
            // No timer: it stays open until the agent stops waiting on the user.
            Task { await notch.expand() }

        case .started:
            expand(then: Dwell.started)
        case .prompted:
            expand(then: Dwell.prompted)
        case .finished:
            expand(then: Dwell.finished)
        case .toolChanged:
            // Expanding on every tool would strobe. A change of *kind* of work is
            // the closest thing to a meaningful beat, and even that is opt-in.
            if Preferences.shared.expandOnToolChange {
                expand(then: Dwell.toolChanged)
            } else {
                model.clearAttention()
                Task { await rest() }
            }
        }
    }

    /// Brings the notch down for a look, e.g. from the menu bar.
    func peek() {
        settleTask?.cancel()
        expand(then: Dwell.finished)
    }

    /// Says hello on launch.
    ///
    /// A menu bar agent with no window, no Dock icon and nothing to report is
    /// indistinguishable from one that failed to start. One card, once, so the
    /// first run is not an act of faith.
    func greet() {
        settleTask?.cancel()
        Task {
            await notch.expand()
            try? await Task.sleep(for: .milliseconds(2800))
            guard !isHovering else { return }
            await notch.hide()
        }
    }

    func hide() {
        settleTask?.cancel()
        Task { await notch.hide() }
    }

    // MARK: - Private

    private func expand(then dwell: Duration) {
        Task { await notch.expand() }
        settleTask = Task { [weak self] in
            try? await Task.sleep(for: dwell)
            guard !Task.isCancelled, let self else { return }
            model.clearAttention()
            settle()
        }
    }

    private func scheduleHide() {
        settleTask = Task { [weak self] in
            try? await Task.sleep(for: Dwell.idle)
            guard !Task.isCancelled, let self else { return }
            await notch.hide()
        }
    }

    /// Falls back to whatever the current state deserves once a dwell expires.
    private func settle() {
        guard !isHovering else { return }
        if model.isIdle {
            scheduleHide()
        } else {
            Task { await rest() }
        }
    }

    /// The state the panel rests in while an agent is working.
    ///
    /// On a screen with a notch that is the compact strip either side of it.
    /// Every other screen gets the floating style, which has **no compact state
    /// at all** — `DynamicNotchKit` turns `compact()` into `hide()` there:
    ///
    /// ```swift
    /// if effectiveStyle(for: screen).isFloating {
    ///     await hide()
    ///     return
    /// }
    /// ```
    ///
    /// So resting on those screens means staying expanded. Without this branch
    /// the panel disappears for exactly as long as the agent is working and
    /// returns once it stops, which is precisely backwards.
    private func rest() async {
        if targetScreenHasNotch {
            await notch.compact()
        } else {
            await notch.expand()
        }
    }

    /// `DynamicNotchKit` defaults every call to `NSScreen.screens[0]` and
    /// resolves `.auto` from that screen alone, so this has to ask the same
    /// screen the same question or the two will quietly disagree. Note that
    /// `screens[0]` is the *primary* display: a MacBook driving an external
    /// monitor set as primary floats there, notch or no notch.
    private var targetScreenHasNotch: Bool {
        NSScreen.screens.first?.hasCameraHousing ?? false
    }

    private func hoverChanged(_ hovering: Bool) {
        isHovering = hovering
        settleTask?.cancel()

        if hovering {
            Task { await notch.expand() }
        } else {
            settleTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(350))
                guard !Task.isCancelled, let self else { return }
                settle()
            }
        }
    }
}
