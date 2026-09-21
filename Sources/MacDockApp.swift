import SwiftUI

@main
struct MacDockApp: App {
    @StateObject private var registry = ModuleRegistry()

    var body: some Scene {
        MenuBarExtra("MacDock", image: "MenuBarIcon") {
            ContentView()
                .environmentObject(registry)
                .tint(Color.accentTeal)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(registry)
        }
    }
}
