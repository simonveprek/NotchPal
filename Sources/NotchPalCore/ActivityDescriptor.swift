import Foundation

/// Turns a raw `tool_name` + `tool_input` pair into a sentence a human wants to read.
///
/// This is where most of NotchPal's value lives. "Running a tool" is noise; "Reading
/// `DynamicNotch.swift`, lines 1–200" is information. Every branch below exists
/// because the generic version of it was not worth glancing up at.
public enum ActivityDescriptor {
    public static func describe(tool: String, input: [String: Any], cwd: String?) -> Activity {
        // MCP tools are namespaced and never collide with built-ins, so check first.
        if let mcp = Format.mcpComponents(tool) {
            return Activity(
                tool: tool,
                category: .mcp,
                verb: "Calling",
                subject: mcp.tool,
                qualifier: mcp.server
            )
        }

        switch tool {
        case "Read", "read_file", "view_image":
            return read(tool: tool, input: input, cwd: cwd)
        case "Edit", "MultiEdit", "NotebookEdit":
            return edit(tool: tool, input: input, cwd: cwd)
        case "Write", "create_file":
            return write(tool: tool, input: input, cwd: cwd)
        case "apply_patch":
            return patch(tool: tool, input: input, cwd: cwd)
        case "Bash", "shell", "exec", "exec_command", "local_shell":
            return shell(tool: tool, input: input)
        case "BashOutput":
            return Activity(tool: tool, category: .execute, verb: "Reading", subject: "shell output")
        case "KillShell", "KillBash":
            return Activity(tool: tool, category: .execute, verb: "Stopping", subject: "shell")
        case "Grep", "search", "ripgrep":
            return grep(tool: tool, input: input, cwd: cwd)
        case "Glob":
            return glob(tool: tool, input: input, cwd: cwd)
        case "WebFetch", "fetch":
            return webFetch(tool: tool, input: input)
        case "WebSearch", "web_search":
            let query = string(input, "query") ?? string(input, "q") ?? "the web"
            return Activity(tool: tool, category: .browse, verb: "Searching", subject: "“\(Format.truncate(query, to: 48))”", qualifier: "web")
        case "Task", "Agent", "spawn_agent":
            return delegate(tool: tool, input: input)
        case "TodoWrite", "update_plan", "TaskCreate", "TaskUpdate":
            return plan(tool: tool, input: input)
        case "ExitPlanMode", "EnterPlanMode":
            return Activity(tool: tool, category: .plan, verb: "Presenting", subject: "a plan")
        default:
            let pretty = tool
                .replacingOccurrences(of: "_", with: " ")
                .trimmingCharacters(in: .whitespaces)
            return Activity(tool: tool, category: .other, verb: "Running", subject: pretty.isEmpty ? "a tool" : pretty)
        }
    }

    // MARK: - Per-tool detail

    private static func read(tool: String, input: [String: Any], cwd: String?) -> Activity {
        let path = string(input, "file_path") ?? string(input, "path") ?? string(input, "target_file") ?? "a file"
        var qualifier = Format.directory(of: path, relativeTo: cwd)

        // A line range is the single most useful thing to know about a partial read.
        let offset = int(input, "offset")
        let limit = int(input, "limit")
        if let offset, let limit {
            qualifier = "lines \(offset)–\(offset + limit - 1)"
        } else if let limit {
            qualifier = "first \(limit) lines"
        } else if let pages = string(input, "pages") {
            qualifier = "pages \(pages)"
        }

        return Activity(tool: tool, category: .read, verb: "Reading", subject: Format.fileName(path), qualifier: qualifier)
    }

    private static func edit(tool: String, input: [String: Any], cwd: String?) -> Activity {
        let path = string(input, "file_path") ?? string(input, "path") ?? "a file"
        var qualifier = Format.directory(of: path, relativeTo: cwd)
        if bool(input, "replace_all") == true {
            qualifier = "replacing every match"
        } else if let edits = input["edits"] as? [Any], edits.count > 1 {
            qualifier = "\(edits.count) edits"
        }
        return Activity(tool: tool, category: .edit, verb: "Editing", subject: Format.fileName(path), qualifier: qualifier)
    }

    private static func write(tool: String, input: [String: Any], cwd: String?) -> Activity {
        let path = string(input, "file_path") ?? string(input, "path") ?? "a file"
        let content = string(input, "content") ?? string(input, "contents")
        let qualifier = content.map { Format.bytes($0.utf8.count) } ?? Format.directory(of: path, relativeTo: cwd)
        return Activity(tool: tool, category: .write, verb: "Writing", subject: Format.fileName(path), qualifier: qualifier)
    }

    /// Codex edits files by shipping a patch envelope. The file list is in the body.
    private static func patch(tool: String, input: [String: Any], cwd: String?) -> Activity {
        let body = string(input, "command") ?? string(input, "input") ?? string(input, "patch") ?? firstLongString(input) ?? ""
        let files = patchedFiles(in: body)

        switch files.count {
        case 0:
            return Activity(tool: tool, category: .edit, verb: "Applying", subject: "a patch")
        case 1:
            return Activity(
                tool: tool,
                category: .edit,
                verb: "Patching",
                subject: Format.fileName(files[0]),
                qualifier: Format.directory(of: files[0], relativeTo: cwd)
            )
        default:
            return Activity(
                tool: tool,
                category: .edit,
                verb: "Patching",
                subject: Format.fileName(files[0]),
                qualifier: "and \(files.count - 1) more"
            )
        }
    }

