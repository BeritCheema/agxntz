import AppKit
import SwiftUI

/// A menu-style dropdown: flat rounded panel attached directly below the
/// menu-bar item (like a native NSMenu), instead of a floating popover
/// with an arrow.
@MainActor
final class DropdownPanel: NSPanel {
    private var hostingView: NSHostingView<DropdownView>?
    private var clickMonitors: [Any] = []
    private(set) weak var anchorButton: NSStatusBarButton?
    var onClose: (() -> Void)?
    /// Windows whose clicks should NOT auto-dismiss the panel (our own
    /// status items — their button actions handle toggling themselves).
    var ownedWindows: () -> [NSWindow] = { [] }

    init(store: SessionStore, onOpenSettings: @escaping () -> Void) {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .popUpMenu
        isMovable = false
        hidesOnDeactivate = false
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]

        let effect = NSVisualEffectView()
        effect.material = .menu
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 10
        effect.layer?.cornerCurve = .continuous
        effect.layer?.masksToBounds = true
        effect.layer?.borderWidth = 1
        effect.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.4).cgColor

        let host = NSHostingView(rootView: DropdownView(store: store, onOpenSettings: onOpenSettings))
        host.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            host.topAnchor.constraint(equalTo: effect.topAnchor),
            host.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
        contentView = effect
        hostingView = host
    }

    override var canBecomeKey: Bool { true }

    func show(below button: NSStatusBarButton) {
        anchorButton = button
        layoutBelowAnchor()
        makeKeyAndOrderFront(nil)
        installMonitors()
    }

    /// Re-anchor after content changes size (sessions appearing/disappearing
    /// while the panel is open).
    func layoutBelowAnchor() {
        guard let button = anchorButton,
              let buttonWindow = button.window,
              let hostingView else { return }

        let size = hostingView.fittingSize
        setContentSize(size)

        let buttonFrame = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        var x = buttonFrame.midX - size.width / 2
        // Align the panel's top with the top of the app-content area (just
        // below the menu bar) rather than the status button's own bottom,
        // which sits inside the taller bar and leaves a gap.
        var top = buttonFrame.minY
        if let screen = buttonWindow.screen ?? NSScreen.main {
            let visible = screen.visibleFrame
            top = visible.maxY
            x = min(max(x, visible.minX + 8), visible.maxX - size.width - 8)
        }
        setFrameOrigin(NSPoint(x: x, y: top - size.height))
    }

    private func installMonitors() {
        // Any click outside the panel dismisses it, like a menu.
        let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            // Global monitors fire on the main thread; assume isolation to call
            // dismiss() directly instead of a Task that captures self.
            MainActor.assumeIsolated { self?.dismiss() }
        }
        let local = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self else { return event }
            if event.window !== self, !self.ownedWindows().contains(where: { $0 === event.window }) {
                self.dismiss()
            }
            return event
        }
        clickMonitors = [global, local].compactMap { $0 }
    }

    func dismiss() {
        for monitor in clickMonitors { NSEvent.removeMonitor(monitor) }
        clickMonitors = []
        orderOut(nil)
        onClose?()
    }

    override func cancelOperation(_ sender: Any?) {
        dismiss() // Escape closes it
    }

}
