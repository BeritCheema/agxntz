import Foundation

enum AgentKind: String, CaseIterable, Codable {
    case claude = "Claude"
    case codex = "Codex"
    case grok = "Grok"
    case opencode = "OpenCode"
    case pi = "Pi"

    /// Executable basenames that indicate this agent is running.
    var processNames: [String] {
        switch self {
        case .claude: return ["claude"]
        case .codex: return ["codex"]
        case .grok: return ["grok"]
        case .opencode: return ["opencode"]
        case .pi: return ["pi"]
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
    /// Done sessions disappear this long after their last activity.
    static let doneRetention: TimeInterval = 30 * 60
    /// Session files untouched for longer than this are not scanned at all.
    static let scanWindow: TimeInterval = doneRetention + 5 * 60
}
