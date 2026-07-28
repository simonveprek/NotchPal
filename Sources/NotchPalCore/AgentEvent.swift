import Foundation

/// One normalized moment in an agent's life, as it travels from a hook to the notch.
///
/// Both Claude Code and Codex expose nearly the same hook contract, so a single
/// event shape covers both. `notchpal-report` does the parsing and summarizing so the
/// app receives something small and already-rendered-to-language.
public struct AgentEvent: Codable, Sendable {
    /// Wire format version. Bumped when the shape changes incompatibly.
    public static let currentVersion = 1

    public var v: Int
    public var agent: Agent
    public var kind: Kind
    /// The agent's own session/thread identifier. Distinguishes concurrent windows.
    public var sessionID: String
    public var at: Date

    public var cwd: String?
    public var model: String?
    public var permissionMode: String?

    /// Correlates `toolStart` with its matching `toolEnd`.
    public var toolUseID: String?
    public var activity: Activity?

    /// Notification text, or a snippet of the agent's last message.
    public var message: String?
    /// The event's own discriminator where it has one: `source` for a session
    /// start, `notification_type` for a notification, `error_type` for a failure.
    public var subtype: String?
    public var subagent: String?
    /// For `toolEnd`: whether the tool succeeded.
    public var ok: Bool?

    public enum Kind: String, Codable, Sendable {
        case sessionStart
        case sessionEnd
        case promptSubmit
        case toolStart
        case toolEnd
        case permissionRequest
        case notification
        case turnEnd
        case turnFailed
        case subagentStart
        case subagentStop
        case compactStart
        case compactEnd
    }

    public init(
        v: Int = AgentEvent.currentVersion,
        agent: Agent,
        kind: Kind,
        sessionID: String,
        at: Date = Date(),
        cwd: String? = nil,
        model: String? = nil,
        permissionMode: String? = nil,
        toolUseID: String? = nil,
        activity: Activity? = nil,
        message: String? = nil,
        subtype: String? = nil,
        subagent: String? = nil,
        ok: Bool? = nil
    ) {
        self.v = v
        self.agent = agent
        self.kind = kind
        self.sessionID = sessionID
        self.at = at
        self.cwd = cwd
        self.model = model
        self.permissionMode = permissionMode
        self.toolUseID = toolUseID
        self.activity = activity
        self.message = message
        self.subtype = subtype
        self.subagent = subagent
        self.ok = ok
    }
}

/// What the agent is doing right now, decomposed so the UI can typeset it well:
/// `[glyph] Reading **DynamicNotch.swift** · lines 1–200`
public struct Activity: Codable, Sendable, Equatable {
    /// The raw tool name, kept for power users and for matcher debugging.
    public var tool: String
    public var category: Category
    /// Present participle: "Reading", "Running", "Searching".
    public var verb: String
    /// The thing being acted on — a filename, a command, a query.
    public var subject: String
    /// Secondary detail — a line range, a directory, a byte count.
    public var qualifier: String?

    public enum Category: String, Codable, Sendable {
        case read, edit, write, execute, search, browse, delegate, plan, mcp, other

        /// SF Symbol shown alongside the activity.
        public var symbol: String {
            switch self {
            case .read: "text.page"
            case .edit: "pencil.line"
            case .write: "square.and.pencil"
            case .execute: "apple.terminal"
            case .search: "magnifyingglass"
            case .browse: "globe"
            case .delegate: "person.2"
            case .plan: "checklist"
            case .mcp: "puzzlepiece.extension"
            case .other: "gearshape"
            }
        }
    }

    public init(tool: String, category: Category, verb: String, subject: String, qualifier: String? = nil) {
        self.tool = tool
        self.category = category
        self.verb = verb
        self.subject = subject
        self.qualifier = qualifier
    }
}

// MARK: - JSON coding

public extension AgentEvent {
    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    /// One event, one line — the socket protocol is newline-delimited JSON.
    func lineEncoded() throws -> Data {
        var data = try AgentEvent.encoder.encode(self)
        data.append(0x0A)
        return data
    }
}
