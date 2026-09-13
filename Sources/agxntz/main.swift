import AppKit
import Foundation

let arguments = CommandLine.arguments

Log.enabled = arguments.contains("--debug")
    || arguments.contains("--scan")
    || ProcessInfo.processInfo.environment["AGXNTZ_DEBUG"] == "1"

// Debug mode: one detection pass, printed to stdout.
if arguments.contains("--scan") {
    let now = Date()
    let processes = ProcessSnapshot.capture()
    let providers: [AgentProvider] = [
        ClaudeCodeProvider(), CodexProvider(), OpenCodeProvider(), GrokProvider(),
        PiFamilyProvider.pi(), PiFamilyProvider.omp(),
    ]
    for provider in providers {
        for s in provider.scan(now: now, processes: processes) {
            print("[\(s.kind.rawValue)] \(s.projectName) — \(s.state) — \(s.activity) — started \(s.elapsedText) ago — id \(s.id) — \(s.debugInfo ?? "")")
            for sub in s.subAgents {
                print("    ↳ \(sub.projectName) — \(sub.state) — \(sub.activity) — \(sub.elapsedText) — id \(sub.id)")
            }
        }
    }
    exit(0)
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var store: SessionStore!
    private var statusBar: StatusBarController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.d("agxntz launched (pid \(ProcessInfo.processInfo.processIdentifier)), debug logging on")
        store = SessionStore()
        statusBar = StatusBarController(store: store)
        store.start()
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory) // menu-bar only, no Dock icon
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
