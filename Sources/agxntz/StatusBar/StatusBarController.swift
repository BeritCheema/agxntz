import AppKit
import SwiftUI
import Combine

@MainActor
final class StatusBarController: NSObject, NSPopoverDelegate {
    private let store: SessionStore
    private var aggregateItem: NSStatusItem?
    private var pinnedItems: [String: NSStatusItem] = [:]
    private var popover: NSPopover?
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
    }

    private func syncAggregate() {
        let hasSessions = !store.sessions.isEmpty
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
        }
        for session in pinned {
            if let item = pinnedItems[session.id] {
                swapHostedView(of: item, rootView: AnyView(PinnedItemView(session: session)))
            } else {
                let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
                configure(item: item, rootView: AnyView(PinnedItemView(session: session)))
                pinnedItems[session.id] = item
            }
        }
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
        togglePopover(from: sender)
    }

    private func togglePopover(from button: NSStatusBarButton) {
        if let popover, popover.isShown {
            popover.performClose(nil)
            self.popover = nil
            return
        }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
        popover.contentViewController = NSHostingController(rootView: DropdownView(store: store))
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        self.popover = popover
    }

    nonisolated func popoverDidClose(_ notification: Notification) {
        Task { @MainActor in self.popover = nil }
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

        let hooks = NSMenuItem(
            title: ClaudeHookInstaller.isInstalled ? "Claude Code Hooks Installed ✓" : "Install Claude Code Hooks…",
            action: ClaudeHookInstaller.isInstalled ? nil : #selector(installHooks),
            keyEquivalent: ""
        )
        hooks.target = self
        menu.addItem(hooks)
        menu.addItem(.separator())
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

    @objc private func installHooks() {
        do {
            try ClaudeHookInstaller.install()
        } catch {
            let alert = NSAlert()
            alert.messageText = "Could not install Claude Code hooks"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
