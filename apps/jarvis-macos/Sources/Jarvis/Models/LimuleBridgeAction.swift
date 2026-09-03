import Foundation

/// One call to LIMULE Bridge (`http://127.0.0.1:8765`), the local HTTP
/// server bundled with LIMULE's own native app that gives direct control
/// of this Mac (mouse, keyboard, files, browser, messages...). Every case
/// here corresponds 1:1 to a documented Bridge route -- unlike the raw
/// generic primitives Bridge itself exposes, callers always go through a
/// named case, so the possible actions are enumerable and every one of
/// them has a fixed, reviewed audit summary (see `auditSummary`).
///
/// This has no per-action confirmation gate, unlike `SystemActionCapability`
/// -- Bridge itself has none, and a deliberate decision was made not to add
/// one in Jarvis either. The Suivi (audit trail) is the safety net instead:
/// every action, successful or not, is logged before this call returns.
enum LimuleBridgeAction: Sendable {
    case health
    case screenshot(displayID: Int?)
    case displays
    case snapshot(app: String?)
    case click(x: Double, y: Double)
    case doubleClick(x: Double, y: Double)
    case rightClick(x: Double, y: Double)
    case drag(fromX: Double, fromY: Double, toX: Double, toY: Double)
    case getClipboard
    case setClipboard(text: String)
    case windows
    case type(text: String)
    case key(combo: String)
    case scroll(dx: Int, dy: Int)
    case launchApp(bundleID: String)
    case activateApp(bundleID: String)
    case press(title: String, app: String?)
    case startTimer(seconds: Int)
    case startAlarm(hour: Int, minute: Int, label: String?)
    case createReminder(title: String, list: String?)
    case sendMessage(recipient: String, text: String)
    case createNote(title: String, body: String)
    case createDocument(app: String, title: String, body: String)
    case writeTextFile(path: String, content: String)
    case readTextFile(path: String)
    case browserNavigate(url: String)
    case browserText
    case browserClick(target: String)
    case browserType(target: String, text: String)
    case listDirectory(path: String)
    case moveFile(from: String, to: String)
    case searchFiles(query: String, path: String)
    case undo

    var method: String {
        switch self {
        case .health, .screenshot, .displays, .snapshot, .getClipboard, .windows:
            return "GET"
        default:
            return "POST"
        }
    }

    var path: String {
        switch self {
        case .health: return "/health"
        case .screenshot: return "/screenshot"
        case .displays: return "/displays"
        case .snapshot: return "/snapshot"
        case .click: return "/click"
        case .doubleClick: return "/double_click"
        case .rightClick: return "/right_click"
        case .drag: return "/drag"
        case .getClipboard, .setClipboard: return "/clipboard"
        case .windows: return "/windows"
        case .type: return "/type"
        case .key: return "/key"
        case .scroll: return "/scroll"
        case .launchApp: return "/launch_app"
        case .activateApp: return "/activate_app"
        case .press: return "/press"
        case .startTimer: return "/start_timer"
        case .startAlarm: return "/start_alarm"
        case .createReminder: return "/create_reminder"
        case .sendMessage: return "/send_message"
        case .createNote: return "/create_note"
        case .createDocument: return "/create_document"
        case .writeTextFile: return "/write_text_file"
        case .readTextFile: return "/read_text_file"
        case .browserNavigate: return "/browser_navigate"
        case .browserText: return "/browser_text"
        case .browserClick: return "/browser_click"
        case .browserType: return "/browser_type"
        case .listDirectory: return "/list_directory"
        case .moveFile: return "/move_file"
        case .searchFiles: return "/search_files"
        case .undo: return "/undo"
        }
    }

    /// Only GET routes use a query string; every POST route sends its
    /// arguments as a JSON body instead.
    var queryItems: [String: String] {
        switch self {
        case .screenshot(let displayID):
            return displayID.map { ["display_id": String($0)] } ?? [:]
        case .snapshot(let app):
            return app.map { ["app": $0] } ?? [:]
        default:
            return [:]
        }
    }

