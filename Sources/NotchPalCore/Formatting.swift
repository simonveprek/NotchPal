import Foundation

public enum Format {
    /// Compact, glanceable durations. The notch has room for about six characters.
    ///
    ///     0.4s   ·   12s   ·   1:04   ·   14:22   ·   2:03:11
    public static func duration(_ seconds: TimeInterval) -> String {
        let s = max(0, seconds)
        if s < 1 { return String(format: "%.1fs", s) }
        if s < 60 { return "\(Int(s.rounded()))s" }
        let total = Int(s.rounded())
        let (h, m, sec) = (total / 3600, (total % 3600) / 60, total % 60)
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, sec) }
        return String(format: "%d:%02d", m, sec)
    }

    public static func bytes(_ count: Int) -> String {
        let units = ["B", "KB", "MB", "GB"]
        var value = Double(count)
        var unit = 0
        while value >= 1024, unit < units.count - 1 {
            value /= 1024
            unit += 1
        }
        return unit == 0 ? "\(count) B" : String(format: "%.1f %@", value, units[unit])
    }

    /// The part of a path a developer actually reads: the file name.
    public static func fileName(_ path: String) -> String {
        (path as NSString).lastPathComponent
    }

    /// The directory a file lives in, shortened relative to the session's working
    /// directory when possible, then to `~`, then to its last two components.
    public static func directory(of path: String, relativeTo cwd: String?) -> String? {
        let dir = (path as NSString).deletingLastPathComponent
        guard !dir.isEmpty, dir != "/" else { return nil }
        if let cwd, dir == cwd { return nil }
        if let cwd, dir.hasPrefix(cwd + "/") {
            return String(dir.dropFirst(cwd.count + 1))
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if dir == home { return "~" }
        if dir.hasPrefix(home + "/") { return "~/" + String(dir.dropFirst(home.count + 1)) }
        let parts = dir.split(separator: "/")
        if parts.count > 2 { return "…/" + parts.suffix(2).joined(separator: "/") }
        return dir
    }

    /// The last path component of a working directory — what people call "the project".
    public static func projectName(_ cwd: String?) -> String? {
        guard let cwd, !cwd.isEmpty else { return nil }
        let name = (cwd as NSString).lastPathComponent
        return name.isEmpty ? nil : name
    }

    /// Collapses a shell command to a single readable line.
    public static func command(_ raw: String, limit: Int = 64) -> String {
        let collapsed = raw
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ; ")
        return truncate(collapsed.isEmpty ? raw : collapsed, to: limit)
    }

    public static func truncate(_ text: String, to limit: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        return trimmed.prefix(limit - 1).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// Turns `mcp__github__create_issue` into ("github", "create issue").
    public static func mcpComponents(_ tool: String) -> (server: String, tool: String)? {
        guard tool.hasPrefix("mcp__") else { return nil }
        let parts = tool.dropFirst(5).components(separatedBy: "__")
        guard let server = parts.first, !server.isEmpty else { return nil }
        let rest = parts.dropFirst().joined(separator: " ").replacingOccurrences(of: "_", with: " ")
        return (server, rest.isEmpty ? "call" : rest)
    }
}
