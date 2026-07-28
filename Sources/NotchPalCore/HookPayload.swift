import Foundation

/// Decodes a hook payload from Claude Code or Codex into an `AgentEvent`.
///
/// The two agents converged on the same hook contract — same event names, same
/// `session_id` / `cwd` / `hook_event_name` envelope, same `tool_input` blob — so
/// one decoder serves both. Where they differ (Claude sends `user_message`, Codex
/// sends `prompt`) both spellings are accepted.
public enum HookPayload {
    /// Returns `nil` for hook events NotchPal has nothing to say about, rather than
    /// inventing a state for them.
    public static func event(from data: Data, agent: Agent) -> AgentEvent? {
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let name = ActivityDescriptor.string(root, "hook_event_name")
        else { return nil }

        let cwd = ActivityDescriptor.string(root, "cwd")
        var event = AgentEvent(
            agent: agent,
            kind: .notification,
            sessionID: ActivityDescriptor.string(root, "session_id") ?? "unknown",
            cwd: cwd,
            model: ActivityDescriptor.string(root, "model"),
            permissionMode: ActivityDescriptor.string(root, "permission_mode"),
            toolUseID: ActivityDescriptor.string(root, "tool_use_id"),
            subagent: ActivityDescriptor.string(root, "agent_type")
        )

        let toolInput = root["tool_input"] as? [String: Any] ?? [:]
        let toolName = ActivityDescriptor.string(root, "tool_name")

        switch name {
        case "SessionStart":
            event.kind = .sessionStart
            event.subtype = ActivityDescriptor.string(root, "source")

        case "SessionEnd":
            event.kind = .sessionEnd
            event.subtype = ActivityDescriptor.string(root, "end_reason")

        case "UserPromptSubmit":
            event.kind = .promptSubmit
            event.message = ActivityDescriptor.string(root, "user_message")
                ?? ActivityDescriptor.string(root, "prompt")

        case "PreToolUse":
            guard let toolName else { return nil }
            event.kind = .toolStart
            event.activity = ActivityDescriptor.describe(tool: toolName, input: toolInput, cwd: cwd)

        case "PostToolUse":
            guard let toolName else { return nil }
            event.kind = .toolEnd
            event.ok = true
            event.activity = ActivityDescriptor.describe(tool: toolName, input: toolInput, cwd: cwd)

        case "PostToolUseFailure":
            guard let toolName else { return nil }
            event.kind = .toolEnd
            event.ok = false
            event.message = ActivityDescriptor.string(root, "error_message")
            event.activity = ActivityDescriptor.describe(tool: toolName, input: toolInput, cwd: cwd)

        case "PermissionRequest", "PermissionDenied":
            event.kind = .permissionRequest
            if let toolName {
                event.activity = ActivityDescriptor.describe(tool: toolName, input: toolInput, cwd: cwd)
            }
            event.subtype = toolName

        case "Notification":
            event.kind = .notification
            event.subtype = ActivityDescriptor.string(root, "notification_type")
            event.message = ActivityDescriptor.string(root, "message")

        case "Stop":
            event.kind = .turnEnd
            event.message = ActivityDescriptor.string(root, "last_assistant_message")

        case "StopFailure":
            event.kind = .turnFailed
            event.subtype = ActivityDescriptor.string(root, "error_type")
            event.message = ActivityDescriptor.string(root, "error_message")
                ?? ActivityDescriptor.string(root, "error_type")

        case "SubagentStart":
            event.kind = .subagentStart

        case "SubagentStop":
            event.kind = .subagentStop
            event.message = ActivityDescriptor.string(root, "last_assistant_message")

        case "PreCompact":
            event.kind = .compactStart

        case "PostCompact":
            event.kind = .compactEnd

        default:
            return nil
        }

        // Long assistant messages are for the transcript, not for a strip of glass.
        if let message = event.message {
            event.message = Format.truncate(message.replacingOccurrences(of: "\n", with: " "), to: 140)
        }

        return event
    }
}
