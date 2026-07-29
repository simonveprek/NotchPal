import Foundation
import ServiceManagement

/// Launch at login, via `SMAppService`.
///
/// This is the modern replacement for the old login-item APIs and for shipping a
/// separate helper application: macOS registers the bundle itself, and the user
/// can always override it in System Settings › General › Login Items.
///
/// It only works for a real bundle. Running the executable straight out of
/// `swift build` — or from Xcode — has no bundle for macOS to register, so the
/// menu item explains itself rather than failing silently.
enum LoginItem {
    /// Whether this process is a bundled app at all.
    ///
    /// A bare SwiftPM executable still reports a `Bundle.main`, but it has no
    /// bundle identifier, which is exactly what `SMAppService` needs.
    static var isSupported: Bool {
        Bundle.main.bundleIdentifier != nil
    }

    static var isEnabled: Bool {
        guard isSupported else { return false }
        return SMAppService.mainApp.status == .enabled
    }

    /// Turns launch-at-login on or off.
    /// - Returns: a human-readable problem, or `nil` on success.
    static func setEnabled(_ enabled: Bool) -> String? {
        guard isSupported else {
            return "Launch at login needs the bundled app. Run `make install` and open NotchPal from Applications."
        }

        do {
            if enabled {
                // Re-registering an already-registered app throws, so clear it first.
                if SMAppService.mainApp.status == .enabled {
                    try? SMAppService.mainApp.unregister()
                }
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// What the menu item should say about itself when it cannot be used.
    static var unavailableReason: String? {
        isSupported ? nil : "Available once NotchPal runs from Applications"
    }
}
