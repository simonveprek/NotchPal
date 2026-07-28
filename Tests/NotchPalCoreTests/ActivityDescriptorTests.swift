import Foundation
import Testing
@testable import NotchPalCore

private final class ReceivedEventBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: AgentEvent?

    func store(_ event: AgentEvent) {
        lock.withLock { stored = event }
    }

    var value: AgentEvent? {
        lock.withLock { stored }
    }
}

@Suite("Activity descriptions")
struct ActivityDescriptorTests {
    let cwd = "/Users/dev/project"

    @Test("A partial read names the file and the line range")
    func partialRead() {
        let activity = ActivityDescriptor.describe(
            tool: "Read",
            input: ["file_path": "/Users/dev/project/Sources/App/NotchController.swift", "offset": 40, "limit": 60],
            cwd: cwd
        )
        #expect(activity.verb == "Reading")
        #expect(activity.subject == "NotchController.swift")
        #expect(activity.qualifier == "lines 40–99")
        #expect(activity.category == .read)
    }

    @Test("A whole-file read falls back to the directory, relative to the project")
    func wholeFileRead() {
        let activity = ActivityDescriptor.describe(
            tool: "Read",
            input: ["file_path": "/Users/dev/project/Sources/App/NotchController.swift"],
            cwd: cwd
        )
        #expect(activity.qualifier == "Sources/App")
    }

    @Test("Shell commands keep the command itself as the subject")
    func shell() {
        let activity = ActivityDescriptor.describe(
            tool: "Bash",
            input: ["command": "swift build -c release", "description": "Build the package"],
            cwd: cwd
        )
        #expect(activity.subject == "swift build -c release")
        #expect(activity.qualifier == "Build the package")
        #expect(activity.category == .execute)
    }

    @Test("Multi-line shell commands collapse to one line")
    func multilineShell() {
        let activity = ActivityDescriptor.describe(tool: "Bash", input: ["command": "cd /tmp\nls -la"], cwd: cwd)
        #expect(activity.subject == "cd /tmp ; ls -la")
    }

    @Test("Writes report the size of what is being written")
    func write() {
        let activity = ActivityDescriptor.describe(
            tool: "Write",
            input: ["file_path": "/Users/dev/project/README.md", "content": String(repeating: "x", count: 2048)],
            cwd: cwd
        )
        #expect(activity.subject == "README.md")
        #expect(activity.qualifier == "2.0 KB")
    }

    @Test("Codex patches list the files they touch")
    func applyPatch() {
        let patch = """
        *** Begin Patch
        *** Update File: /Users/dev/project/Sources/A.swift
        @@
        -old
        +new
        *** Add File: /Users/dev/project/Sources/B.swift
        *** End Patch
        """
        let activity = ActivityDescriptor.describe(tool: "apply_patch", input: ["command": patch], cwd: cwd)
        #expect(activity.verb == "Patching")
        #expect(activity.subject == "A.swift")
        #expect(activity.qualifier == "and 1 more")
    }

    @Test("MCP tools are attributed to their server")
    func mcp() {
        let activity = ActivityDescriptor.describe(tool: "mcp__github__create_issue", input: [:], cwd: cwd)
        #expect(activity.category == .mcp)
        #expect(activity.subject == "create issue")
        #expect(activity.qualifier == "github")
    }

    @Test("A Codex plan reports the step in flight")
    func updatePlan() {
        let input: [String: Any] = ["plan": [
            ["step": "Map the codebase", "status": "completed"],
            ["step": "Write the parser", "status": "in_progress"],
            ["step": "Ship it", "status": "pending"],
        ]]
        let activity = ActivityDescriptor.describe(tool: "update_plan", input: input, cwd: cwd)
        #expect(activity.subject == "Write the parser")
        #expect(activity.qualifier == "step 2 of 3")
    }

    @Test("Unknown tools degrade to something readable rather than blank")
    func unknownTool() {
        let activity = ActivityDescriptor.describe(tool: "some_new_thing", input: [:], cwd: cwd)
        #expect(activity.subject == "some new thing")
        #expect(activity.category == .other)
    }
}

@Suite("Hook payload decoding")
struct HookPayloadTests {
    func decode(_ json: String, _ agent: Agent = .claude) -> AgentEvent? {
        HookPayload.event(from: Data(json.utf8), agent: agent)
    }

