import Foundation

struct RecentFileEntry: Identifiable, Equatable {
    let path: String
    let modifiedAt: Date

    var id: String { path }
    var name: String { (path as NSString).lastPathComponent }
}

enum RecentFilesInspector {
    static func recentFiles(in projectPath: String, limit: Int = 8) -> [RecentFileEntry] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: URL(fileURLWithPath: projectPath),
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var results: [RecentFileEntry] = []
        var scanned = 0

        while let url = enumerator.nextObject() as? URL {
            scanned += 1
            if scanned > FileScanPolicy.maxScannedPerRoot { break }

            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey])
            if values?.isDirectory == true {
                if FileScanPolicy.ignoredDirectories.contains(url.lastPathComponent) {
                    enumerator.skipDescendants()
                }
                continue
            }
            guard let modified = values?.contentModificationDate else { continue }
            results.append(RecentFileEntry(path: url.path, modifiedAt: modified))
        }

        return Array(
            results
                .sorted { $0.modifiedAt > $1.modifiedAt }
                .prefix(limit)
        )
    }
}
