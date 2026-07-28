import AppKit
import NotchPalCore

// NotchPal is a status-bar agent whose only real UI is a floating panel, so it runs
// on a plain AppKit lifecycle rather than a SwiftUI `App`.
//
// This is deliberate. A SwiftUI `App` whose only scene is a `MenuBarExtra` needs
// to be a bundled application before macOS will give it a status item, which
// makes it impossible to just hit Run in Xcode on a SwiftUI package target.
// Creating the `NSStatusItem` by hand works whether or not there is a bundle,
// so the debug build and the shipped app behave identically.

// One-shot commands first: `--install-hooks`, `--status`, and friends exit here.
CommandLineMode.runIfRequested()

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
// A status item, not a Dock icon. Set before `run()` so no icon ever flashes.
application.setActivationPolicy(.accessory)
application.run()
