import SwiftUI

/// A self-contained utility that lives inside the MacDock panel.
/// Each module owns its service, its view, and whether it is enabled.
protocol DockModule: Identifiable, Sendable {
    var id: String { get }
    var title: String { get }
    var systemImage: String { get }
    associatedtype Body: View
    @MainActor @ViewBuilder func makeView() -> Body
}

struct AnyDockModule: Identifiable {
    let id: String
    let title: String
    let systemImage: String
    private let _makeView: @MainActor () -> AnyView

    init<M: DockModule>(_ module: M) {
        id = module.id
        title = module.title
        systemImage = module.systemImage
        _makeView = { AnyView(module.makeView()) }
    }

    @MainActor func makeView() -> AnyView { _makeView() }
}
