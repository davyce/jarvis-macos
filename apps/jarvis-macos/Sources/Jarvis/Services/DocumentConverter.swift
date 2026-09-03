import AppKit
import Foundation

/// Extracts readable text from document formats `LocalFileReader` can't
/// decode as plain UTF-8. Two independent paths:
/// - Rich-text/Office formats (.docx, .doc, .rtf, .rtfd, .odt, .html) via
///   `NSAttributedString` -- fast, synchronous, no special permission.
/// - Apple's own iWork formats (.pages, .numbers) via AppleScript
///   automation of the actual app: neither `textutil` nor
///   `NSAttributedString` can read these at all, but Pages/Numbers can
///   export themselves to unformatted text/CSV
///   (verified against iworkautomation.com's documented `export` command
///   syntax before implementing, not assumed). Keynote (.key) is
///   deliberately NOT supported here -- its `export` command has no
///   plain-text option, only HTML/PDF/PowerPoint/images/QuickTime.
///
/// Only ever invoked from an explicit single-file read (`lis le fichier
/// X`), never from `LocalFileService.search`'s bulk content-matching --
/// launching Pages/Numbers per matching file during a broad scan would
/// reintroduce the exact performance problem already fixed once this
/// session for `LocalFileReader.blockedExtensions`.
enum DocumentConverter {
    enum ConversionError: LocalizedError {
        case unsupportedFormat
        case automationFailed(String)

        var errorDescription: String? {
            switch self {
            case .unsupportedFormat:
                return "Ce format n'a pas de conversion en texte disponible."
            case .automationFailed(let message):
                return "La conversion a echoue : \(message)"
            }
        }
    }

    private static let richTextExtensions: Set<String> = ["docx", "doc", "rtf", "rtfd", "odt", "html", "htm"]

    static func canConvert(extension ext: String) -> Bool {
        let lower = ext.lowercased()
        return richTextExtensions.contains(lower) || lower == "pages" || lower == "numbers"
    }

    static func extractText(from path: String) throws -> String {
        let url = URL(fileURLWithPath: path)
        let ext = url.pathExtension.lowercased()

        if richTextExtensions.contains(ext) {
            return try extractRichText(url: url)
        }
        if ext == "pages" {
            return try extractViaAppleScript(url: url, appName: "Pages", exportSuffix: "txt") { source, target in
                """
                tell application "Pages"
                    activate
                    set theDoc to open POSIX file "\(source)"
                    with timeout of 120 seconds
                        export theDoc to file "\(target)" as unformatted text
                    end timeout
                    close theDoc saving no
                end tell
                """
            }
        }
        if ext == "numbers" {
            return try extractViaAppleScript(url: url, appName: "Numbers", exportSuffix: "csv") { source, target in
                """
                tell application "Numbers"
                    activate
                    set theDoc to open POSIX file "\(source)"
                    with timeout of 120 seconds
                        export theDoc to file "\(target)" as CSV
                    end timeout
                    close theDoc saving no
                end tell
                """
            }
        }
        throw ConversionError.unsupportedFormat
    }

    private static func extractRichText(url: URL) throws -> String {
        let attributed = try NSAttributedString(url: url, options: [:], documentAttributes: nil)
        return attributed.string
    }

    /// Injectable so tests can exercise the temp-file/error-handling logic
    /// around this without launching real Pages/Numbers.
    nonisolated(unsafe) static var runAppleScript: (String) throws -> Void = { source in
        var errorDict: NSDictionary?
        guard let script = NSAppleScript(source: source) else {
            throw ConversionError.automationFailed("Script invalide.")
        }
        script.executeAndReturnError(&errorDict)
        if let errorDict {
            let message = errorDict[NSAppleScript.errorMessage] as? String ?? "Erreur inconnue."
            throw ConversionError.automationFailed(message)
        }
    }

    /// Pages/Numbers are sandboxed Mac App Store apps -- they can't write
    /// an export to an arbitrary path like Jarvis's own
    /// `FileManager.temporaryDirectory` (a private per-process location
    /// outside their sandbox container), only to locations their sandbox
    /// profile actually grants, like `~/Documents`. Confirmed live: the
    /// first implementation used the system temp dir and Pages failed with
    /// "n'a pas pu etre exporte sous le nom ...". The reference AppleScript
    /// example (iworkautomation.com) exports to `(path to documents
    /// folder)` for the same reason, not assumed here after the fact.
    private static func exportScratchDirectory() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent(".jarvis-exports", isDirectory: true)
    }

    /// The manual menu path to suggest when automation fails, per app.
    private static let manualExportMenuPath: [String: String] = [
        "Pages": "Fichier > Exporter vers > Texte...",
        "Numbers": "Fichier > Exporter vers > CSV..."
    ]

    private static func extractViaAppleScript(
        url: URL,
        appName: String,
        exportSuffix: String,
        script: (String, String) -> String
    ) throws -> String {
        let scratchDirectory = exportScratchDirectory()
        try? FileManager.default.createDirectory(at: scratchDirectory, withIntermediateDirectories: true)
        let tempFile = scratchDirectory.appendingPathComponent("\(UUID().uuidString).\(exportSuffix)")
        defer { try? FileManager.default.removeItem(at: tempFile) }

        do {
            try runAppleScript(script(escapeForAppleScript(url.path), escapeForAppleScript(tempFile.path)))
        } catch {
            // Confirmed live (reproduced outside Jarvis entirely, even on a
            // brand-new blank document): this is a long-standing Apple bug
            // in the export AppleScript command itself
            // (openradar.appspot.com/30389024, first reported 2016, still
            // present), not a problem with this file or this code. No
            // amount of retrying or rephrasing the script fixes it -- the
            // only reliable path is a one-time manual export.
            let menuPath = manualExportMenuPath[appName] ?? "Fichier > Exporter vers..."
            throw ConversionError.automationFailed(
                "\(appName) a refuse d'exporter ce document automatiquement -- c'est un bug connu d'Apple dans l'automatisation de \(appName) (pas un probleme avec ce fichier). Exporte-le une fois toi-meme dans \(appName) (\(menuPath)), puis redemande a Jarvis de lire le fichier texte obtenu."
            )
        }

        guard let data = try? Data(contentsOf: tempFile), let text = String(data: data, encoding: .utf8) else {
            throw ConversionError.automationFailed("Le fichier exporte par \(appName) est illisible.")
        }
        return text
    }

    private static func escapeForAppleScript(_ path: String) -> String {
        path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}
