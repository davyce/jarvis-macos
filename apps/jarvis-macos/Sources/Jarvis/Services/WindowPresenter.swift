import AppKit

/// Brings the main Jarvis window to the front no matter its current state:
/// minimized, occluded behind other windows, or fully closed (in which case
/// SwiftUI has torn the window down and it has to be reopened via the
/// `openWindow` environment action, captured once from `RootView`).
@MainActor
enum WindowPresenter {
    static var openMainWindow: (() -> Void)?

    static func presentMainWindow() {
        NSApp.activate(ignoringOtherApps: true)

        if let window = NSApp.windows.first(where: { $0.title == "Jarvis" }) {
            if window.isMiniaturized {
                window.deminiaturize(nil)
            }
            window.makeKeyAndOrderFront(nil)
        } else {
            openMainWindow?()
        }

        NotificationCenter.default.post(name: .jarvisOpenCommand, object: nil)
    }
}
