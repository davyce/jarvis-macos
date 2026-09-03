import Foundation

/// Bridges `JarvisBridge` to LIMULE Bridge (local HTTP control server).
/// Kept in its own file, entirely additive: `JarvisBridge.perform` is
/// synchronous and stays that way for its existing four actions and three
/// AXUIElement system actions; Bridge calls are inherently async network
/// I/O, so this adds a parallel async entry point instead of widening the
/// existing one -- zero risk to the tested, existing call sites.
extension JarvisBridge {
    /// Injection points, same style as the AXUIElement system actions in
    /// `JarvisBridge.swift`.
    nonisolated(unsafe) static var limuleBridgeEnabled: () -> Bool = { LimuleBridgeSettings.isEnabled }
    nonisolated(unsafe) static var limuleBridgeTokenGate: () -> Bool = { LimuleBridgeAuthentication.token() != nil }
    nonisolated(unsafe) static var limuleBridgeAuditRecorder: (LimuleBridgeAuditEntry) -> Void = { LocalDatabase.shared.insertLimuleBridgeAudit($0) }
    nonisolated(unsafe) static var limuleBridgeAuditLoader: (Int) -> [LimuleBridgeAuditEntry] = { LocalDatabase.shared.loadLimuleBridgeAudit(limit: $0) }
    nonisolated(unsafe) static var limuleBridgeExecute: (LimuleBridgeAction) async throws -> LimuleBridgeClient.ActionResult = LimuleBridgeClient.perform

    enum LimuleBridgeGateError: LocalizedError {
        case disabled
        case tokenUnavailable

        var errorDescription: String? {
            switch self {
            case .disabled:
                return "LIMULE Bridge est desactive. Active-le dans Connections > LIMULE Bridge."
            case .tokenUnavailable:
                return "LIMULE Bridge n'est pas disponible sur ce Mac (l'app LIMULE doit avoir tourne au moins une fois)."
            }
        }
    }

    /// Checks the master toggle and token availability, executes, and
    /// always records the outcome -- success or failure -- to the Suivi
    /// before returning or throwing. No per-action confirmation: see
    /// `LimuleBridgeAction`'s doc comment for why -- this audit trail is
    /// the safety net in its place. Shared by `performLimuleBridgeAction`
    /// (which discards `.data`) and `performScreenshotBridgeAction` (which
    /// needs it) rather than each re-implementing the same gate.
    private static func executeAndAudit(_ action: LimuleBridgeAction) async throws -> LimuleBridgeClient.ActionResult {
        guard limuleBridgeEnabled() else { throw LimuleBridgeGateError.disabled }
        guard limuleBridgeTokenGate() else { throw LimuleBridgeGateError.tokenUnavailable }

        do {
            let result = try await limuleBridgeExecute(action)
            recordLimuleBridgeAudit(action: action, outcome: .success, detail: result.message)
            return result
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            let reminder = recentFailureReminder(forRoute: action.path)
            recordLimuleBridgeAudit(action: action, outcome: .failure, detail: message)
            let combined = reminder.map { "\(message)\n\n\($0)" } ?? message
            throw LimuleBridgeFailureMessage(errorDescription: combined)
        }
    }

    private struct LimuleBridgeFailureMessage: LocalizedError {
        let errorDescription: String?
    }

    /// If this same route also failed recently (within 24h -- an old,
    /// possibly since-fixed failure isn't worth resurfacing), returns a
    /// short reminder to append to the new failure's message. `Jarvis` has
    /// no tool-calling loop to retry within a turn, so this is how a
    /// repeated failure actually becomes visible to whoever reads the
    /// reply -- most Bridge calls are deterministic chat triggers that
    /// never reach `askLimule()`'s system-prompt failure digest at all.
    private static func recentFailureReminder(forRoute route: String) -> String? {
        guard let previous = limuleBridgeAuditLoader(20).first(where: { $0.route == route && $0.outcome == .failure }),
              Date.now.timeIntervalSince(previous.createdAt) < 24 * 3600 else { return nil }
        return "Cette action a deja echoue recemment : \(previous.detail)"
    }

    /// Performs one LIMULE Bridge action, discarding any binary payload
    /// (`.data`) -- every action except `.screenshot` has none anyway. See
    /// `performScreenshotBridgeAction` for the one action that needs it.
    static func performLimuleBridgeAction(_ action: LimuleBridgeAction) async -> ActionResult {
        do {
            let result = try await executeAndAudit(action)
            return ActionResult(succeeded: true, message: result.message)
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return ActionResult(succeeded: false, message: message)
        }
    }

    struct ScreenshotActionResult {
        let succeeded: Bool
        let message: String
        let localPath: String?
        let width: Int?
        let height: Int?
    }

