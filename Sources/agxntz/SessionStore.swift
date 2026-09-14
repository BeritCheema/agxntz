import Foundation
import Combine

@MainActor
final class SessionStore: ObservableObject {
    @Published private(set) var sessions: [AgentSession] = []
    @Published private(set) var pinnedIDs: [String] = []

    private let providers: [AgentProvider] = [
        ClaudeCodeProvider(),
        CodexProvider(),
        OpenCodeProvider(),
        GrokProvider(),
        PiFamilyProvider.pi(),
        PiFamilyProvider.omp(),
    ]
    private var timer: Timer?
    private let pinsKey = "agxntz.pinnedSessionIDs"
    // Stable display order: first-seen index per session id. Rows are grouped
    // by state but keep their position within a group, so an agent only moves
    // when its state changes — never merely because its activity time ticked.
    private var orderIndex: [String: Int] = [:]
    private var orderCounter = 0

    init() {
        pinnedIDs = UserDefaults.standard.stringArray(forKey: pinsKey) ?? []
    }

    func start() {
        refresh()
        restartTimer()
    }

    /// (Re)create the poll timer using the current interval setting.
    func restartTimer() {
        timer?.invalidate()
        let interval = max(0.25, AppSettings.shared.pollInterval)
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        t.tolerance = min(0.5, interval / 2)
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func refresh() {
        let providers = self.providers
        let disabled = AppSettings.shared.disabledAgents   // snapshot on main
        Task.detached(priority: .utility) {
            let now = Date()
            let processes = ProcessSnapshot.capture()
            var collected: [AgentSession] = []
            for provider in providers where !disabled.contains(provider.kind.rawValue) {
                collected.append(contentsOf: provider.scan(now: now, processes: processes))
            }
            let scanned = collected
            await MainActor.run { [weak self] in
                guard let self else { return }
                let result = self.stableSorted(scanned)
                if result != self.sessions {
                    self.logTransitions(from: self.sessions, to: result)
                    self.sessions = result
                }
                // Drop pins whose sessions no longer exist (sub-agents too).
                let live = Set(result.flatMap { [$0.id] + $0.subAgents.map(\.id) })
                let kept = self.pinnedIDs.filter(live.contains)
                if kept != self.pinnedIDs { self.setPins(kept) }
            }
        }
    }

    /// Group by state, keeping each session's position within its group stable
    /// (by first-seen order). New sessions get the next index and append to the
    /// end of their group. A session changing state moves groups but keeps its
    /// index, so ordering never churns from activity-time changes alone.
    private func stableSorted(_ scanned: [AgentSession]) -> [AgentSession] {
        for s in scanned where orderIndex[s.id] == nil {
            orderIndex[s.id] = orderCounter
            orderCounter += 1
        }
        let liveIDs = Set(scanned.map(\.id))
        orderIndex = orderIndex.filter { liveIDs.contains($0.key) }
        return scanned.sorted { a, b in
            a.state != b.state ? a.state < b.state
                : (orderIndex[a.id] ?? 0) < (orderIndex[b.id] ?? 0)
        }
    }

    func sessions(in state: SessionState) -> [AgentSession] {
        sessions.filter { $0.state == state }
    }

    /// Aggregate counters exclude pinned sessions — those already have their
    /// own menu-bar item, and counting them twice reads as duplication.
    func unpinnedCount(of state: SessionState) -> Int {
        sessions.lazy.filter { $0.state == state && !self.pinnedIDs.contains($0.id) }.count
    }

    var hasUnpinnedSessions: Bool {
        sessions.contains { !pinnedIDs.contains($0.id) }
    }

    /// Aggregate (unpinned) agents packed into menu-bar elements: one element
    /// of up to 6 dots; when more than 6 agents, the largest state group peels
    /// off into its own element; a single state over 6 becomes a "● N" count.
    var aggregateElements: [AggregateElement] {
        let pinned = Set(pinnedIDs)
        var counts: [SessionState: Int] = [:]
        for session in sessions where !pinned.contains(session.id) {
            counts[session.state, default: 0] += 1
        }

        let cap = Tuning.config.maxDots
        var elements: [AggregateElement] = []
        var remaining: [(SessionState, Int)] = []      // groups of ≤cap, in state order
        for state in [SessionState.working, .waiting, .done] {
            guard let c = counts[state], c > 0 else { continue }
            if c > cap { elements.append(.number(state, c)) }
            else { remaining.append((state, c)) }
        }

        while !remaining.isEmpty {
            let total = remaining.reduce(0) { $0 + $1.1 }
            if total <= cap {
                var dots: [SessionState] = []
                for (state, c) in remaining { dots += Array(repeating: state, count: c) }
                elements.append(.dots(dots))
                remaining.removeAll()
            } else {
                // Split off the state with the most agents into its own element.
                let idx = remaining.indices.max { remaining[$0].1 < remaining[$1].1 }!
                let (state, c) = remaining.remove(at: idx)
                elements.append(.dots(Array(repeating: state, count: c)))
            }
        }
        return elements
    }

    /// Every monitorable entity: main sessions plus their sub-agents. Used so
    /// a sub-agent can be pinned and resolved just like a main session.
    var allMonitorable: [AgentSession] {
        sessions + sessions.flatMap(\.subAgents)
    }

    var pinnedSessions: [AgentSession] {
        let all = allMonitorable
        return pinnedIDs.compactMap { id in all.first { $0.id == id } }
    }

    func isPinned(_ id: String) -> Bool { pinnedIDs.contains(id) }

    func togglePin(_ id: String) {
        var pins = pinnedIDs
        if let index = pins.firstIndex(of: id) {
            pins.remove(at: index)
        } else {
            pins.append(id)
        }
        setPins(pins)
    }

    private func logTransitions(from old: [AgentSession], to new: [AgentSession]) {
        guard Log.enabled else { return }
        let oldByID = Dictionary(uniqueKeysWithValues: old.map { ($0.id, $0) })
        let newIDs = Set(new.map(\.id))
        for session in new {
            let previous = oldByID[session.id]
            if previous == nil {
                Log.d("+ \(session.id) [\(session.projectName)] \(session.state) '\(session.activity)' (\(session.debugInfo ?? "-"))")
            } else if previous?.state != session.state || previous?.activity != session.activity {
                Log.d("~ \(session.id) [\(session.projectName)] \(previous!.state)->\(session.state) '\(session.activity)' (\(session.debugInfo ?? "-"))")
            }
        }
        for session in old where !newIDs.contains(session.id) {
            Log.d("- \(session.id) [\(session.projectName)] removed (was \(session.state))")
        }
    }

    private func setPins(_ pins: [String]) {
        pinnedIDs = pins
        UserDefaults.standard.set(pins, forKey: pinsKey)
    }
}
