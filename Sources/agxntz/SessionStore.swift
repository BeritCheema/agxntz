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
        PiProvider(),
    ]
    private var timer: Timer?
    private let pinsKey = "agxntz.pinnedSessionIDs"

    init() {
        pinnedIDs = UserDefaults.standard.stringArray(forKey: pinsKey) ?? []
    }

    func start(interval: TimeInterval = 2.0) {
        refresh()
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        t.tolerance = 0.5
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func refresh() {
        let providers = self.providers
        Task.detached(priority: .utility) {
            let now = Date()
            let processes = ProcessSnapshot.capture()
            var collected: [AgentSession] = []
            for provider in providers {
                collected.append(contentsOf: provider.scan(now: now, processes: processes))
            }
            collected.sort { a, b in
                a.state == b.state ? a.lastActivityAt > b.lastActivityAt : a.state < b.state
            }
            let result = collected
            await MainActor.run { [weak self] in
                guard let self else { return }
                if result != self.sessions { self.sessions = result }
                // Drop pins whose sessions no longer exist.
                let live = Set(result.map(\.id))
                let kept = self.pinnedIDs.filter(live.contains)
                if kept != self.pinnedIDs { self.setPins(kept) }
            }
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

    var pinnedSessions: [AgentSession] {
        pinnedIDs.compactMap { id in sessions.first { $0.id == id } }
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

    private func setPins(_ pins: [String]) {
        pinnedIDs = pins
        UserDefaults.standard.set(pins, forKey: pinsKey)
    }
}
