import SwiftUI
import AppKit
import UserNotifications
import Sparkle

/// Main app delegate handling menu bar setup and lifecycle
@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {

    // MARK: - Properties
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var setupWindow: NSWindow?
    private var statusTimer: Timer?
    private var notificationObservers: [NSObjectProtocol] = []
    private var updaterController: SPUStandardUpdaterController?

    private let config = SyncConfiguration.shared
    private let driveMonitor = DriveMonitor.shared
    private let syncManager = SyncManager.shared
    private let scheduler = SchedulerManager.shared

    // MARK: - App Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: nil
        )

        // Setup menu bar
        setupMenuBar()

        // Check if first run
        if !config.isConfigured {
            showSetupWindow()
        } else {
            // Start scheduler
            scheduler.start()
        }

        // Start monitoring drive changes
        startDriveMonitoring()
        observeAppStatusChanges()
    }

    /// Quitting mid-backup would leave rsync running on its own, so ask
    /// first and stop it cleanly.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard syncManager.status.isRunning else { return .terminateNow }

        let alert = NSAlert()
        alert.messageText = "A backup is in progress"
        alert.informativeText = "If you quit now, the backup stops and will finish next time. Nothing already backed up is lost."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Keep Backing Up")
        alert.addButton(withTitle: "Stop Backup and Quit")
        NSApp.activate(ignoringOtherApps: true)

        guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }

        // The sync may have finished while the alert was up.
        guard syncManager.status.isRunning else { return .terminateNow }

        syncManager.whenIdle {
            // Reply on a later turn, after .terminateLater has been returned.
            DispatchQueue.main.async {
                NSApp.reply(toApplicationShouldTerminate: true)
            }
        }
        syncManager.cancelRunningSync()
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        scheduler.stop()
        statusTimer?.invalidate()
        for observer in notificationObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Menu Bar Setup

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem?.button {
            updateStatusIcon()
            button.action = #selector(togglePopover)
            button.target = self
        }

        // Create popover
        popover = NSPopover()
        popover?.contentSize = NSSize(width: 300, height: 350)
        popover?.behavior = .transient
        popover?.contentViewController = NSHostingController(rootView: MenuBarPopover())
    }

    private func updateStatusIcon() {
        guard let button = statusItem?.button else { return }

        let status = MenuBarStatus.current()
        let configuration = NSImage.SymbolConfiguration(pointSize: 16, weight: .medium)

        button.image = NSImage(
            systemSymbolName: status.iconName,
            accessibilityDescription: "DadCloner - \(status.accessibilityLabel)"
        )?.withSymbolConfiguration(configuration)
        button.contentTintColor = status.nsColor
    }

    @objc private func togglePopover() {
        guard let button = statusItem?.button, let popover = popover else { return }

        if popover.isShown {
            popover.performClose(nil)
        } else {
            // Refresh drive status before showing
            driveMonitor.refreshMountedVolumes()

            // Update the popover content
            popover.contentViewController = NSHostingController(rootView: MenuBarPopover())

            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)

            // Make the popover the key window
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    // MARK: - Setup Window

    /// Shows the setup wizard. A fresh window and view are built each time,
    /// so re-running setup (Change Drives) starts from the beginning.
    func showSetupWindow() {
        if setupWindow == nil {
            let setupView = SetupView(onFinish: { [weak self] in
                self?.setupWindow?.close()
            })
            let hostingController = NSHostingController(rootView: setupView)

            let window = NSWindow(contentViewController: hostingController)
            window.title = "DadCloner Setup"
            window.styleMask = [.titled, .closable]
            window.setContentSize(NSSize(width: 500, height: 450))
            // We hold the only strong reference; don't let AppKit release it too.
            window.isReleasedWhenClosed = false
            window.center()
            window.delegate = self
            setupWindow = window
        }

        setupWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Manual update check, triggered from Settings
    func checkForUpdates() {
        updaterController?.checkForUpdates(nil)
    }

    // MARK: - Drive Monitoring

    private func startDriveMonitoring() {
        // Refreshing posts dadClonerDriveStatusDidChange, which updates the icon.
        statusTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.driveMonitor.refreshMountedVolumes()
            }
        }
    }

    private func observeAppStatusChanges() {
        for name in [Notification.Name.dadClonerSyncStatusDidChange, .dadClonerDriveStatusDidChange] {
            let observer = NotificationCenter.default.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.updateStatusIcon()
                }
            }
            notificationObservers.append(observer)
        }
    }
}

// MARK: - Window Delegate

extension AppDelegate: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window == setupWindow else { return }

        if !config.isConfigured {
            // User closed setup without completing - show warning
            let alert = NSAlert()
            alert.messageText = "Setup Incomplete"
            alert.informativeText = "DadCloner needs to be set up before it can back up your files. You can access setup again from the menu bar icon."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }

        setupWindow = nil
    }
}

// MARK: - Sparkle

extension AppDelegate: SPUUpdaterDelegate {
    /// Don't relaunch into a new version in the middle of a backup;
    /// install as soon as the current sync finishes.
    nonisolated func updater(
        _ updater: SPUUpdater,
        shouldPostponeRelaunchForUpdate item: SUAppcastItem,
        untilInvokingBlock installHandler: @escaping () -> Void
    ) -> Bool {
        MainActor.assumeIsolated {
            guard SyncManager.shared.status.isRunning else { return false }
            SyncLogger.shared.info("Update ready; installing after the current backup finishes")
            SyncManager.shared.whenIdle(installHandler)
            return true
        }
    }
}