    /// Pulls paths out of `*** Add|Update|Delete File: <path>` lines.
    static func patchedFiles(in patch: String) -> [String] {
        var files: [String] = []
        for line in patch.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("***") else { continue }
            for marker in ["Add File:", "Update File:", "Delete File:", "Move to:"] {
                guard let range = trimmed.range(of: marker) else { continue }
                let path = trimmed[range.upperBound...].trimmingCharacters(in: .whitespaces)
                if !path.isEmpty { files.append(path) }
                break
            }
        }
        return files
    }

    private static func shell(tool: String, input: [String: Any]) -> Activity {
        var raw = string(input, "command") ?? string(input, "script") ?? ""
        if raw.isEmpty, let argv = input["cmd"] as? [Any] {
            raw = argv.compactMap { $0 as? String }.joined(separator: " ")
        }
        if raw.isEmpty { raw = string(input, "cmd") ?? "a command" }

        // Claude passes a human description alongside the command; it makes a good subtitle.
        let description = string(input, "description")
        let background = bool(input, "run_in_background") == true
        let qualifier = background ? "in the background" : description.map { Format.truncate($0, to: 40) }

        return Activity(tool: tool, category: .execute, verb: "Running", subject: Format.command(raw), qualifier: qualifier)
    }

    private static func grep(tool: String, input: [String: Any], cwd: String?) -> Activity {
        let pattern = string(input, "pattern") ?? string(input, "query") ?? "something"
        var qualifier: String?
        if let path = string(input, "path") {
            qualifier = Format.projectName(path).map { path == cwd ? $0 : ($0 + "/") } ?? path
            if let cwd, path.hasPrefix(cwd + "/") { qualifier = String(path.dropFirst(cwd.count + 1)) + "/" }
        }
        if let glob = string(input, "glob") { qualifier = glob }
        return Activity(
            tool: tool,
            category: .search,
            verb: "Searching",
            subject: "“\(Format.truncate(pattern, to: 40))”",
            qualifier: qualifier
        )
    }

    private static func glob(tool: String, input: [String: Any], cwd: String?) -> Activity {
        let pattern = string(input, "pattern") ?? "*"
        var qualifier: String?
        if let path = string(input, "path"), path != cwd {
            qualifier = Format.directory(of: path + "/x", relativeTo: cwd)
        }
        return Activity(tool: tool, category: .search, verb: "Finding", subject: pattern, qualifier: qualifier)
    }

    private static func webFetch(tool: String, input: [String: Any]) -> Activity {
        let raw = string(input, "url") ?? "a page"
        let components = URLComponents(string: raw)
        let host = components?.host?.replacingOccurrences(of: "www.", with: "") ?? Format.truncate(raw, to: 40)
        var qualifier = components?.path
        if qualifier == "/" || qualifier?.isEmpty == true { qualifier = nil }
        return Activity(tool: tool, category: .browse, verb: "Fetching", subject: host, qualifier: qualifier.map { Format.truncate($0, to: 32) })
    }

    private static func delegate(tool: String, input: [String: Any]) -> Activity {
        let what = string(input, "description") ?? string(input, "subject") ?? "a subtask"
        let type = string(input, "subagent_type") ?? string(input, "agent_type")
        return Activity(
            tool: tool,
            category: .delegate,
            verb: "Delegating",
            subject: Format.truncate(what, to: 44),
            qualifier: type
        )
    }

    private static func plan(tool: String, input: [String: Any]) -> Activity {
        // Codex's update_plan carries the whole checklist; surface the step in flight.
        if let steps = input["plan"] as? [[String: Any]], !steps.isEmpty {
            let done = steps.filter { ($0["status"] as? String) == "completed" }.count
            let current = steps.first { ($0["status"] as? String) == "in_progress" }
            let label = current.flatMap { $0["step"] as? String } ?? "the plan"
            return Activity(
                tool: tool,
                category: .plan,
                verb: "Working on",
                subject: Format.truncate(label, to: 44),
                qualifier: "step \(min(done + 1, steps.count)) of \(steps.count)"
            )
        }
        if let subject = string(input, "subject") {
            return Activity(tool: tool, category: .plan, verb: "Tracking", subject: Format.truncate(subject, to: 44))
        }
        if let todos = input["todos"] as? [Any] {
            return Activity(tool: tool, category: .plan, verb: "Updating", subject: "the plan", qualifier: "\(todos.count) items")
        }
        return Activity(tool: tool, category: .plan, verb: "Updating", subject: "the plan")
    }

    // MARK: - Loose JSON accessors
    //
    // Hook payloads are the agents' own shapes, and they drift between releases.
    // Reading defensively costs a few lines and keeps a schema change from
    // turning into a blank notch.

    static func string(_ dict: [String: Any], _ key: String) -> String? {
        guard let value = dict[key] as? String, !value.isEmpty else { return nil }
        return value
    }

    static func int(_ dict: [String: Any], _ key: String) -> Int? {
        if let n = dict[key] as? Int { return n }
        if let n = dict[key] as? Double { return Int(n) }
        if let s = dict[key] as? String { return Int(s) }
        return nil
    }

    static func bool(_ dict: [String: Any], _ key: String) -> Bool? {
        if let b = dict[key] as? Bool { return b }
        if let s = dict[key] as? String { return s == "true" }
        return nil
    }

    private static func firstLongString(_ dict: [String: Any]) -> String? {
        dict.values.compactMap { $0 as? String }.max { $0.count < $1.count }
    }
}
