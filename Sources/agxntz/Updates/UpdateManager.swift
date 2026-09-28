import AppKit
import Combine
import Sparkle

/// Owns Sparkle. The update feed (appcast.xml) and the update archive both come
/// straight from the GitHub release — see SUFeedURL in Info.plist.
///
/// Sparkle does the checking, downloading, EdDSA/code-signature verification,
/// installing and relaunching; the UI is ours and deliberately minimal (see
/// MinimalUserDriver). One prompt: "A new version of agxntz is available —
/// 0.1.0 → 0.2.0" with Update / Later. A background check never interrupts: it
/// sets `pendingVersion`, which shows a row in the dropdown and right-click
/// menu, and clicking that brings up the prompt.
@MainActor
final class UpdateManager: NSObject, ObservableObject {
    static let shared = UpdateManager()

    /// Version of an available update awaiting the user's answer.
    @Published private(set) var pendingVersion: String?
    /// True while an accepted update downloads and installs.
    @Published private(set) var isInstalling = false

    private var updater: SPUUpdater?
    private let driver = MinimalUserDriver()
    /// Sparkle's pending "install or not?" callback for `pendingVersion`.
    private var pendingReply: ((SPUUserUpdateChoice) -> Void)?
    /// A check the user started (so "up to date" / errors get reported).
    private var userInitiated = false

    /// False for local dev builds (not a stamped release).
    var isEnabled: Bool { updater != nil }

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    /// Whether this build should run the updater: a real release bundle (has a
    /// feed URL and a stamped version), or forced on for testing.
    static var shouldRun: Bool {
        if ProcessInfo.processInfo.environment["AGXNTZ_FORCE_UPDATER"] == "1" { return true }
        let hasFeed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil
        return hasFeed && currentVersion != "dev"
    }

    func start() {
        guard updater == nil, Self.shouldRun else {
            Log.d("updater: disabled for this build (version \(Self.currentVersion))")
            return
        }
        let u = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: driver, delegate: self)
        do {
            try u.start()
        } catch {
            Log.d("updater: failed to start: \(error.localizedDescription)")
            return
        }
        // Daily update checks are always on — not a user preference. Sparkle
        // persists this in user defaults, so re-assert it every launch to
        // override any value stored by an earlier build.
        u.automaticallyChecksForUpdates = true
        updater = u
        Log.d("updater: started, daily checks on")
        // Test hook: run a user-initiated check right away.
        if ProcessInfo.processInfo.environment["AGXNTZ_CHECK_NOW"] == "1" { checkForUpdates() }
    }

    /// "Check for Updates…" / the update row: if an update is already waiting,
    /// ask about it; otherwise check now and report the result.
    func checkForUpdates() {
        guard let updater, !isInstalling else { return }
        if pendingReply != nil {
            promptForPending()
        } else {
            userInitiated = true
            updater.checkForUpdates()
        }
    }

    // MARK: Driven by MinimalUserDriver (always on the main thread)

    fileprivate func updateFound(version: String, userInitiated: Bool, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        Log.d("updater: found \(version) (\(userInitiated ? "user check" : "background"))")
        pendingVersion = version
        pendingReply = reply
        if userInitiated { promptForPending() }   // background: just surface the row
    }

    fileprivate func downloadStarted() { isInstalling = true }

    fileprivate func updateNotFound() {
        if userInitiated {
            alert(title: "agxntz is up to date", detail: "Version \(Self.currentVersion)")
        }
        reset()
    }

    fileprivate func updateFailed(_ error: Error) {
        Log.d("updater: error: \(error.localizedDescription)")
        if userInitiated || isInstalling {
            alert(title: "Couldn't update agxntz", detail: error.localizedDescription)
        }
        reset()
    }

    fileprivate func reset() {
        pendingVersion = nil
        pendingReply = nil
        isInstalling = false
        userInitiated = false
    }

    // MARK: UI

    private func promptForPending() {
        guard let reply = pendingReply, let version = pendingVersion else { return }
        pendingReply = nil
        let alert = NSAlert()
        alert.messageText = "A new version of agxntz is available"
        alert.informativeText = "\(Self.currentVersion) → \(version)"
        alert.addButton(withTitle: "Update")
        alert.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)   // menu-bar app: bring the alert forward
        let response = alert.runModal()
        Log.d("updater: prompt answered \(response == .alertFirstButtonReturn ? "Update" : "Later")")
        if response == .alertFirstButtonReturn {
            isInstalling = true
            reply(.install)
        } else {
            pendingVersion = nil
            reply(.dismiss)                        // offered again at the next check
        }
    }

    private func alert(title: String, detail: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}

extension UpdateManager: SPUUpdaterDelegate {
    /// Test hook: AGXNTZ_FEED_URL points the updater at a local appcast. Releases
    /// use SUFeedURL (the GitHub release's appcast.xml).
    nonisolated func feedURLString(for updater: SPUUpdater) -> String? {
        ProcessInfo.processInfo.environment["AGXNTZ_FEED_URL"]
    }
}

/// Sparkle's non-Sendable callbacks, carried across the isolation boundary.
/// Sparkle invokes the user driver on the main thread and they're only ever
/// used there.
private struct MainThreadBox<T>: @unchecked Sendable { let value: T }

/// Sparkle user driver with the smallest possible UI: one Update / Later
/// prompt, silent download + install + relaunch, and an alert only for
/// user-initiated "up to date" results or failures. Release notes, progress
/// windows, "skip this version" and the auto-install checkbox are omitted.
///
/// The protocol is nonisolated Objective-C, but Sparkle calls it on the main
/// thread, so each method hops into main-actor isolation explicitly.
private final class MinimalUserDriver: NSObject, SPUUserDriver {
    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        // Automatic checks are on by default (SUEnableAutomaticChecks); never ask.
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: true, sendSystemProfile: false))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {}

    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState,
                         reply: @escaping (SPUUserUpdateChoice) -> Void) {
        let version = appcastItem.displayVersionString
        let userInitiated = state.userInitiated
        let box = MainThreadBox(value: reply)
        MainActor.assumeIsolated {
            UpdateManager.shared.updateFound(version: version, userInitiated: userInitiated, reply: box.value)
        }
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {}

    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        MainActor.assumeIsolated { UpdateManager.shared.updateNotFound() }
        acknowledgement()
    }

    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        let box = MainThreadBox(value: error)
        MainActor.assumeIsolated { UpdateManager.shared.updateFailed(box.value) }
        acknowledgement()
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        MainActor.assumeIsolated { UpdateManager.shared.downloadStarted() }
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {}
    func showDownloadDidReceiveData(ofLength length: UInt64) {}
    func showDownloadDidStartExtractingUpdate() {}
    func showExtractionReceivedProgress(_ progress: Double) {}

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        reply(.install)   // the user already said Update
    }

    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool,
                              retryTerminatingApplication: @escaping () -> Void) {}

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        acknowledgement()
    }

    func dismissUpdateInstallation() {
        MainActor.assumeIsolated { UpdateManager.shared.reset() }
    }
}
