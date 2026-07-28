import Foundation

/// A coding agent that can report into the notch.
public enum Agent: String, Codable, Sendable, CaseIterable {
    case claude
    case codex

    public var displayName: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        }
    }

    /// Where the agent looks for its hook configuration.
    public var configDirectory: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        switch self {
        case .claude: return home.appending(path: ".claude", directoryHint: .isDirectory)
        case .codex: return home.appending(path: ".codex", directoryHint: .isDirectory)
        }
    }
}
