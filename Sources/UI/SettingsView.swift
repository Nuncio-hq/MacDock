import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var registry: ModuleRegistry

    var body: some View {
        Form {
            Section("Modules") {
                Toggle("System Monitor", isOn: $registry.monitorEnabled)
                Toggle("Clipboard History", isOn: $registry.clipboardEnabled)
                Toggle("Screenshot", isOn: $registry.screenshotEnabled)
            }
        }
        .formStyle(.grouped)
        .frame(width: 380, height: 200)
    }
}
