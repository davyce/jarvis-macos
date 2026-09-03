import AppKit
import Foundation

/// Saves screenshot PNG bytes from LIMULE Bridge to local disk so a chat
/// message can reference them by path (see `ScreenshotSpec`). Stored under
/// Application Support, not Caches -- the path is referenced indefinitely
/// from `CommandEntry.text`, persisted in SQLite; a file the OS is free to
/// purge between launches would produce the same "image missing" gap on
/// the SAME device that cross-device conversation sync already produces
/// across devices. Retention/cleanup is explicitly out of scope: PNGs
/// accumulate here the same way command_history text already accumulates
/// forever with no purge.
enum ScreenshotStore {
    struct SavedScreenshot {
        let path: String
        let width: Int
        let height: Int
    }

    enum StoreError: LocalizedError {
        case invalidImageData
        case writeFailed(String)

        var errorDescription: String? {
            switch self {
            case .invalidImageData:
                return "Les donnees recues ne sont pas une image valide."
            case .writeFailed(let message):
                return "Impossible d'enregistrer la capture d'ecran : \(message)"
            }
        }
    }

    /// Injectable so tests don't write into the user's real Application
    /// Support folder.
    nonisolated(unsafe) static var directory: () -> URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Jarvis", isDirectory: true).appendingPathComponent("Screenshots", isDirectory: true)
    }

    static func save(_ pngData: Data) throws -> SavedScreenshot {
        guard let image = NSImage(data: pngData), let size = image.representations.first.map({ (width: $0.pixelsWide, height: $0.pixelsHigh) }) else {
            throw StoreError.invalidImageData
        }

        let folder = directory()
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            throw StoreError.writeFailed(error.localizedDescription)
        }

        let filename = "\(UUID().uuidString).png"
        let destination = folder.appendingPathComponent(filename)
        do {
            try pngData.write(to: destination)
        } catch {
            throw StoreError.writeFailed(error.localizedDescription)
        }

        return SavedScreenshot(path: destination.path, width: size.width, height: size.height)
    }
}
