import Foundation

enum AgentKind: String, CaseIterable, Codable {
    case claude = "Claude"
    case codex = "Codex"
    case grok = "Grok"
    case opencode = "OpenCode"
    case pi = "Pi"
    case omp = "Oh My Pi"

    /// Executable basenames that indicate this agent is running.
    var processNames: [String] {
        switch self {
        case .claude: return ["claude"]
        case .codex: return ["codex"]
        case .grok: return ["grok"]
        case .opencode: return ["opencode"]
        case .pi: return ["pi"]
        case .omp: return ["omp"]
        }
    }

    /// Stable prefix for session ids (display names can have spaces).
    var idPrefix: String {
        switch self {
        case .omp: return "omp"
        default: return rawValue.lowercased()
        }
    }
}

enum SessionState: Int, Comparable {
    case working = 0
    case waiting = 1
    case done = 2

    static func < (lhs: SessionState, rhs: SessionState) -> Bool { lhs.rawValue < rhs.rawValue }
}

struct AgentSession: Identifiable, Equatable {
    let id: String            // e.g. "claude:<session-uuid>"
    let kind: AgentKind
    let projectName: String
    let cwd: String?
    let activity: String
    let state: SessionState
    let startedAt: Date
    let lastActivityAt: Date  // for done sessions, when the turn finished
    var lastMessage: String? = nil  // latest agent-authored text, for the dropdown
    var debugInfo: String? = nil    // why the provider chose this state (--debug)
    var subAgents: [AgentSession] = []  // sub-agents spawned by this session

    // debugInfo carries per-tick details (ages etc.) and must not make two
    // otherwise-identical snapshots unequal, or the UI would churn every tick.
    static func == (lhs: AgentSession, rhs: AgentSession) -> Bool {
        lhs.id == rhs.id && lhs.state == rhs.state && lhs.activity == rhs.activity
            && lhs.projectName == rhs.projectName && lhs.startedAt == rhs.startedAt
            && lhs.lastActivityAt == rhs.lastActivityAt && lhs.lastMessage == rhs.lastMessage
            && lhs.subAgents == rhs.subAgents
    }
}

extension String {
    /// Collapse whitespace/newlines into a compact single-spaced snippet.
    var messageSnippet: String? {
        let collapsed = split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if collapsed.isEmpty { return nil }
        return collapsed.count > 280 ? String(collapsed.prefix(280)) + "…" : collapsed
    }
}

extension AgentSession {
    var elapsedText: String {
        let seconds = max(0, Date().timeIntervalSince(startedAt))
        return Self.shortDuration(seconds)
    }

    var finishedAgoText: String {
        let seconds = max(0, Date().timeIntervalSince(lastActivityAt))
        return "finished \(Self.shortDuration(seconds)) ago"
    }

    static func shortDuration(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        if minutes < 1 { return "<1m" }
        if minutes < 60 { return "\(minutes)m" }
        return "\(minutes / 60)h \(minutes % 60)m"
    }
}

enum Tuning {
    /// A write within this window means the agent is actively working.
    static let workingWindow: TimeInterval = 12
    /// A session backed by a live process lingers this long after its last
    /// activity (so you notice completion) before dropping.
    static let doneRetention: TimeInterval = 30 * 60
    /// A session whose process is gone (killed / CLI closed) is kept only this
    /// briefly. Actively-writing sessions always fall within this window, so a
    /// genuinely live session is never dropped even if process detection misses.
    static let killedRetention: TimeInterval = 2 * 60
    /// Session files untouched for longer than this are not scanned at all.
    static let scanWindow: TimeInterval = doneRetention + 5 * 60

    /// Whether a session should drop from the list this tick, given whether a
    /// live process backs it. Live: done shows for `doneRetention`. Not live
    /// (killed): anything shows for at most `killedRetention`.
    static func shouldDrop(state: SessionState, alive: Bool, age: TimeInterval) -> Bool {
        if !alive { return age > killedRetention }
        return state == .done && age > doneRetention
    }
}
