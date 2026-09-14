import Foundation
import Combine

/// User settings, persisted to UserDefaults and mirrored into `Tuning.config`
/// for the background scanners. Observed by the UI to react live.
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private let d = UserDefaults.standard

    // Appearance
    @Published var tickerSpeed: Double { didSet { save("tickerSpeed", tickerSpeed) } }
    @Published var tickerFontSize: Double { didSet { save("tickerFontSize", tickerFontSize) } }
    @Published var maxDots: Int { didSet { save("maxDots", maxDots); apply() } }

    // Behavior
    @Published var doneRetentionMinutes: Double { didSet { save("doneRetentionMin", doneRetentionMinutes); apply() } }
    @Published var killedRetentionMinutes: Double { didSet { save("killedRetentionMin", killedRetentionMinutes); apply() } }
    @Published var pollInterval: Double { didSet { save("pollInterval", pollInterval) } }

    // Agents (store disabled rawValues; default: all enabled)
    @Published var disabledAgents: Set<String> { didSet { d.set(Array(disabledAgents), forKey: "disabledAgents") } }

    private init() {
        tickerSpeed = (d.object(forKey: "tickerSpeed") as? Double) ?? 30
        tickerFontSize = (d.object(forKey: "tickerFontSize") as? Double) ?? 12
        maxDots = (d.object(forKey: "maxDots") as? Int) ?? 6
        doneRetentionMinutes = (d.object(forKey: "doneRetentionMin") as? Double) ?? 30
        killedRetentionMinutes = (d.object(forKey: "killedRetentionMin") as? Double) ?? 2
        pollInterval = (d.object(forKey: "pollInterval") as? Double) ?? 1
        disabledAgents = Set((d.array(forKey: "disabledAgents") as? [String]) ?? [])
        apply()
    }

    private func save(_ key: String, _ value: Any) { d.set(value, forKey: key) }

    /// Push the scan-relevant values into Tuning for the background threads.
    func apply() {
        Tuning.config.doneRetention = doneRetentionMinutes * 60
        Tuning.config.killedRetention = killedRetentionMinutes * 60
        Tuning.config.maxDots = max(1, min(6, maxDots))
    }

    func isEnabled(_ kind: AgentKind) -> Bool { !disabledAgents.contains(kind.rawValue) }

    func setEnabled(_ kind: AgentKind, _ enabled: Bool) {
        if enabled { disabledAgents.remove(kind.rawValue) }
        else { disabledAgents.insert(kind.rawValue) }
    }
}
