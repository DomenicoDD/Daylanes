import AppKit
import SwiftUI

/// Diary text as light Markdown: paragraphs split by blank lines, `- ` / `* ` / `1. ` lists, and inline
/// **bold**, *italics*, `code` and [links](https://…). Anything else shows as written.
struct DiaryMarkdown: View {
    let text: String
    var size: CGFloat = 14

    /// The reading measure: 65 characters of the body font, measured on "0" like CSS's `ch`.
    static func measure(size: CGFloat = 14) -> CGFloat {
        let zero = ("0" as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: size)]).width
        return (zero * 65).rounded()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(DiaryMarkdown.blocks(text).enumerated()), id: \.offset) { _, block in
                switch block {
                case let .paragraph(line):
                    inline(line)
                case let .item(marker, line):
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(marker).foregroundStyle(Theme.secondary).monospacedDigit()
                            .frame(minWidth: 10, alignment: .leading)
                        inline(line)
                    }
                }
            }
        }
        .font(.system(size: size))
        .lineSpacing(4)
        .foregroundStyle(Theme.text)
        .textSelection(.enabled)
    }

    private func inline(_ line: String) -> some View {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        let attributed = (try? AttributedString(markdown: line, options: options)) ?? AttributedString(line)
        return Text(attributed).fixedSize(horizontal: false, vertical: true)
    }

    enum Block: Equatable {
        case paragraph(String)
        case item(String, String)
    }

    /// Lines that start a list item become their own block; other consecutive lines join one paragraph.
    static func blocks(_ text: String) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []
        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))) }
            paragraph = []
        }
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                flush()
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("• ") {
                flush()
                blocks.append(.item("•", String(line.dropFirst(2))))
            } else if let dot = line.firstIndex(of: "."), line[..<dot].allSatisfy(\.isNumber), !line[..<dot].isEmpty,
                      line[line.index(after: dot)...].hasPrefix(" ") {
                flush()
                blocks.append(.item(String(line[...dot]), String(line[line.index(dot, offsetBy: 2)...])))
            } else if line.hasPrefix("#") {
                flush()
                blocks.append(.paragraph("**" + line.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces) + "**"))
            } else {
                paragraph.append(line)
            }
        }
        flush()
        return blocks
    }
}
