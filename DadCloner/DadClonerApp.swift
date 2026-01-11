import SwiftUI

@main
struct DadClonerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // We don't use a WindowGroup since this is a menu bar app
        Settings {
            EmptyView()
        }
    }
}
