import AppKit
import NotchPalCore
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private(set) var controller: NotchController!
    private var server: EventServer?
    private var statusItem: NSStatusItem?
    private var sweep: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller = NotchController(model: model)
        model.onChange = { [weak self] in
            guard let self else { return }
            self.controller.sync()
            self.refreshStatusItem()
        }
        installStatusItem()
        startListening()
        startStallSweep()
        model.banner = hookGuidance()
        controller.greet()
    }

    func applicationWillTerminate(_ notification: Notification) {
        sweep?.invalidate()
        server?.stop()
    }

    /// Nothing arrives when an agent is killed, so staleness has to be noticed
    /// rather than reported. Five seconds is frequent enough to feel immediate
    /// and far too cheap to matter.
    private func startStallSweep() {
        sweep = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.model.expireStale() else { return }
                self.controller.sync()
                self.refreshStatusItem()
            }
        }
    }

    /// `notchpal-report` ships beside the app binary — true both in the .app bundle
    /// and in the plain `swift build` / Xcode layout.
    var reporterURL: URL {
        let neighbour = URL(filePath: CommandLine.arguments[0])
            .deletingLastPathComponent()
            .appending(path: "notchpal-report")
        return neighbour
    }

    // MARK: - Listening

    private func startListening() {
        let server = EventServer(deliverOn: .main) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.model.apply(event)
                if event.agent == .codex, !Preferences.shared.codexHooksVerified {
                    Preferences.shared.codexHooksVerified = true
                    self.model.banner = self.hookGuidance()
                }
                self.controller.sync()
                self.refreshStatusItem()
            }
        }
        do {
            try server.start()
            self.server = server
            model.setListening(true)
        } catch {
            model.setListening(false, error: String(describing: error))
        }
        refreshStatusItem()
    }

    /// What the idle card should tell you to do next.
    private func hookGuidance() -> String {
        guard model.isListening else { return model.listenError ?? "Could not open the event socket" }
        let missing = Agent.allCases.filter { !hooksReady(for: $0) }
        guard !missing.isEmpty else {
            if !Preferences.shared.codexHooksVerified {
                return "Codex hooks configured · open /hooks in Codex and trust NotchPal once"
            }
            return "Hooks active · start a session in Claude Code or Codex"
        }
        return "Install \(missing.map(\.displayName).joined(separator: " and ")) hooks from the menu bar"
    }

    private func hooksReady(for agent: Agent) -> Bool {
        let status = HookInstaller.status(for: agent, reporter: reporterURL)
        return status.installed && !status.stale
    }

    // MARK: - Status item

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = Self.statusImage()
        item.button?.toolTip = "NotchPal"
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    /// Draws the notch glyph once as a template image, so it picks up the menu
    /// bar's own tint in light mode, dark mode, and while the menu is open.
    private static func statusImage() -> NSImage? {
        let renderer = ImageRenderer(
            content: NotchGlyph()
                .fill(.black)
                .frame(width: 17, height: 11)
                .padding(.vertical, 3)
        )
        renderer.scale = 3
        let image = renderer.nsImage
        image?.isTemplate = true
        return image
    }

    private func refreshStatusItem() {
        // The glyph dims when nothing is running, so a glance at the menu bar
        // answers "is anything working?" without opening anything.
        statusItem?.button?.alphaValue = model.isIdle ? 0.55 : 1
    }

    // MARK: - Actions

    @objc private func toggleHooks(_ sender: NSMenuItem) {
        guard let agent = Agent(rawValue: sender.representedObject as? String ?? "") else { return }
        let shouldInstall = !hooksReady(for: agent)
        do {
            if shouldInstall {
                try HookInstaller.install(for: agent, reporter: reporterURL)
                if agent == .codex {
                    Preferences.shared.codexHooksVerified = false
                }
            } else {
                try HookInstaller.uninstall(for: agent)
                if agent == .codex {
                    Preferences.shared.codexHooksVerified = false
                }
            }
            model.banner = hookGuidance()
            controller.peek()
        } catch {
            let alert = NSAlert()
            alert.messageText = "Could not update \(agent.displayName) hooks"
            alert.informativeText = String(describing: error)
            alert.alertStyle = .warning
            alert.runModal()
        }
    }

    @objc private func toggleExpandOnToolChange() {
        Preferences.shared.expandOnToolChange.toggle()
    }

    @objc private func showStatus() {
        controller.peek()
    }

    @objc private func forgetSessions() {
        model.reset()
        controller.sync()
        refreshStatusItem()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

// MARK: - Menu

extension AppDelegate: NSMenuDelegate {
    /// Rebuilt on every open so it always reflects live state rather than
    /// whatever was true when the app launched.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        if let error = model.listenError {
            menu.addItem(disabled("Not listening — \(error)"))
        } else if model.isIdle {
            menu.addItem(disabled(model.isListening ? "No agents running" : "Not listening"))
        } else {
            for session in model.liveSessions {
                menu.addItem(disabled(summary(for: session)))
            }
        }

        menu.addItem(.separator())

        for agent in Agent.allCases {
            let status = HookInstaller.status(for: agent, reporter: reporterURL)
            let title: String
            if status.stale {
                title = "\(agent.displayName) hooks (update needed)"
            } else if agent == .codex, status.installed, !Preferences.shared.codexHooksVerified {
                title = "\(agent.displayName) hooks (review with /hooks)"
            } else {
                title = "\(agent.displayName) hooks"
            }
            let item = NSMenuItem(title: title, action: #selector(toggleHooks(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = agent.rawValue
            item.state = hooksReady(for: agent) ? .on : .off
            menu.addItem(item)
        }

        menu.addItem(.separator())

        let expand = NSMenuItem(
            title: "Expand when the work changes",
            action: #selector(toggleExpandOnToolChange),
            keyEquivalent: ""
        )
        expand.target = self
        expand.state = Preferences.shared.expandOnToolChange ? .on : .off
        menu.addItem(expand)

        menu.addItem(action("Show status", #selector(showStatus)))
        menu.addItem(action("Forget sessions", #selector(forgetSessions)))

        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit NotchPal", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func action(_ title: String, _ selector: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        return item
    }

    private func summary(for session: AgentSession) -> String {
        guard let headline = session.headline else { return session.agent.displayName }
        let project = session.projectName.map { " · \($0)" } ?? ""
        return "\(session.agent.displayName): \(headline.verb) \(headline.subject)\(project)"
    }
}

// MARK: - One-shot commands

enum CommandLineMode {
    static func runIfRequested() {
        let arguments = Set(CommandLine.arguments.dropFirst())
        guard !arguments.isEmpty else { return }

        let reporter = URL(filePath: CommandLine.arguments[0])
            .deletingLastPathComponent()
            .appending(path: "notchpal-report")

        func each(_ body: (Agent) throws -> Void) {
            for agent in Agent.allCases {
                do {
                    try body(agent)
                    print("\(agent.displayName): ok")
                } catch {
                    print("\(agent.displayName): \(error)")
                }
            }
        }

        if arguments.contains("--install-hooks") {
            each { try HookInstaller.install(for: $0, reporter: reporter) }
            exit(0)
        }
        if arguments.contains("--uninstall-hooks") {
            each { try HookInstaller.uninstall(for: $0) }
            exit(0)
        }
        if arguments.contains("--status") {
            print("socket:   \(EventSocket.path)")
            print("reporter: \(reporter.path(percentEncoded: false))")
            for agent in Agent.allCases {
                let status = HookInstaller.status(for: agent, reporter: reporter)
                let state = status.installed ? (status.stale ? "installed (stale path)" : "installed") : "not installed"
                print("\(agent.displayName): \(state) — \(status.configFile.path(percentEncoded: false))")
            }
            exit(0)
        }
        if arguments.contains("--help") || arguments.contains("-h") {
            print("""
            NotchPal — coding agent status in the notch.

            Run with no arguments to start the menu bar agent.

              --install-hooks      register NotchPal's hooks with Claude Code and Codex
              --uninstall-hooks    remove them again
              --status             show socket, reporter path, and hook state
            """)
            exit(0)
        }
    }
}
