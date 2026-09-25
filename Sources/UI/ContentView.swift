import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var registry: ModuleRegistry
    @EnvironmentObject private var updater: UpdaterController
    @Environment(\.openSettings) private var openSettings
    @State private var selectedModuleID: String?

    private var modules: [AnyDockModule] { registry.enabledModules }
    private var selected: AnyDockModule? {
        modules.first { $0.id == selectedModuleID } ?? modules.first
    }

    var body: some View {
        VStack(spacing: 0) {
            SegmentedBar(modules: modules, selectedID: $selectedModuleID)
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 8)

            Group {
                if let selected {
                    selected.makeView()
                        .id(selected.id)
                } else {
                    ContentUnavailableView("No Modules Enabled",
                                           systemImage: "square.stack",
                                           description: Text("Enable modules in Settings."))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 10)

            Divider()
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .opacity(0.4)

            HStack(spacing: 16) {
                Button {
                    openSettings()
                    NSApp.activate(ignoringOtherApps: true)
                } label: {
                    Label("Preferences", systemImage: "gearshape")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)

                Button {
                    updater.checkForUpdates()
                } label: {
                    Label("Updates", systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)

                Spacer()

                Button {
                    NSApp.terminate(nil)
                } label: {
                    Label("Quit", systemImage: "power")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            .font(.callout)
            .padding(.horizontal, 16)
            .padding(.bottom, 10)
        }
        .frame(width: 360, height: 460)
        .background(.regularMaterial)
    }
}

/// Custom glass segmented control: capsule highlight over a translucent strip.
private struct SegmentedBar: View {
    let modules: [AnyDockModule]
    @Binding var selectedID: String?
    @Namespace private var capsule

    var body: some View {
        HStack(spacing: 0) {
            ForEach(modules) { module in
                let isSelected = module.id == (selectedID ?? modules.first?.id)
                Button {
                    withAnimation(.snappy(duration: 0.22)) {
                        selectedID = module.id
                    }
                } label: {
                    Label(module.title, systemImage: module.systemImage)
                        .font(.callout)
                        .labelStyle(.titleAndIcon)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background {
                            if isSelected {
                                Capsule()
                                    .fill(.background)
                                    .shadow(color: .black.opacity(0.12), radius: 4, y: 1)
                                    .matchedGeometryEffect(id: "capsule", in: capsule)
                            }
                        }
                        .foregroundStyle(isSelected ? Color.accentTeal : .secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(.quaternary.opacity(0.5), in: Capsule())
    }
}

extension Color {
    /// MacDock accent: teal matching the app icon's accent bar.
    static let accentTeal = Color(red: 0.04, green: 0.73, blue: 0.71)
}
