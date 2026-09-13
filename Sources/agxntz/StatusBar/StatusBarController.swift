import AppKit
import SwiftUI
import Combine

@MainActor
final class StatusBarController: NSObject {
    private let store: SessionStore
    private var aggregateItem: NSStatusItem?
    private var pinnedItems: [String: NSStatusItem] = [:]
    private var pinnedRendered: [String: AgentSession] = [:]  // last session rendered per pin
    private var panel: DropdownPanel?
    private var cancellables = Set<AnyCancellable>()

    init(store: SessionStore) {
        self.store = store
        super.init()
        store.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.sync() }
            }
            .store(in: &cancellables)
        sync()
    }

    // MARK: - Sync menu-bar presence with store state

    private func sync() {
        syncAggregate()
        syncPinned()
        panel?.layoutBelowAnchor()
    }

    private func syncAggregate() {
        let hasSessions = store.hasUnpinnedSessions
        if hasSessions {
            if aggregateItem == nil {
                let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
                configure(item: item, rootView: AnyView(CounterView(store: store)))
                aggregateItem = item
            }
        } else if let item = aggregateItem {
            // No relevant agents: no menu-bar presence at all.
            NSStatusBar.system.removeStatusItem(item)
            aggregateItem = nil
        }
    }

    private func syncPinned() {
        let pinned = store.pinnedSessions
        let wanted = Set(pinned.map(\.id))

        for (id, item) in pinnedItems where !wanted.contains(id) {
            NSStatusBar.system.removeStatusItem(item)
            pinnedItems.removeValue(forKey: id)
            pinnedRendered.removeValue(forKey: id)
        }
        for session in pinned {
            if let item = pinnedItems[session.id] {
                // Only rebuild the hosted view when what the pinned item
                // *shows* changed (state, activity, message). Ignoring e.g.
                // lastActivityAt ticks keeps the SwiftUI subtree — and its
                // scrolling ticker — alive and smooth across polls.
                if !Self.sameDisplay(pinnedRendered[session.id], session) {
                    swapHostedView(of: item, rootView: AnyView(PinnedItemView(session: session)))
                    pinnedRendered[session.id] = session
                }
            } else {
                let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
                configure(item: item, rootView: AnyView(PinnedItemView(session: session)))
                pinnedItems[session.id] = item
                pinnedRendered[session.id] = session
            }
        }
    }

    /// Whether two sessions render identically as a pinned menu-bar item.
    private static func sameDisplay(_ a: AgentSession?, _ b: AgentSession) -> Bool {
        guard let a else { return false }
        return a.state == b.state && a.activity == b.activity && a.lastMessage == b.lastMessage
    }

    private func configure(item: NSStatusItem, rootView: AnyView) {
        guard let button = item.button else { return }
        swapHostedView(of: item, rootView: rootView)
        button.target = self
        button.action = #selector(itemClicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    private func swapHostedView(of item: NSStatusItem, rootView: AnyView) {
        guard let button = item.button else { return }
        if let host = button.subviews.compactMap({ $0 as? NSHostingView<AnyView> }).first {
            host.rootView = rootView
            return
        }
        let host = NSHostingView(rootView: rootView)
        host.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: button.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: button.trailingAnchor),
            host.topAnchor.constraint(equalTo: button.topAnchor),
            host.bottomAnchor.constraint(equalTo: button.bottomAnchor),
        ])
    }

    // MARK: - Interaction

    @objc private func itemClicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showContextMenu(for: sender)
            return
        }
        togglePanel(from: sender)
    }

    private func togglePanel(from button: NSStatusBarButton) {
        if let panel {
            let sameAnchor = panel.anchorButton === button
            panel.dismiss()
            if sameAnchor { return } // plain toggle-off
        }
        let panel = DropdownPanel(store: store)
        panel.onClose = { [weak self] in self?.panel = nil }
        panel.ownedWindows = { [weak self] in
            guard let self else { return [] }
            var windows: [NSWindow] = []
            if let w = self.aggregateItem?.button?.window { windows.append(w) }
            for item in self.pinnedItems.values {
                if let w = item.button?.window { windows.append(w) }
            }
            return windows
        }
        panel.show(below: button)
        self.panel = panel
    }

    private func showContextMenu(for button: NSStatusBarButton) {
        let menu = NSMenu()

        if let pinnedID = pinnedItems.first(where: { $0.value.button === button })?.key {
            let unpin = NSMenuItem(title: "Unpin", action: #selector(unpinClicked(_:)), keyEquivalent: "")
            unpin.target = self
            unpin.representedObject = pinnedID
            menu.addItem(unpin)
            menu.addItem(.separator())
        }

        let quit = NSMenuItem(title: "Quit agxntz", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        // Deprecated-but-reliable way to pop a menu from a status item
        // without permanently hijacking left-click.
        button.menu = menu
        button.performClick(nil)
        button.menu = nil
    }

    @objc private func unpinClicked(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String {
            store.togglePin(id)
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
