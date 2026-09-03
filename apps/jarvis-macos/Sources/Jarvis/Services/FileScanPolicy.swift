import Foundation

/// Shared bounds for anything that walks a directory tree with
/// `FileManager.enumerator` (`RecentFilesInspector`, `LocalFileService`) --
/// kept in one place so the two scanners can't quietly drift apart.
enum FileScanPolicy {
    static let ignoredDirectories: Set<String> = [
        ".git", "node_modules", ".build", "DerivedData", "build", "dist",
        "__pycache__", ".venv", "venv", "Pods", ".next", ".cache", "xcuserdata"
    ]

    static let maxScannedPerRoot = 20_000
}
