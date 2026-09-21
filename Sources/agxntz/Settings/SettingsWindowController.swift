import AppKit
import SwiftUI

/// Owns the Settings window (a normal app window, unlike the transient
/// dropdown panel).
@MainActor
final class SettingsWindowController {
    private var window: NSWindow?
    private let store: SessionStore

    init(store: SessionStore) { self.store = store }

    func show() {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let hosting = NSHostingController(rootView: SettingsView(store: store))
        let win = NSWindow(contentViewController: hosting)
        win.title = "agxntz Settings"
        win.styleMask = [.titled, .closable, .miniaturizable]
        win.isReleasedWhenClosed = false
        win.center()
        window = win
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
    }
}
