import Foundation

/// Parsed contents of a ```screenshot fenced block -- same never-throw
/// `parse(from:)` shape as `ChartSpec`/`FileListSpec`. References a local
/// file by path rather than embedding image bytes: `CommandEntry` is
/// `Codable` and synced across devices via `WorkspaceSyncService`, so a
/// raw `Data` field has no place here. A path that doesn't resolve to a
/// real file on this device (e.g. a conversation synced from elsewhere,
/// where the PNG itself never traveled) is handled by `ScreenshotBlockView`
/// showing a fallback card, not by this type.
struct ScreenshotSpec: Codable, Equatable {
    let path: String
    let width: Int
    let height: Int
    let capturedAt: Date
    let displayID: Int?

    static func parse(from json: String) -> ScreenshotSpec? {
        guard let raw = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(ScreenshotSpec.self, from: raw)
    }

    func toJSON() -> String? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
