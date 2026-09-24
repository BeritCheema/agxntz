import AppKit
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

    // State colors as "#RRGGBB"; nil means the system default for that state.
    @Published var workingColorHex: String? { didSet { saveOptional("workingColor", workingColorHex); apply() } }
    @Published var waitingColorHex: String? { didSet { saveOptional("waitingColor", waitingColorHex); apply() } }
    @Published var doneColorHex: String? { didSet { saveOptional("doneColor", doneColorHex); apply() } }

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
        workingColorHex = d.string(forKey: "workingColor")
        waitingColorHex = d.string(forKey: "waitingColor")
        doneColorHex = d.string(forKey: "doneColor")
        doneRetentionMinutes = (d.object(forKey: "doneRetentionMin") as? Double) ?? 30
        killedRetentionMinutes = (d.object(forKey: "killedRetentionMin") as? Double) ?? 2
        pollInterval = (d.object(forKey: "pollInterval") as? Double) ?? 1
        disabledAgents = Set((d.array(forKey: "disabledAgents") as? [String]) ?? [])
        apply()
    }

    private func save(_ key: String, _ value: Any) { d.set(value, forKey: key) }
    private func saveOptional(_ key: String, _ value: String?) {
        if let value { d.set(value, forKey: key) } else { d.removeObject(forKey: key) }
    }

    /// Restore all three state colors to the system defaults.
    func resetStateColors() {
        workingColorHex = nil
        waitingColorHex = nil
        doneColorHex = nil
    }

    /// Push the scan-relevant values into Tuning for the background threads.
    func apply() {
        Tuning.config.doneRetention = doneRetentionMinutes * 60
        Tuning.config.killedRetention = killedRetentionMinutes * 60
        Tuning.config.maxDots = max(1, maxDots)
        Palette.working = workingColorHex.flatMap(NSColor.init(hex:)) ?? Palette.defaultWorking
        Palette.waiting = waitingColorHex.flatMap(NSColor.init(hex:)) ?? Palette.defaultWaiting
        Palette.done = doneColorHex.flatMap(NSColor.init(hex:)) ?? Palette.defaultDone
    }

    func isEnabled(_ kind: AgentKind) -> Bool { !disabledAgents.contains(kind.rawValue) }

    func setEnabled(_ kind: AgentKind, _ enabled: Bool) {
        if enabled { disabledAgents.remove(kind.rawValue) }
        else { disabledAgents.insert(kind.rawValue) }
    }
}

/// The live state colors, mirrored from AppSettings so any renderer (menu-bar
/// images, SwiftUI rows) reads them without touching the main-actor settings.
enum Palette {
    static let defaultWorking = NSColor.systemGreen
    static let defaultWaiting = NSColor.systemOrange
    static let defaultDone = NSColor.systemBlue

    nonisolated(unsafe) static var working: NSColor = defaultWorking
    nonisolated(unsafe) static var waiting: NSColor = defaultWaiting
    nonisolated(unsafe) static var done: NSColor = defaultDone
}

extension NSColor {
    /// "#RRGGBB" (leading # optional) in sRGB.
    convenience init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(srgbRed: CGFloat((v >> 16) & 0xFF) / 255,
                  green: CGFloat((v >> 8) & 0xFF) / 255,
                  blue: CGFloat(v & 0xFF) / 255,
                  alpha: 1)
    }

    /// "#RRGGBB" in sRGB, or nil if the color can't be converted.
    var hexString: String? {
        guard let c = usingColorSpace(.sRGB) else { return nil }
        func byte(_ x: CGFloat) -> Int { Int((max(0, min(1, x)) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(c.redComponent), byte(c.greenComponent), byte(c.blueComponent))
    }
}
