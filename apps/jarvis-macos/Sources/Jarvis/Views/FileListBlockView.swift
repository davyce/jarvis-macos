import AppKit
import SwiftUI

/// Renders a `FileListSpec` (search results) as an interactive list --
/// same dark-card chrome as `CodeBlockView`/`ChartBlockView`. Each row can
/// be revealed in the Finder or opened directly, giving "present results
/// in chat" real interactivity instead of a wall of plain paths.
struct FileListBlockView: View {
    let spec: FileListSpec

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("\(spec.entries.count) resultat(s) pour \u{201C}\(spec.query)\u{201D}")
                    .font(.caption2.weight(.bold))
                    .tracking(0.6)
                    .foregroundStyle(.secondary)
                Spacer()
                if spec.truncated {
                    Text("liste tronquee")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.white.opacity(0.05))

            Divider().overlay(.white.opacity(0.08))

            if spec.entries.isEmpty {
                Text("Aucun resultat.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(12)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(spec.entries.enumerated()), id: \.offset) { index, entry in
                        FileListRow(entry: entry)
                        if index < spec.entries.count - 1 {
                            Divider().overlay(.white.opacity(0.06))
                        }
                    }
                }
            }
        }
        .background(Color.black.opacity(0.32), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.white.opacity(0.08), lineWidth: 1))
    }
}

private struct FileListRow: View {
    let entry: FileListSpec.Entry

    private var url: URL { URL(fileURLWithPath: entry.path) }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: entry.isDirectory ? "folder" : "doc")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(url.lastPathComponent)
                    .font(.callout.weight(.medium))
                Text(entry.path)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            if let modifiedAt = entry.modifiedAt {
                Text(Self.dateFormatter.string(from: modifiedAt))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Afficher dans le Finder")

            Button {
                NSWorkspace.shared.open(url)
            } label: {
                Image(systemName: "arrow.up.forward.square")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Ouvrir")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "dd/MM/yy HH:mm"
        return formatter
    }()
}
