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

        Window("MacDock Storage", id: "storage") {
            StorageManagerView()
                .tint(Color.accentTeal)
        }
        .defaultSize(width: 960, height: 640)

        Settings {
            SettingsView()
                .environmentObject(registry)
        }
    }
}