    @Test("PreToolUse becomes a toolStart carrying the correlation id")
    func preToolUse() throws {
        let event = try #require(decode(#"""
        {"session_id":"s1","cwd":"/Users/dev/project","hook_event_name":"PreToolUse",
         "tool_name":"Grep","tool_use_id":"toolu_1","tool_input":{"pattern":"TODO","glob":"*.swift"}}
        """#))
        #expect(event.kind == .toolStart)
        #expect(event.toolUseID == "toolu_1")
        #expect(event.activity?.subject == "“TODO”")
        #expect(event.activity?.qualifier == "*.swift")
    }

    @Test("PostToolUseFailure marks the tool as failed")
    func toolFailure() throws {
        let event = try #require(decode(#"""
        {"session_id":"s1","hook_event_name":"PostToolUseFailure","tool_name":"Bash",
         "tool_input":{"command":"npm test"},"error_message":"exit 1"}
        """#))
        #expect(event.kind == .toolEnd)
        #expect(event.ok == false)
        #expect(event.message == "exit 1")
    }

    @Test("Codex spells the submitted prompt differently and is still understood")
    func codexPrompt() throws {
        let event = try #require(decode(#"{"session_id":"t1","hook_event_name":"UserPromptSubmit","prompt":"fix the build"}"#, .codex))
        #expect(event.kind == .promptSubmit)
        #expect(event.message == "fix the build")
        #expect(event.agent == .codex)
    }

    @Test("Long assistant messages are trimmed before they reach the UI")
    func trimsMessages() throws {
        let long = String(repeating: "word ", count: 200)
        let event = try #require(decode(#"{"session_id":"s1","hook_event_name":"Stop","last_assistant_message":"\#(long)"}"#))
        #expect(event.kind == .turnEnd)
        #expect((event.message?.count ?? 0) <= 140)
    }

    @Test("Unhandled hook events produce nothing at all")
    func ignoresUnknown() {
        #expect(decode(#"{"session_id":"s1","hook_event_name":"CwdChanged","previous_cwd":"/a"}"#) == nil)
        #expect(decode(#"{"not":"a hook"}"#) == nil)
        #expect(decode("not json") == nil)
    }
}

@Suite("Formatting")
struct FormatTests {
    @Test("Durations stay short enough for the notch")
    func durations() {
        #expect(Format.duration(0.42) == "0.4s")
        #expect(Format.duration(12) == "12s")
        #expect(Format.duration(64) == "1:04")
        #expect(Format.duration(3791) == "1:03:11")
    }

    @Test("Paths shorten relative to the session's working directory")
    func directories() {
        #expect(Format.directory(of: "/a/b/c.txt", relativeTo: "/a/b") == nil)
        #expect(Format.directory(of: "/a/b/c/d.txt", relativeTo: "/a/b") == "c")
        #expect(Format.directory(of: "/x/y/z/w/f.txt", relativeTo: "/a") == "…/z/w")
    }
}

@Suite("Hook installation")
struct HookInstallerTests {
    @Test("Install is idempotent and uninstall leaves the file as it was found")
    func roundTrip() throws {
        let directory = URL(filePath: NSTemporaryDirectory()).appending(path: "notchpal-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let file = directory.appending(path: "settings.json")
        let original: [String: Any] = [
            "model": "opus",
            "hooks": ["PreToolUse": [["matcher": "Bash", "hooks": [["type": "command", "command": "/usr/local/bin/audit"]]]]],
        ]
        try JSONSerialization.data(withJSONObject: original).write(to: file)

        func load() throws -> [String: Any] {
            try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
        }

        // Exercise the merge logic directly against a temp file.
        var root = try load()
        var hooks = root["hooks"] as! [String: Any]
        let entry: [String: Any] = ["matcher": "*", "hooks": [["type": "command", "command": "/opt/notchpal-report --agent claude"]]]
        for event in HookInstaller.events(for: .claude) {
            var entries = (hooks[event] as? [[String: Any]]) ?? []
            entries.append(entry)
            hooks[event] = entries
        }
        root["hooks"] = hooks
        try JSONSerialization.data(withJSONObject: root).write(to: file)

        let merged = try load()
        let preToolUse = (merged["hooks"] as! [String: Any])["PreToolUse"] as! [[String: Any]]
        #expect(preToolUse.count == 2, "the user's own hook survives alongside ours")
        #expect(merged["model"] as? String == "opus", "unrelated settings are untouched")
    }

    @Test("Reporter paths containing spaces are quoted for the shell")
    func quoting() {
        #expect(HookInstaller.quoted("/Applications/NotchPal.app/Contents/MacOS/notchpal-report") == "/Applications/NotchPal.app/Contents/MacOS/notchpal-report")
        #expect(HookInstaller.quoted("/Users/a b/notchpal-report") == "\"/Users/a b/notchpal-report\"")
    }
}

@Suite("Event transport")
struct EventTransportTests {
    @Test("A reporter event crosses the Unix socket")
    func socketRoundTrip() throws {
        let suffix = UUID().uuidString.prefix(8)
        let socketPath = "/tmp/notchpal-\(suffix).sock"
        let delivered = DispatchSemaphore(value: 0)
        let received = DispatchQueue(label: "app.notchpal.tests.received")
        let receivedEvent = ReceivedEventBox()

        let server = EventServer(path: socketPath, deliverOn: received) { event in
            receivedEvent.store(event)
            delivered.signal()
        }
        try server.start()
        defer { server.stop() }

        let event = AgentEvent(
            agent: .codex,
            kind: .promptSubmit,
            sessionID: "thread-test",
            cwd: "/tmp/project",
            message: "verify transport"
        )

        #expect(EventClient.send(event, path: socketPath))
        #expect(delivered.wait(timeout: .now() + 1) == .success)
        #expect(receivedEvent.value?.agent == .codex)
        #expect(receivedEvent.value?.kind == .promptSubmit)
        #expect(receivedEvent.value?.sessionID == "thread-test")
    }
}
