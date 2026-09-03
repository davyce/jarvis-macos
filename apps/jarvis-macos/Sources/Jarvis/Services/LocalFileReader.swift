import Foundation

enum LocalFileReader {
    enum ReadError: LocalizedError {
        case unsupported
        case unreadable

        var errorDescription: String? {
            switch self {
            case .unsupported: return "Ce format ne peut pas etre affiche comme texte."
            case .unreadable: return "Jarvis ne peut pas lire ce fichier."
            }
        }
    }

    static func entries(in directory: URL) -> [URL] {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return urls.sorted {
            let leftDirectory = (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            let rightDirectory = (try? $1.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if leftDirectory != rightDirectory { return leftDirectory }
            return $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending
        }
    }

    /// Extensions never worth attempting to decode as text -- covers common
    /// binary/media/archive/font/executable formats, not just the original
    /// small handful. Broadened after live testing of `LocalFileService`'s
    /// content search showed it stalling on real Desktop/Documents folders:
    /// every non-name-matching file was being fully read into memory just
    /// to fail UTF-8 decoding, which is slow across thousands of photos,
    /// videos, and other binaries a real folder actually contains.
    static let blockedExtensions: Set<String> = [
        "app", "dmg", "zip", "rar", "7z", "tar", "gz", "bz2",
        "png", "jpg", "jpeg", "gif", "heic", "heif", "tiff", "tif", "bmp", "webp", "ico", "psd", "ai", "sketch", "fig",
        "pdf", "docx", "xlsx", "numbers", "pages", "key", "ppt", "pptx", "doc", "xls",
        "mp3", "mp4", "mov", "avi", "mkv", "wav", "m4a", "m4v", "aac", "flac", "webm",
        "sqlite", "sqlite3", "db", "plist", "icns",
        "ttf", "otf", "woff", "woff2",
        "exe", "dll", "so", "dylib", "a", "o", "class", "jar", "wasm"
    ]

    static func read(url: URL) throws -> String {
        guard !blockedExtensions.contains(url.pathExtension.lowercased()) else { throw ReadError.unsupported }
        // Check size via metadata before reading -- Data(contentsOf:) would
        // otherwise load an oversized file fully into memory just to then
        // discard it for being too big.
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
        guard let size, size <= 512_000 else { throw ReadError.unreadable }
        guard let data = try? Data(contentsOf: url) else { throw ReadError.unreadable }
        guard let text = String(data: data, encoding: .utf8) else { throw ReadError.unsupported }
        return text
    }
}
