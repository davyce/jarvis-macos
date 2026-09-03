import SwiftUI

@main
struct JarvisApp: App {
    @State private var projectStore = ProjectStore()

    var body: some Scene {
        Window("Jarvis", id: "main") {
            RootView()
                .environment(projectStore)
                .frame(minWidth: 980, minHeight: 680)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
        .defaultSize(width: 1240, height: 780)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Jarvis") {
                Button("Ouvrir Jarvis") {
                    WindowPresenter.presentMainWindow()
                }
                .keyboardShortcut("k", modifiers: [.command])
                Divider()
                Button("Rafraichir les projets") {
                    projectStore.refreshAll()
                }
                .keyboardShortcut("r", modifiers: [.command])
            }
        }

        MenuBarExtra {
            JarvisMenuBarContent()
                .environment(projectStore)
        } label: {
            JarvisMenuBarLabel()
                .environment(projectStore)
        }
        .menuBarExtraStyle(.window)
    }
}

extension Notification.Name {
    static let jarvisOpenCommand = Notification.Name("jarvis.open-command")
}
