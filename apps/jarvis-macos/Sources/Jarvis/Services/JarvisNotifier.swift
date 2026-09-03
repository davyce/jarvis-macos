import Foundation
import UserNotifications

enum JarvisNotifier {
    static func requestAuthorizationIfNeeded() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
    }

    static func notifyBuildResult(project: JarvisProject, snapshot: BuildSnapshot) {
        let content = UNMutableNotificationContent()
        switch snapshot.state {
        case .failed(let detail):
            content.title = "Build en echec - \(project.name)"
            content.body = detail.split(separator: "\n").first.map(String.init) ?? "Voir Jarvis pour le detail."
        case .success:
            content.title = "Build reussi - \(project.name)"
            content.body = "Le dernier build verifie est passe."
        default:
            return
        }
        content.sound = .default

        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
