import Foundation

/// Local, LIMULE-Bridge-independent file operations. Jarvis is a
/// non-sandboxed app with direct POSIX access to its own machine --
/// routing these through the optional, often-disabled Bridge server would
/// make the feature silently unavailable whenever the user hasn't enabled
/// it. Search is the only genuinely expensive operation here (multi-root
/// walk with content reads); every single-file operation below is a
/// single syscall and stays synchronous, same as `RecentFilesInspector`
/// and `LocalFileReader` already are.
enum LocalFileService {
    struct FileEntry: Identifiable, Equatable, Codable {
        let path: String
        let isDirectory: Bool
        let modifiedAt: Date?
        var id: String { path }
        var name: String { (path as NSString).lastPathComponent }
    }

    enum ServiceError: LocalizedError {
        case sourceMissing
        case destinationExists(String)

        var errorDescription: String? {
            switch self {
            case .sourceMissing:
                return "Le fichier source est introuvable."
            case .destinationExists(let path):
                return "Un fichier existe deja a \(path)."
            }
        }
    }

    /// Where "anywhere on the Mac" actually searches: the folders a normal
    /// user's files realistically live in, each independently bounded by
    /// `FileScanPolicy.maxScannedPerRoot` -- a literal walk of `$HOME`
    /// would also traverse `~/Library` (other apps' caches/containers) for
    /// no benefit and much higher cost.
    static let realDefaultSearchRoots: () -> [URL] = {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        var roots = [
            home.appendingPathComponent("Desktop"),
            home.appendingPathComponent("Documents"),
            home.appendingPathComponent("Downloads")
        ]
        let projects = home.appendingPathComponent("Projects")
        if fm.fileExists(atPath: projects.path) {
            roots.append(projects)
        }
        return roots
    }

    /// Injectable (tests point this at a disposable temp directory instead
    /// of scanning the real Desktop/Documents/Downloads on every run).
    nonisolated(unsafe) static var defaultSearchRoots: () -> [URL] = realDefaultSearchRoots

    /// Matches by filename (case/diacritic-insensitive) or, for files
    /// `LocalFileReader.read` can actually open (under its size cap, not a
    /// blocked binary extension), by content. A content-read failure just
    /// means "no content match" here, not an error -- most files hit in a
    /// broad scan are expected to be unreadable as text.
    static func search(query: String, roots: [URL] = defaultSearchRoots(), limit: Int = 30) async -> (entries: [FileEntry], truncated: Bool) {
        let folded = query.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        guard !folded.isEmpty else { return ([], false) }

        var results: [FileEntry] = []
        var truncated = false
        var contentChecksAttempted = 0
        let maxContentChecks = 2_000
        let fm = FileManager.default

        for root in roots {
            guard let enumerator = fm.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            var scanned = 0
            while let url = enumerator.nextObject() as? URL {
                if results.count >= limit {
                    truncated = true
                    break
                }
                scanned += 1
                if scanned > FileScanPolicy.maxScannedPerRoot { break }

                let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey])
                if values?.isDirectory == true {
                    if FileScanPolicy.ignoredDirectories.contains(url.lastPathComponent) {
                        enumerator.skipDescendants()
                    }
                    continue
                }

                let nameMatches = url.lastPathComponent
                    .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
                    .contains(folded)
                var contentMatches = false
                if !nameMatches, contentChecksAttempted < maxContentChecks,
                   !LocalFileReader.blockedExtensions.contains(url.pathExtension.lowercased()) {
                    contentChecksAttempted += 1
                    contentMatches = (try? LocalFileReader.read(url: url))?
                        .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
                        .contains(folded) ?? false
                }

                guard nameMatches || contentMatches else { continue }
                results.append(FileEntry(path: url.path, isDirectory: false, modifiedAt: values?.contentModificationDate))
            }
            if results.count >= limit { break }
        }

        return (results, truncated)
    }

    /// `URL(fileURLWithPath:)` never expands `~` the way a shell does --
    /// without this, a path like "~/Desktop/test.txt" resolves as a
    /// literal, nonexistent relative path component named "~" under
    /// whatever the app's current working directory happens to be.
    private static func expand(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }

    static func listDirectory(_ path: String) -> [FileEntry] {
        LocalFileReader.entries(in: URL(fileURLWithPath: expand(path))).map { url in
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey])
            return FileEntry(
                path: url.path,
                isDirectory: values?.isDirectory ?? false,
                modifiedAt: values?.contentModificationDate
            )
        }
    }

    /// Falls back to `DocumentConverter` (Pages/Numbers automation,
    /// NSAttributedString for Office/RTF) for formats `LocalFileReader`
    /// rejects outright but that DO have a real text-extraction path.
    /// Deliberately only reached from an explicit single-file read, never
    /// from `search`'s bulk content scan -- see `DocumentConverter`'s doc
    /// comment for why.
    static func readTextFile(_ path: String) throws -> String {
        let expanded = expand(path)
        do {
            return try LocalFileReader.read(url: URL(fileURLWithPath: expanded))
        } catch LocalFileReader.ReadError.unsupported {
            let ext = (expanded as NSString).pathExtension
            guard DocumentConverter.canConvert(extension: ext) else { throw LocalFileReader.ReadError.unsupported }
            return try DocumentConverter.extractText(from: expanded)
        }
    }

    static func writeTextFile(path: String, content: String) throws {
        try content.write(toFile: expand(path), atomically: true, encoding: .utf8)
    }

    /// Appends " copie" (incrementing on collision: "copie 2", "copie 3"...)
    /// before the extension. Returns the new file's path.
    static func duplicateFile(path: String) throws -> String {
        let path = expand(path)
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else { throw ServiceError.sourceMissing }
        let source = URL(fileURLWithPath: path)
        let ext = source.pathExtension
        let base = source.deletingPathExtension().lastPathComponent
        let directory = source.deletingLastPathComponent()

        var candidate = directory.appendingPathComponent(ext.isEmpty ? "\(base) copie" : "\(base) copie.\(ext)")
        var attempt = 2
        while fm.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent(ext.isEmpty ? "\(base) copie \(attempt)" : "\(base) copie \(attempt).\(ext)")
            attempt += 1
        }
        try fm.copyItem(at: source, to: candidate)
        return candidate.path
    }

    /// Injectable so tests can assert the right URL was passed without
    /// depending on real Trash behavior in a CI/sandboxed test runner.
    nonisolated(unsafe) static var trash: (URL) throws -> Void = { url in
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }

    /// Moves to the macOS Trash, never a permanent removal -- keeps a
    /// destructive chat action recoverable the same way deleting a file in
    /// the Finder is.
    static func deleteFile(path: String) throws {
        let path = expand(path)
        guard FileManager.default.fileExists(atPath: path) else { throw ServiceError.sourceMissing }
        try trash(URL(fileURLWithPath: path))
    }

    /// Covers both "move" and "rename" -- same primitive either way.
    static func moveFile(from: String, to: String) throws {
        let from = expand(from)
        let to = expand(to)
        let fm = FileManager.default
        guard fm.fileExists(atPath: from) else { throw ServiceError.sourceMissing }
        guard !fm.fileExists(atPath: to) else { throw ServiceError.destinationExists(to) }
        try fm.moveItem(at: URL(fileURLWithPath: from), to: URL(fileURLWithPath: to))
    }
}
