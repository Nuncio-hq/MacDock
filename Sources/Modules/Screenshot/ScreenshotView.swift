import SwiftUI

struct ScreenshotModule: DockModule {
    let id = "screenshot"
    let title = "Screenshot"
    let systemImage = "camera.viewfinder"
    func makeView() -> some View { ScreenshotView() }
}

struct ScreenshotView: View {
    @StateObject private var service = ScreenshotService()

    var body: some View {
        VStack(spacing: 12) {
            Grid(horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    CaptureButton(title: "Area → Clipboard", icon: "viewfinder",
                                  action: service.areaToClipboard)
                    CaptureButton(title: "Window → Clipboard", icon: "macwindow",
                                  action: service.windowToClipboard)
                }
                GridRow {
                    CaptureButton(title: "Area → File", icon: "square.dashed",
                                  action: service.areaToFile)
                    CaptureButton(title: "Full Screen → File", icon: "rectangle.dashed",
                                  action: service.fullScreenToFile)
                }
            }
            .padding(.horizontal)

            if let url = service.lastCaptureURL {
                LabeledContent("Last capture") {
                    Button(url.lastPathComponent) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                        .buttonStyle(.link)
                }
                .padding(.horizontal)
            }

            Spacer()

            Text("Captures save to ~/Pictures/MacDock. Screen Recording permission is required for non-interactive captures.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
                .padding(.bottom, 8)
        }
        .padding(.top, 12)
    }
}

private struct CaptureButton: View {
    let title: String
    let icon: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon).font(.title2)
                Text(title).font(.caption)
            }
            .frame(maxWidth: .infinity, minHeight: 56)
        }
        .buttonStyle(.bordered)
    }
}
