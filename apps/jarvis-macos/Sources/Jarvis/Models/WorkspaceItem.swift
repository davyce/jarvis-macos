import Foundation

/// A file or folder Davy has explicitly connected to the conversation --
/// dropped onto the composer, staying "in scope" across turns instead of a
/// one-off content dump. `askLimule()` includes a short preview of each
/// (see `WorkspacePreviewComposer`) so the model can reason about which
/// ones are relevant, then reads the rest on demand via its existing
/// `read_file`/`search_files` tools rather than the whole workspace being
/// pre-loaded into context.
struct WorkspaceItem: Codable, Identifiable, Hashable {
    enum Kind: String, Codable {
        case file
        case folder
    }

    let id: String
    let path: String
    let kind: Kind
    let addedAt: Date

    var name: String { (path as NSString).lastPathComponent }
}