    /// Same gate/execute/audit as `performLimuleBridgeAction`, but saves
    /// the PNG bytes LIMULE Bridge actually returns for `.screenshot`
    /// (`LimuleBridgeClient.ActionResult.data`, previously discarded here)
    /// via `ScreenshotStore`, and returns the local path so the chat
    /// message can embed a ```screenshot fence instead of text-only
    /// confirmation. Degrades to the same message-only shape as any other
    /// Bridge action on failure, missing data, or a save error -- never a
    /// crash on garbled/absent bytes.
    static func performScreenshotBridgeAction(displayID: Int?) async -> ScreenshotActionResult {
        do {
            let result = try await executeAndAudit(.screenshot(displayID: displayID))
            guard let data = result.data else {
                return ScreenshotActionResult(succeeded: true, message: result.message, localPath: nil, width: nil, height: nil)
            }
            do {
                let saved = try ScreenshotStore.save(data)
                return ScreenshotActionResult(succeeded: true, message: result.message, localPath: saved.path, width: saved.width, height: saved.height)
            } catch {
                return ScreenshotActionResult(succeeded: true, message: result.message, localPath: nil, width: nil, height: nil)
            }
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return ScreenshotActionResult(succeeded: false, message: message, localPath: nil, width: nil, height: nil)
        }
    }

    private static func recordLimuleBridgeAudit(action: LimuleBridgeAction, outcome: LimuleBridgeAuditEntry.Outcome, detail: String) {
        limuleBridgeAuditRecorder(LimuleBridgeAuditEntry(
            route: action.path,
            summary: action.auditSummary,
            outcome: outcome,
            detail: detail
        ))
    }

    struct ObservationResult {
        let succeeded: Bool
        let message: String
        let content: String?
    }

    /// Same gate/execute/audit as `performLimuleBridgeAction`, but for the
    /// small set of routes whose whole purpose is to observe something
    /// (clipboard, windows, screens, an app's accessibility tree, a
    /// browser page). `performLimuleBridgeAction` discards the response
    /// body entirely -- its `message` is just `action.auditSummary`, a
    /// fixed label like "Lecture du presse-papiers" -- so a chat trigger
    /// built on it alone would have nothing real to show. `content` here
    /// is the actual decoded payload (verified against LIMULE Bridge's own
    /// server source for each route's exact JSON shape), meant to be
    /// embedded verbatim in the chat reply: the model must never be told
    /// Jarvis "observed" something without that observation's real content
    /// appearing in the conversation, same anti-hallucination discipline
    /// already applied to file reads.
    static func performLimuleObservation(_ action: LimuleBridgeAction) async -> ObservationResult {
        do {
            let result = try await executeAndAudit(action)
            return ObservationResult(succeeded: true, message: result.message, content: decodeObservation(action: action, data: result.data))
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return ObservationResult(succeeded: false, message: message, content: nil)
        }
    }

    private static func decodeObservation(action: LimuleBridgeAction, data: Data?) -> String? {
        guard let data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        switch action {
        case .health:
            let status = json["status"] as? String ?? "inconnu"
            let accessibility = (json["accessibility"] as? Bool) ?? false
            return "Statut : \(status). Accessibilite accordee a Bridge : \(accessibility ? "oui" : "non")."

        case .displays:
            guard let displays = json["displays"] as? [[String: Any]] else { return nil }
            let lines = displays.map { d -> String in
                let id = (d["id"] as? Int).map(String.init) ?? "?"
                let width = (d["width"] as? Int).map(String.init) ?? "?"
                let height = (d["height"] as? Int).map(String.init) ?? "?"
                let isMain = (d["is_main"] as? Bool) ?? false
                return "Ecran \(id) : \(width)x\(height)" + (isMain ? " (principal)" : "")
            }
            return lines.isEmpty ? "Aucun ecran detecte." : lines.joined(separator: "\n")

        case .snapshot:
            let app = json["app"] as? String ?? "application inconnue"
            guard let treeValue = json["tree"],
                  let treeData = try? JSONSerialization.data(withJSONObject: treeValue),
                  let treeString = String(data: treeData, encoding: .utf8) else {
                return "Application : \(app)."
            }
            return "Application : \(app).\n\n\(truncate(treeString, limit: 4000))"

        case .getClipboard:
            let text = json["text"] as? String ?? ""
            return text.isEmpty ? "Le presse-papiers est vide." : truncate(text, limit: 4000)

        case .windows:
            guard let windows = json["windows"] as? [[String: Any]] else { return nil }
            let lines = windows.map { w -> String in
                let app = w["app"] as? String ?? "?"
                let title = w["title"] as? String ?? ""
                return title.isEmpty ? app : "\(app) -- \(title)"
            }
            return lines.isEmpty ? "Aucune fenetre ouverte." : truncate(lines.joined(separator: "\n"), limit: 4000)

        case .browserText:
            let text = json["text"] as? String ?? ""
            let url = json["url"] as? String ?? ""
            let body = text.isEmpty ? "Page sans texte extrait." : truncate(text, limit: 4000)
            return url.isEmpty ? body : "\(body)\n\nURL : \(url)"

        default:
            return nil
        }
    }

    private static func truncate(_ text: String, limit: Int) -> String {
        text.count > limit ? String(text.prefix(limit)) + "\u{2026} (tronque)" : text
    }
}
