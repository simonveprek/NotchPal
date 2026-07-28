import Foundation
import NotchPalCore

// notchpal-report — the bridge between an agent's hook and the notch.
//
// Invoked by Claude Code and Codex for every lifecycle event, with the hook
// payload on stdin. It reads, summarizes, forwards over a Unix socket, and exits.
//
// Two rules govern everything here:
//   1. Exit 0, always. A non-zero exit from a hook can block the agent's tool call.
//   2. Write nothing to stdout. Agents parse hook stdout as JSON control output;
//      stray text there is at best ignored and at worst read as an instruction.
// Diagnostics go to stderr, and only when explicitly asked for.

let arguments = Array(CommandLine.arguments.dropFirst())
let verbose = arguments.contains("--verbose")
    || ProcessInfo.processInfo.environment["NOTCHPAL_VERBOSE"] == "1"
    || ProcessInfo.processInfo.environment["NOTCHPAL_VERBOSE"] == "1"

func note(_ message: @autoclosure () -> String) {
    guard verbose else { return }
    FileHandle.standardError.write(Data("notchpal-report: \(message())\n".utf8))
}

func value(for flag: String) -> String? {
    guard let index = arguments.firstIndex(of: flag), arguments.index(after: index) < arguments.endIndex else {
        return nil
    }
    return arguments[arguments.index(after: index)]
}

if arguments.contains("--help") || arguments.contains("-h") {
    FileHandle.standardError.write(Data("""
    usage: notchpal-report --agent <claude|codex> [--verbose]

    Reads a hook payload on stdin and forwards it to the running NotchPal app.
    Always exits 0 so it can never interrupt the agent that called it.

    """.utf8))
    exit(0)
}

guard let agentName = value(for: "--agent"), let agent = Agent(rawValue: agentName.lowercased()) else {
    note("missing or unknown --agent; expected one of \(Agent.allCases.map(\.rawValue).joined(separator: ", "))")
    exit(0)
}

// Hook payloads are small. Cap the read so a pathological one cannot balloon here.
let maxPayload = 4 << 20
var input = Data()
while input.count < maxPayload, let chunk = try? FileHandle.standardInput.read(upToCount: 1 << 16), !chunk.isEmpty {
    input.append(chunk)
}

guard !input.isEmpty else {
    note("empty stdin")
    exit(0)
}

guard let event = HookPayload.event(from: input, agent: agent) else {
    note("payload produced no event (unhandled hook, or malformed JSON)")
    exit(0)
}

let delivered = EventClient.send(event)
note("\(event.kind.rawValue) \(event.activity?.subject ?? "") -> \(delivered ? "delivered" : "no listener")")
exit(0)
