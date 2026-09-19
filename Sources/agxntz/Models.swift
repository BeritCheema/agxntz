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

/// One menu-bar aggregate element: either up to 6 individual agent dots
/// (colored by state, ordered working→waiting→done) or, for a single state
/// with more than 6 agents, a "● N" count.
enum AggregateElement: Equatable {
    case dots([SessionState])
    case number(SessionState, Int)
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
    /// User-tunable values (mirrored from AppSettings). Read from background
    /// scan threads, so kept as a plain value updated on the main thread;
    /// a slightly stale read between ticks is harmless.
    struct Config {
        var doneRetention: TimeInterval = 30 * 60
        var killedRetention: TimeInterval = 2 * 60
        var maxDots: Int = 6
    }
    nonisolated(unsafe) static var config = Config()

    /// A write within this window means the agent is actively working.
    static let workingWindow: TimeInterval = 12

    /// Brief grace after a tool call is written before its run/wait state is
    /// judged by process signal — covers the moment between the tool_use record
    /// and the command shell actually spawning, so a real run doesn't flash
    /// orange for a tick. Short, so a genuine permission prompt turns orange fast.
    static let toolStartGrace: TimeInterval = 5
    static var doneRetention: TimeInterval { config.doneRetention }
    static var killedRetention: TimeInterval { config.killedRetention }
    /// Session files untouched for longer than this are not scanned at all.
    static var scanWindow: TimeInterval { config.doneRetention + 5 * 60 }

    /// Whether a session should drop from the list this tick, given whether a
    /// live process backs it. Live: done shows for `doneRetention`. Not live
    /// (killed): anything shows for at most `killedRetention`.
    static func shouldDrop(state: SessionState, alive: Bool, age: TimeInterval) -> Bool {
        if !alive { return age > killedRetention }
        return state == .done && age > doneRetention
    }
}
