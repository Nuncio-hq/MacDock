import AppKit
import Foundation

/// Wraps the native `screencapture` tool: interactive area/window capture
/// and full-screen capture to a folder of the user's choice.
@MainActor
final class ScreenshotService: ObservableObject {
    @Published var lastCaptureURL: URL?

    private let captureDir: URL = {
        let dir = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacDock", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// Interactive area selection straight to the clipboard.
    func areaToClipboard() {
        run(["-i", "-c"])
    }

    /// Interactive window capture straight to the clipboard.
    func windowToClipboard() {
        run(["-i", "-w", "-c"])
    }

    /// Interactive area selection saved to ~/Pictures/MacDock.
    func areaToFile() {
        run(["-i", captureFile().path])
    }

    /// Full-screen capture of every display to ~/Pictures/MacDock.
    func fullScreenToFile() {
        run(["-x", captureFile().path])
    }

    private func captureFile() -> URL {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd-HHmmss"
        let stamp = fmt.string(from: Date())
        return captureDir.appendingPathComponent("MacDock-\(stamp).png")
    }

    private func run(_ args: [String]) {
        let destPath = args.last
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = args
        process.terminationHandler = { [weak self] p in
            guard p.terminationStatus == 0, let destPath,
                  FileManager.default.fileExists(atPath: destPath) else { return }
            Task { @MainActor in self?.lastCaptureURL = URL(fileURLWithPath: destPath) }
        }
        try? process.run()
    }
}
