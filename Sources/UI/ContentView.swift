import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var registry: ModuleRegistry
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(spacing: 0) {
            TabView {
                ForEach(registry.enabledModules) { module in
                    module.makeView()
                        .tabItem { Label(module.title, systemImage: module.systemImage) }
                }
            }
            .frame(width: 360, height: 420)

            Divider()

            HStack {
                Text("MacDock").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button {
                    openSettings()
                    NSApp.activate(ignoringOtherApps: true)
                } label: {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.borderless)
                .help("Settings")
                Button("Quit") { NSApp.terminate(nil) }
                    .buttonStyle(.borderless)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }
}
