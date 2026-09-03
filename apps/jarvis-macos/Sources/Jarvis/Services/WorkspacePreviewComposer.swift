import Foundation

/// Short, bounded previews of workspace items for the system prompt --
/// enough for the model to judge relevance and decide what deserves a full
/// `read_file`/`search_files` call, without spending the context budget on
/// every connected item's full content up front.
enum WorkspacePreviewComposer {
    private static let filePreviewCharLimit = 400
    /// Read at most this many bytes off disk before deciding a file is too
    /// large/binary to preview usefully -- avoids loading a multi-gigabyte
    /// file just to keep 400 characters of it.
    private static let fileReadByteLimit = 8_192
    private static let folderEntryLimit = 20

    static func preview(for item: WorkspaceItem) -> String {
        switch item.kind {
        case .file: filePreview(path: item.path)
        case .folder: folderPreview(path: item.path)
        }
    }

    private static func filePreview(path: String) -> String {
        guard let handle = FileHandle(forReadingAtPath: path) else {
            return "(apercu indisponible -- fichier illisible)"
        }
        defer { try? handle.close() }
        let data = handle.readData(ofLength: fileReadByteLimit)
        guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else {
            return "(apercu indisponible -- fichier non textuel ou illisible)"
        }
        guard text.count > filePreviewCharLimit else { return text }
        return "\(text.prefix(filePreviewCharLimit))…"
    }

    private static func folderPreview(path: String) -> String {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: path) else {
            return "(dossier illisible)"
        }
        let visible = entries.filter { !$0.hasPrefix(".") }.sorted()
        guard !visible.isEmpty else { return "(dossier vide)" }
        let shown = visible.prefix(folderEntryLimit)
        let remaining = visible.count - shown.count
        let list = shown.joined(separator: ", ")
        return remaining > 0 ? "\(list) (et \(remaining) de plus)" : list
    }
}
