import Foundation
import ServiceManagement

/// Manages the app's launch at login setting
@Observable
final class LaunchAtLogin {

    // MARK: - Singleton
    static let shared = LaunchAtLogin()

    // MARK: - Properties

    /// Last known registration status. Stored (not read through to
    /// SMAppService on every access) so SwiftUI sees changes.
    private(set) var status: SMAppService.Status = SMAppService.mainApp.status

    /// Whether the app is set to launch at login
    var isEnabled: Bool {
        get { status == .enabled }
        set { setLaunchAtLogin(enabled: newValue) }
    }

    /// macOS needs the user to allow the login item in System Settings.
    var requiresApproval: Bool {
        status == .requiresApproval
    }

    // MARK: - Initialization

    private init() {}

    // MARK: - Methods

    /// Re-read the status (the user may have changed it in System Settings).
    func refresh() {
        status = SMAppService.mainApp.status
    }

    /// Enable or disable launch at login
    func setLaunchAtLogin(enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            SyncLogger.shared.warning(
                "Could not \(enabled ? "turn on" : "turn off") Start at Login",
                details: error.localizedDescription
            )
        }
        refresh()
    }

    /// Open the Login Items pane so the user can approve the app.
    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    /// Enable launch at login (convenience method for setup)
    func enable() {
        isEnabled = true
    }

    /// Disable launch at login
    func disable() {
        isEnabled = false
    }
}
