import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Renders a `ScreenshotSpec` as an inline, interactive image -- same
/// dark-card chrome as `CodeBlockView`/`ChartBlockView`. Click to enlarge
/// (a plain SwiftUI `.sheet`, not `QLPreviewPanel` -- this codebase has no
/// existing QuickLook usage anywhere, and the shared-singleton-panel +
/// data-source/delegate ceremony is disproportionate next to a few lines
/// of SwiftUI that already matches the app's style), copy to the
/// clipboard as a real PNG type, and save to disk.
struct ScreenshotBlockView: View {
    let spec: ScreenshotSpec
    @State private var isEnlarged = false
    @State private var copied = false

    private var image: NSImage? { NSImage(contentsOfFile: spec.path) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Capture d'ecran -- \(Self.dateFormatter.string(from: spec.capturedAt))")
                    .font(.caption2.weight(.bold))
                    .tracking(0.6)
                    .foregroundStyle(.secondary)
                Spacer()
                if image != nil {
                    Button(action: copyToClipboard) {
                        Label(copied ? "Copie" : "Copier", systemImage: copied ? "checkmark" : "doc.on.doc")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(copied ? .green : .secondary)

                    Button(action: saveToDisk) {
                        Label("Enregistrer", systemImage: "square.and.arrow.down")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.white.opacity(0.05))

            Divider().overlay(.white.opacity(0.08))

            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 360, maxHeight: 240)
                    .contentShape(Rectangle())
                    .onTapGesture { isEnlarged = true }
                    .padding(12)
            } else {
                Text("Image indisponible sur cet appareil.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(12)
            }
        }
        .background(Color.black.opacity(0.32), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.white.opacity(0.08), lineWidth: 1))
        .sheet(isPresented: $isEnlarged) {
            if let image {
                EnlargedScreenshotView(image: image, isPresented: $isEnlarged)
            }
        }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "dd/MM/yy HH:mm"
        return formatter
    }()

    private func copyToClipboard() {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: spec.path)) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setData(data, forType: .png)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
    }

    private func saveToDisk() {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: spec.path)) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "capture-\(Int(spec.capturedAt.timeIntervalSince1970)).png"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        try? data.write(to: destination)
    }
}

private struct EnlargedScreenshotView: View {
    let image: NSImage
    @Binding var isPresented: Bool
    @State private var zoom: CGFloat = 1

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button {
                    isPresented = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            .padding(12)

            ScrollView([.horizontal, .vertical]) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .scaleEffect(zoom)
                    .gesture(MagnificationGesture().onChanged { zoom = max(1, min(4, $0)) })
            }
            .padding(.bottom, 12)
        }
        .frame(minWidth: 600, minHeight: 400)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
