import SwiftUI

@main
struct PRNotchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            RepositoryScopeSettingsView {
                appDelegate.repositoryScopeDidChange()
            }
        }
    }
}
