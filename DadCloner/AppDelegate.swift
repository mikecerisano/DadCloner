import SwiftUI
import AppKit
import UserNotifications

/// Main app delegate handling menu bar setup and lifecycle
class AppDelegate: NSObject, NSApplicationDelegate {

    // MARK: - Properties
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var setupWindow: NSWindow?

    private let config = SyncConfiguration.shared
    private let driveMonitor = DriveMonitor.shared
    private let syncManager = SyncManager.shared
    private let scheduler = SchedulerManager.shared

    // MARK: - App Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Request notification permissions
        requestNotificationPermissions()

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
    }

    func applicationWillTerminate(_ notification: Notification) {
        scheduler.stop()
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

        let status = calculateStatus()

        // Use SF Symbols for the icon
        let configuration = NSImage.SymbolConfiguration(pointSize: 16, weight: .medium)

        switch status {
        case .ready:
            button.image = NSImage(systemSymbolName: "externaldrive.fill.badge.checkmark", accessibilityDescription: "DadCloner - Ready")?
                .withSymbolConfiguration(configuration)
            button.contentTintColor = .systemGreen

        case .warning:
            button.image = NSImage(systemSymbolName: "externaldrive.fill.badge.exclamationmark", accessibilityDescription: "DadCloner - Warning")?
                .withSymbolConfiguration(configuration)
            button.contentTintColor = .systemOrange

        case .syncing:
            button.image = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: "DadCloner - Syncing")?
                .withSymbolConfiguration(configuration)
            button.contentTintColor = .systemGray

        case .error:
            button.image = NSImage(systemSymbolName: "externaldrive.fill.badge.xmark", accessibilityDescription: "DadCloner - Error")?
                .withSymbolConfiguration(configuration)
            button.contentTintColor = .systemRed
        }
    }

    private func calculateStatus() -> MenuBarStatus {
        if syncManager.status.isRunning {
            return .syncing
        }

        if !config.isConfigured {
            return .warning
        }

        let sourceValid = driveMonitor.validateSourceDrive().isValid
        let backupValid = driveMonitor.validateBackupDrive().isValid

        if !sourceValid || !backupValid {
            return .error
        }

        if config.isBackupOverdue {
            return .warning
        }

        if !config.lastSyncSuccess && config.lastSyncDate != nil {
            return .warning
        }

        return .ready
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

    func showSetupWindow() {
        if setupWindow == nil {
            let setupView = SetupView()
            let hostingController = NSHostingController(rootView: setupView)

            setupWindow = NSWindow(contentViewController: hostingController)
            setupWindow?.title = "DadCloner Setup"
            setupWindow?.styleMask = [.titled, .closable]
            setupWindow?.setContentSize(NSSize(width: 500, height: 450))
            setupWindow?.center()

            // Handle window closing
            setupWindow?.delegate = self
        }

        setupWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Drive Monitoring

    private func startDriveMonitoring() {
        // Update status icon when drives change
        Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            self?.driveMonitor.refreshMountedVolumes()
            self?.updateStatusIcon()
        }
    }

    // MARK: - Notifications

    private func requestNotificationPermissions() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error = error {
                print("Notification permission error: \(error)")
            }
        }
    }
}

// MARK: - Window Delegate

extension AppDelegate: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        if let window = notification.object as? NSWindow, window == setupWindow {
            // Check if setup was completed
            if !config.isConfigured {
                // User closed setup without completing - show warning
                let alert = NSAlert()
                alert.messageText = "Setup Incomplete"
                alert.informativeText = "DadCloner needs to be set up before it can back up your files. You can access setup again from the menu bar icon."
                alert.alertStyle = .warning
                alert.addButton(withTitle: "OK")
                alert.runModal()
            }
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if sender == setupWindow && !config.isConfigured {
            // Allow closing but warn
            return true
        }
        return true
    }
}
