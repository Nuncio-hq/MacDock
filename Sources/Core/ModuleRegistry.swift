import SwiftUI

/// Central registry of every utility in the app.
/// Modules can be toggled on/off in Settings; the choice persists.
@MainActor
final class ModuleRegistry: ObservableObject {
    static let monitorKey = "module.monitor.enabled"
    static let clipboardKey = "module.clipboard.enabled"
    static let screenshotKey = "module.screenshot.enabled"

    @AppStorage(monitorKey) var monitorEnabled = true
    @AppStorage(clipboardKey) var clipboardEnabled = true
    @AppStorage(screenshotKey) var screenshotEnabled = true

    let monitor = AnyDockModule(MonitorModule())
    let clipboard = AnyDockModule(ClipboardModule())
    let screenshot = AnyDockModule(ScreenshotModule())

    var enabledModules: [AnyDockModule] {
        var list: [AnyDockModule] = []
        if monitorEnabled { list.append(monitor) }
        if clipboardEnabled { list.append(clipboard) }
        if screenshotEnabled { list.append(screenshot) }
        return list
    }
}
