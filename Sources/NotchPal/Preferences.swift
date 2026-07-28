import Foundation
import Observation

/// The small amount of persistent state NotchPal needs.
@MainActor
@Observable
final class Preferences {
    static let shared = Preferences()

    /// Briefly expand the notch when the agent switches between kinds of work
    /// (reading → running a command → editing). Off by default: informative,
    /// but it moves a lot.
    var expandOnToolChange: Bool {
        didSet { defaults.set(expandOnToolChange, forKey: Key.expandOnToolChange) }
    }

    /// Show the notch even when nothing is running, so it can be found.
    var showWhenIdle: Bool {
        didSet { defaults.set(showWhenIdle, forKey: Key.showWhenIdle) }
    }

    /// False after installing or changing the Codex command hooks, because Codex
    /// will skip them until the user reviews their new hash with `/hooks`. The
    /// first real Codex event proves the current definition is trusted.
    var codexHooksVerified: Bool {
        didSet { defaults.set(codexHooksVerified, forKey: Key.codexHooksVerified) }
    }

    private let defaults: UserDefaults

    private enum Key {
        static let expandOnToolChange = "expandOnToolChange"
        static let showWhenIdle = "showWhenIdle"
        static let codexHooksVerified = "codexHooksVerified"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        expandOnToolChange = defaults.bool(forKey: Key.expandOnToolChange)
        showWhenIdle = defaults.bool(forKey: Key.showWhenIdle)
        codexHooksVerified = defaults.bool(forKey: Key.codexHooksVerified)
    }
}
