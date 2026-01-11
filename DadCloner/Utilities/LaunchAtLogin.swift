import Foundation
import ServiceManagement

/// Manages the app's launch at login setting
@Observable
final class LaunchAtLogin {

    // MARK: - Singleton
    static let shared = LaunchAtLogin()

    // MARK: - Properties

    /// Whether the app is set to launch at login
    var isEnabled: Bool {
        get {
            if #available(macOS 13.0, *) {
                return SMAppService.mainApp.status == .enabled
            } else {
                // Fallback for older macOS - check UserDefaults as proxy
                return UserDefaults.standard.bool(forKey: "launchAtLogin")
            }
        }
        set {
            setLaunchAtLogin(enabled: newValue)
        }
    }

    // MARK: - Initialization

    private init() {}

    // MARK: - Methods

    /// Enable or disable launch at login
    func setLaunchAtLogin(enabled: Bool) {
        if #available(macOS 13.0, *) {
            do {
                if enabled {
                    try SMAppService.mainApp.register()
                    print("Registered as login item")
                } else {
                    try SMAppService.mainApp.unregister()
                    print("Unregistered as login item")
                }
            } catch {
                print("Failed to \(enabled ? "register" : "unregister") login item: \(error)")
            }
        } else {
            // Fallback for older macOS versions
            // Store preference (actual registration would need LSSharedFileList)
            UserDefaults.standard.set(enabled, forKey: "launchAtLogin")
        }
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
