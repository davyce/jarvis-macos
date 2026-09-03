import AppKit
import SwiftUI

/// Renders a chat message line by line so Jarvis never shows raw "**"/"```"
/// characters: inline bold/italic/strikethrough/code render as real styling,
/// "# " lines become headings, and fenced code blocks get a dedicated,
/// copyable code view instead of flowing inline text.
///
/// Deliberately line-based rather than a single full-document markdown parse:
/// Apple's `.full` interpreted syntax merges adjacent lines into list/heading
/// structures that SwiftUI's `Text` cannot visually render (no bullets, no
/// paragraph spacing), which made unrelated lines run together with no break.
struct MarkdownMessageContent: View {
    let text: String
    var baseFont: Font = .body
    var onSelectQuizOption: (String) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(Self.parseBlocks(from: text).enumerated()), id: \.offset) { _, block in
                switch block {
                case .code(let language, let code):
                    CodeBlockView(language: language, code: code)
                        .padding(.vertical, 4)
                case .chart(let spec):
                    ChartBlockView(spec: spec)
                        .padding(.vertical, 4)
                case .fileList(let spec):
                    FileListBlockView(spec: spec)
                        .padding(.vertical, 4)
                case .screenshot(let spec):
                    ScreenshotBlockView(spec: spec)
                        .padding(.vertical, 4)
                case .quiz(let spec):
                    QuizBlockView(spec: spec, onSelectOption: onSelectQuizOption)
                        .padding(.vertical, 4)
                case .rule:
                    Divider().overlay(.white.opacity(0.12)).padding(.vertical, 2)
                case .blank:
                    Spacer().frame(height: 2)
                case .bullet(let content):
                    bulletView(content: content)
                case .numbered(let marker, let content):
                    numberedView(marker: marker, content: content)
                case .quote(let content):
                    quoteView(content: content)
                case .line(let content):
                    lineView(for: content)
                }
            }
        }
    }

    @ViewBuilder
    private func lineView(for line: String) -> some View {
        let (level, strippedHeading) = Self.headingLevel(of: line)
        if let level {
            Text(Self.inline(strippedHeading))
                .font(Self.headingFont(level: level, base: baseFont))
                .foregroundStyle(level <= 2 ? .cyan : .primary)
                .padding(.top, level <= 2 ? 9 : 4)
                .textSelection(.enabled)
        } else {
            Text(Self.inline(line))
                .font(baseFont.leading(.loose))
                .textSelection(.enabled)
        }
    }

    private func bulletView(content: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            Circle().fill(.cyan).frame(width: 5, height: 5)
            Text(Self.inline(content)).font(baseFont.leading(.loose)).textSelection(.enabled)
        }
        .padding(.leading, 4)
    }

    private func numberedView(marker: String, content: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            Text(marker).font(.caption.weight(.bold)).foregroundStyle(.cyan).frame(minWidth: 20, alignment: .trailing)
            Text(Self.inline(content)).font(baseFont.leading(.loose)).textSelection(.enabled)
        }
    }

    private func quoteView(content: String) -> some View {
        Text(Self.inline(content))
            .font(baseFont.italic().leading(.loose))
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .padding(.leading, 12)
            .overlay(alignment: .leading) { Rectangle().fill(.cyan.opacity(0.75)).frame(width: 2) }
            .padding(.vertical, 4)
    }

    private static func headingLevel(of line: String) -> (Int?, String) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        var level = 0
        var idx = trimmed.startIndex
        while idx < trimmed.endIndex, trimmed[idx] == "#", level < 6 {
            level += 1
            idx = trimmed.index(after: idx)
        }
        guard level > 0, idx < trimmed.endIndex, trimmed[idx] == " " else { return (nil, line) }
        return (level, String(trimmed[trimmed.index(after: idx)...]))
    }

    private static func headingFont(level: Int, base: Font) -> Font {
        switch level {
        case 1: return .title2.bold()
        case 2: return .title3.bold()
        default: return base.weight(.bold)
        }
    }

    private static func inline(_ content: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: true,
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        return (try? AttributedString(markdown: content, options: options)) ?? AttributedString(content)
    }

    private enum MessageBlock {
        case code(language: String?, code: String)
        case chart(ChartSpec)
        case fileList(FileListSpec)
        case screenshot(ScreenshotSpec)
        case quiz(QuizSpec)
        case rule
        case blank
        case bullet(String)
        case numbered(marker: String, content: String)
        case quote(String)
        case line(String)
    }

    private static func parseBlocks(from text: String) -> [MessageBlock] {
        var blocks: [MessageBlock] = []
        var inCode = false
        var codeLanguage: String?
        var codeLines: [String] = []

        for rawLine in text.components(separatedBy: "\n") {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                if inCode {
                    let code = codeLines.joined(separator: "\n")
                    if codeLanguage == "chart", let spec = ChartSpec.parse(from: code) {
                        blocks.append(.chart(spec))
                    } else if codeLanguage == "filelist", let spec = FileListSpec.parse(from: code) {
                        blocks.append(.fileList(spec))
                    } else if codeLanguage == "screenshot", let spec = ScreenshotSpec.parse(from: code) {
                        blocks.append(.screenshot(spec))
                    } else if codeLanguage == "quiz", let spec = QuizSpec.parse(from: code) {
                        blocks.append(.quiz(spec))
                    } else {
                        blocks.append(.code(language: codeLanguage, code: code))
                    }
                    codeLines = []
                    codeLanguage = nil
                    inCode = false
                } else {
                    inCode = true
                    let lang = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
                    codeLanguage = lang.isEmpty ? nil : lang
                }
                continue
            }

            if inCode {
                codeLines.append(rawLine)
                continue
            }

            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                blocks.append(.rule)
                continue
            }

            if trimmed.isEmpty {
                blocks.append(.blank)
                continue
            }

            if trimmed.hasPrefix("> ") {
                blocks.append(.quote(String(trimmed.dropFirst(2))))
                continue
            }

            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                blocks.append(.bullet(String(trimmed.dropFirst(2))))
                continue
            }

            if let numbered = numberedLine(trimmed) {
                blocks.append(.numbered(marker: numbered.marker, content: numbered.content))
                continue
            }

            blocks.append(.line(rawLine))
        }

        if inCode {
            blocks.append(.code(language: codeLanguage, code: codeLines.joined(separator: "\n")))
        }

        return blocks
    }

    private static func numberedLine(_ line: String) -> (marker: String, content: String)? {
        guard let dot = line.firstIndex(of: "."), dot > line.startIndex else { return nil }
        let number = line[..<dot]
        guard number.allSatisfy(\.isNumber) else { return nil }
        let afterDot = line.index(after: dot)
        guard afterDot < line.endIndex, line[afterDot] == " " else { return nil }
        return (String(number) + ".", String(line[line.index(after: afterDot)...]))
    }
}

struct CodeBlockView: View {
    let language: String?
    let code: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(languageLabel)
                    .font(.caption2.weight(.bold))
                    .tracking(0.6)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(action: copy) {
                    Label(copied ? "Copie" : "Copier", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(copied ? .green : .secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.white.opacity(0.05))

            Divider().overlay(.white.opacity(0.08))

            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(12)
            }
        }
        .background(Color.black.opacity(0.32), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.white.opacity(0.08), lineWidth: 1))
    }

    private var languageLabel: String {
        guard let language, !language.isEmpty else { return "CODE" }
        return language.uppercased()
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
    }
}
