import Foundation

/// Registers (and removes) NotchPal's hooks in the agents' own configuration files.
///
/// Both agents read a `hooks` map keyed by event name, so the shape below is
/// identical for each — only the file differs. Claude Code keeps hooks inside
/// `~/.claude/settings.json`; Codex reads a dedicated `~/.codex/hooks.json`.
///
/// Everything here is written to be a good guest in a file the user owns:
/// existing keys are preserved, a timestamped backup is taken before the first
/// write, and uninstall removes exactly what install added.
public enum HookInstaller {
    /// Hook entries are recognized as ours by the binary they invoke. Keep the
    /// old name so installing NotchPal upgrades existing Islet hooks in place.
    static let signature = "notchpal-report"
    static let legacySignature = "islet-report"

    public struct Status: Sendable {
        public var agent: Agent
        public var configFile: URL
        public var installed: Bool
        /// Set when hooks point at a different copy of `notchpal-report` than this one.
        public var stale: Bool
    }

    public enum InstallError: Error, CustomStringConvertible {
        case unreadable(URL)
        case notAnObject(URL)

        public var description: String {
            switch self {
            case let .unreadable(url): "Could not read \(url.path(percentEncoded: false))"
            case let .notAnObject(url): "\(url.lastPathComponent) is not a JSON object"
            }
        }
    }

    /// The events NotchPal subscribes to, per agent.
    ///
    /// Deliberately not every event the agents offer — only the ones that change
    /// what the notch should be showing. Each extra subscription is another
    /// process spawned on the agent's critical path.
    static func events(for agent: Agent) -> [String] {
        var shared = [
            "SessionStart",
            "SessionEnd",
            "UserPromptSubmit",
            "PreToolUse",
            "PostToolUse",
            "Stop",
            "SubagentStart",
            "SubagentStop",
            "PreCompact",
            "PostCompact",
            "PermissionRequest",
        ]
        if agent == .claude {
            // Claude reports tool failures and turn failures as distinct events.
            shared.append(contentsOf: ["PostToolUseFailure", "StopFailure", "Notification"])
        }
        return shared
    }

    public static func configFile(for agent: Agent) -> URL {
        switch agent {
        case .claude: agent.configDirectory.appending(path: "settings.json")
        case .codex: agent.configDirectory.appending(path: "hooks.json")
        }
    }

    // MARK: - Inspection

    public static func status(for agent: Agent, reporter: URL) -> Status {
        let file = configFile(for: agent)
        guard
            let root = try? loadObject(at: file),
            let hooks = root["hooks"] as? [String: Any]
        else {
            return Status(agent: agent, configFile: file, installed: false, stale: false)
        }

        let commands = hooks.values
            .compactMap { $0 as? [[String: Any]] }
            .flatMap { $0 }
            .compactMap { $0["hooks"] as? [[String: Any]] }
            .flatMap { $0 }
            .compactMap { $0["command"] as? String }
            .filter { isReporterCommand($0) }

        guard !commands.isEmpty else {
            return Status(agent: agent, configFile: file, installed: false, stale: false)
        }
        let expected = quoted(reporter.path(percentEncoded: false))
        return Status(
            agent: agent,
            configFile: file,
            installed: true,
            stale: !commands.allSatisfy { $0.hasPrefix(expected) }
        )
    }

    // MARK: - Mutation

    public static func install(for agent: Agent, reporter: URL) throws {
        let file = configFile(for: agent)
        var root = (try? loadObject(at: file)) ?? [:]
        var hooks = root["hooks"] as? [String: Any] ?? [:]

        let entry: [String: Any] = [
            "matcher": "*",
            "hooks": [[
                "type": "command",
                "command": "\(quoted(reporter.path(percentEncoded: false))) --agent \(agent.rawValue)",
                "timeout": 5,
            ]],
        ]

        for event in events(for: agent) {
            var existing = (hooks[event] as? [[String: Any]]) ?? []
            existing.removeAll(where: isOurs)
            existing.append(entry)
            hooks[event] = existing
        }

        root["hooks"] = hooks
        if agent == .codex {
            root["description"] = "NotchPal — live coding agent status in the notch"
        }
        try write(root, to: file)
    }

    public static func uninstall(for agent: Agent) throws {
        let file = configFile(for: agent)
        guard var root = try? loadObject(at: file), var hooks = root["hooks"] as? [String: Any] else { return }

        for (event, value) in hooks {
            guard var entries = value as? [[String: Any]] else { continue }
            entries.removeAll(where: isOurs)
            // Leave no empty scaffolding behind.
            if entries.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = entries }
        }

        if hooks.isEmpty { root.removeValue(forKey: "hooks") } else { root["hooks"] = hooks }
        if agent == .codex,
           let description = root["description"] as? String,
           description.hasPrefix("Islet") || description.hasPrefix("NotchPal")
        {
            root.removeValue(forKey: "description")
        }
        try write(root, to: file)
    }

    // MARK: - Plumbing

    private static func isOurs(_ entry: [String: Any]) -> Bool {
        guard let inner = entry["hooks"] as? [[String: Any]] else { return false }
        return !inner.isEmpty && inner.allSatisfy {
            guard let command = $0["command"] as? String else { return false }
            return isReporterCommand(command)
        }
    }

    private static func isReporterCommand(_ command: String) -> Bool {
        command.contains(signature) || command.contains(legacySignature)
    }

    private static func loadObject(at url: URL) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return [:] }
        guard let data = try? Data(contentsOf: url) else { throw InstallError.unreadable(url) }
        if data.isEmpty { return [:] }
        guard let object = try? JSONSerialization.jsonObject(with: data) else { throw InstallError.unreadable(url) }
        guard let dictionary = object as? [String: Any] else { throw InstallError.notAnObject(url) }
        return dictionary
    }

    private static func write(_ object: [String: Any], to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // Back up the user's own file once per change, before we touch it.
        if FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
            let stamp = Int(Date().timeIntervalSince1970)
            let backup = url.appendingPathExtension("notchpal-\(stamp).bak")
            try? FileManager.default.copyItem(at: url, to: backup)
        }

        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        try data.write(to: url, options: .atomic)
    }

    /// Reporter paths can contain spaces (`~/Library/Application Support/…`).
    static func quoted(_ path: String) -> String {
        path.contains(" ") ? "\"\(path)\"" : path
    }
}