    /// Every POST route's body. `nil` bodies still send `{}` -- Bridge
    /// requires `Content-Type: application/json` on every POST regardless.
    var jsonBody: [String: Any]? {
        switch self {
        case .click(let x, let y), .doubleClick(let x, let y), .rightClick(let x, let y):
            return ["x": x, "y": y]
        case .drag(let fromX, let fromY, let toX, let toY):
            return ["from_x": fromX, "from_y": fromY, "to_x": toX, "to_y": toY]
        case .setClipboard(let text):
            return ["text": text]
        case .type(let text):
            return ["text": text]
        case .key(let combo):
            return ["combo": combo]
        case .scroll(let dx, let dy):
            return ["dx": dx, "dy": dy]
        case .launchApp(let bundleID), .activateApp(let bundleID):
            return ["bundleId": bundleID]
        case .press(let title, let app):
            var body: [String: Any] = ["title": title]
            if let app { body["app"] = app }
            return body
        case .startTimer(let seconds):
            return ["seconds": seconds]
        case .startAlarm(let hour, let minute, let label):
            var body: [String: Any] = ["hour": hour, "minute": minute]
            if let label { body["label"] = label }
            return body
        case .createReminder(let title, let list):
            var body: [String: Any] = ["title": title]
            if let list { body["list"] = list }
            return body
        case .sendMessage(let recipient, let text):
            return ["recipient": recipient, "text": text]
        case .createNote(let title, let body):
            return ["title": title, "body": body]
        case .createDocument(let app, let title, let body):
            return ["app": app, "title": title, "body": body]
        case .writeTextFile(let path, let content):
            return ["path": path, "content": content]
        case .readTextFile(let path):
            return ["path": path]
        case .browserNavigate(let url):
            return ["url": url]
        case .browserClick(let target):
            return ["target": target]
        case .browserType(let target, let text):
            return ["target": target, "text": text]
        case .listDirectory(let path):
            return ["path": path]
        case .moveFile(let from, let to):
            return ["from": from, "to": to]
        case .searchFiles(let query, let path):
            return ["query": query, "path": path]
        case .undo, .browserText:
            return [:]
        default:
            return nil
        }
    }

    /// Matches the reference table exactly -- every route that isn't a
    /// pure read (health/screenshot/displays/snapshot/clipboard-GET/windows/
    /// read_text_file/browser_text/list_directory/search_files) is sensitive.
    var isSensitive: Bool {
        switch self {
        case .health, .screenshot, .displays, .snapshot, .getClipboard, .windows,
             .readTextFile, .browserText, .listDirectory, .searchFiles:
            return false
        default:
            return true
        }
    }

    var isBinaryResponse: Bool {
        if case .screenshot = self { return true }
        return false
    }

    /// One redacted, human-readable line per action for the Suivi audit
    /// trail -- never the full content of a file, message, or note, just
    /// enough to review after the fact what Jarvis actually did.
    var auditSummary: String {
        switch self {
        case .health: return "Verification de disponibilite Bridge"
        case .screenshot(let displayID): return "Capture d'ecran" + (displayID.map { " (ecran \($0))" } ?? "")
        case .displays: return "Liste des ecrans"
        case .snapshot(let app): return "Lecture de l'arbre d'accessibilite" + (app.map { " de \($0)" } ?? "")
        case .click(let x, let y): return "Clic en (\(Int(x)), \(Int(y)))"
        case .doubleClick(let x, let y): return "Double-clic en (\(Int(x)), \(Int(y)))"
        case .rightClick(let x, let y): return "Clic droit en (\(Int(x)), \(Int(y)))"
        case .drag: return "Glisser-deposer"
        case .getClipboard: return "Lecture du presse-papiers"
        case .setClipboard: return "Ecriture dans le presse-papiers"
        case .windows: return "Liste des fenetres"
        case .type(let text): return "Frappe clavier : \u{201C}\(Self.truncate(text))\u{201D}"
        case .key(let combo): return "Raccourci clavier \(combo)"
        case .scroll: return "Defilement"
        case .launchApp(let bundleID): return "Lancement de \(bundleID)"
        case .activateApp(let bundleID): return "Mise au premier plan de \(bundleID)"
        case .press(let title, let app): return "Clic sur \u{201C}\(title)\u{201D}" + (app.map { " dans \($0)" } ?? "")
        case .startTimer(let seconds): return "Minuteur de \(seconds)s"
        case .startAlarm(let hour, let minute, _): return "Alarme a \(String(format: "%02d:%02d", hour, minute))"
        case .createReminder(let title, _): return "Rappel : \u{201C}\(title)\u{201D}"
        case .sendMessage(let recipient, let text): return "Message a \(recipient) : \u{201C}\(Self.truncate(text))\u{201D}"
        case .createNote(let title, _): return "Note : \u{201C}\(title)\u{201D}"
        case .createDocument(let app, let title, _): return "Document \u{201C}\(title)\u{201D} dans \(app)"
        case .writeTextFile(let path, _): return "Ecriture du fichier \(path)"
        case .readTextFile(let path): return "Lecture du fichier \(path)"
        case .browserNavigate(let url): return "Navigation vers \(url)"
        case .browserText: return "Lecture du texte de la page"
        case .browserClick(let target): return "Clic sur \u{201C}\(target)\u{201D} dans le navigateur"
        case .browserType(let target, _): return "Frappe dans \u{201C}\(target)\u{201D} du navigateur"
        case .listDirectory(let path): return "Liste du dossier \(path)"
        case .moveFile(let from, let to): return "Deplacement de \(from) vers \(to)"
        case .searchFiles(let query, let path): return "Recherche \u{201C}\(query)\u{201D} dans \(path)"
        case .undo: return "Annulation de la derniere action"
        }
    }

    private static func truncate(_ text: String, limit: Int = 60) -> String {
        text.count > limit ? String(text.prefix(limit)) + "\u{2026}" : text
    }
}
