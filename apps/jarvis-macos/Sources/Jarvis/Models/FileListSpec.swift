import Foundation

/// Parsed contents of a ```filelist fenced block Jarvis emits after a file
/// search -- same shape/spirit as `ChartSpec`: pure `Codable`, `parse(from:)`
/// never throws, malformed JSON just means "show as a plain code block
/// instead" at the call site.
struct FileListSpec: Codable, Equatable {
    struct Entry: Codable, Equatable {
        let path: String
        let isDirectory: Bool
        let modifiedAt: Date?
    }

    let query: String
    let entries: [Entry]
    let truncated: Bool

    static func parse(from json: String) -> FileListSpec? {
        guard let raw = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(FileListSpec.self, from: raw)
    }

    func toJSON() -> String? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
