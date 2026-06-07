import Foundation

enum ExportService {
    private static let maxExportIndent = 64

    // MARK: - Plain Text (tab-indented)

    static func plainText(root: OutlineNode) -> String {
        var lines: [String] = []
        var stack = root.children.reversed().map { (node: $0, indent: 0) }
        while let item = stack.popLast() {
            appendPlainTextLine(item.node, indent: min(item.indent, maxExportIndent), into: &lines)
            for child in item.node.children.reversed() {
                stack.append((child, item.indent + 1))
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func appendPlainTextLine(_ node: OutlineNode, indent: Int, into lines: inout [String]) {
        let prefix = String(repeating: "\t", count: indent)
        let marker = node.isDone ? "[x] " : ""
        lines.append("\(prefix)\(marker)\(node.text)")
        if !node.note.isEmpty {
            for noteLine in node.note.components(separatedBy: .newlines) {
                lines.append("\(prefix)\t\(noteLine)")
            }
        }
    }

    // MARK: - Markdown

    static func markdown(root: OutlineNode) -> String {
        var lines: [String] = []
        // Use root title as heading
        if !root.text.isEmpty {
            lines.append("# \(root.text)")
            lines.append("")
        }
        var stack = root.children.reversed().map { (node: $0, indent: 0) }
        while let item = stack.popLast() {
            appendMarkdownLine(item.node, indent: min(item.indent, maxExportIndent), into: &lines)
            for child in item.node.children.reversed() {
                stack.append((child, item.indent + 1))
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func appendMarkdownLine(_ node: OutlineNode, indent: Int, into lines: inout [String]) {
        let prefix = String(repeating: "  ", count: indent)
        let checkbox = node.isDone ? "- [x] " : "- "
        lines.append("\(prefix)\(checkbox)\(formattedMarkdown(node.text, formatting: node.formatting))")
        if !node.note.isEmpty {
            for noteLine in node.note.components(separatedBy: .newlines) {
                lines.append("\(prefix)  \(noteLine)")
            }
        }
    }

    // MARK: - HTML

    static func html(root: OutlineNode) -> String {
        var html = "<!DOCTYPE html>\n<html>\n<head>\n"
        html += "<meta charset=\"utf-8\">\n"
        html += "<title>\(escapeHTML(root.text))</title>\n"
        html += "<style>\n"
        html += "  body { font-family: -apple-system, system-ui, sans-serif; max-width: 720px; margin: 40px auto; padding: 0 20px; color: #1d1d1f; }\n"
        html += "  h1 { font-size: 24px; font-weight: 600; }\n"
        html += "  ul { padding-left: 24px; }\n"
        html += "  li { margin: 4px 0; }\n"
        html += "  .done { color: #999; text-decoration: line-through; }\n"
        html += "  .note { color: #666; font-size: 0.9em; margin-top: 2px; }\n"
        html += "</style>\n"
        html += "</head>\n<body>\n"
        if !root.text.isEmpty {
            html += "<h1>\(escapeHTML(root.text))</h1>\n"
        }
        if !root.children.isEmpty {
            html += "<ul>\n"
            appendHTMLChildren(root.children, into: &html)
            html += "</ul>\n"
        }
        html += "</body>\n</html>\n"
        return html
    }

    private enum HTMLEvent {
        case node(OutlineNode)
        case closeChildren
        case closeItem
    }

    private static func appendHTMLChildren(_ children: [OutlineNode], into html: inout String) {
        var stack = children.reversed().map { HTMLEvent.node($0) }

        while let event = stack.popLast() {
            switch event {
            case let .node(node):
                let cls = node.isDone ? " class=\"done\"" : ""
                html += "<li\(cls)>\(formattedHTML(node.text, formatting: node.formatting))"
                if !node.note.isEmpty {
                    html += "\n<div class=\"note\">\(escapeHTML(node.note))</div>"
                }
                if node.children.isEmpty {
                    html += "</li>\n"
                } else {
                    html += "\n<ul>\n"
                    stack.append(.closeItem)
                    stack.append(.closeChildren)
                    for child in node.children.reversed() {
                        stack.append(.node(child))
                    }
                }
            case .closeChildren:
                html += "</ul>\n"
            case .closeItem:
                html += "</li>\n"
            }
        }
    }

    private static func escapeHTML(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func formattedMarkdown(_ text: String, formatting: [TextFormattingSpan]) -> String {
        renderFormatted(text, formatting: formatting) { segment, spans in
            var output = segment
            for span in spans {
                switch span.kind {
                case .bold:
                    output = "**\(output)**"
                case .italic:
                    output = "*\(output)*"
                case .underline:
                    output = "<u>\(output)</u>"
                case .highlight:
                    output = "==\(output)=="
                case .link:
                    guard let url = span.url, !url.isEmpty else { break }
                    output = "[\(output)](\(url))"
                }
            }
            return output
        }
    }

    private static func formattedHTML(_ text: String, formatting: [TextFormattingSpan]) -> String {
        renderFormatted(text, formatting: formatting) { segment, spans in
            var output = escapeHTML(segment)
            for span in spans {
                switch span.kind {
                case .bold:
                    output = "<strong>\(output)</strong>"
                case .italic:
                    output = "<em>\(output)</em>"
                case .underline:
                    output = "<u>\(output)</u>"
                case .highlight:
                    output = "<mark>\(output)</mark>"
                case .link:
                    guard let url = span.url, !url.isEmpty else { break }
                    output = "<a href=\"\(escapeHTML(url))\">\(output)</a>"
                }
            }
            return output
        }
    }

    private static func renderFormatted(
        _ text: String,
        formatting: [TextFormattingSpan],
        renderSegment: (String, [TextFormattingSpan]) -> String
    ) -> String {
        let nsText = text as NSString
        let textLength = nsText.length
        let spans = formatting.normalized(forTextLength: textLength)
        guard !spans.isEmpty, textLength > 0 else {
            return renderSegment(text, [])
        }

        var boundaries: Set<Int> = [0, textLength]
        for span in spans {
            boundaries.insert(span.location)
            boundaries.insert(span.location + span.length)
        }

        let sortedBoundaries = boundaries.sorted()
        var output = ""
        var activeSpans: [TextFormattingSpan] = []
        var nextSpanIndex = 0

        for index in 0..<(sortedBoundaries.count - 1) {
            let start = sortedBoundaries[index]
            let end = sortedBoundaries[index + 1]
            guard end > start else { continue }

            activeSpans.removeAll { $0.location + $0.length <= start }
            while nextSpanIndex < spans.count, spans[nextSpanIndex].location <= start {
                activeSpans.append(spans[nextSpanIndex])
                nextSpanIndex += 1
            }

            let segment = nsText.substring(with: NSRange(location: start, length: end - start))
            let segmentSpans = activeSpans
                .filter { $0.location + $0.length >= end }
                .sorted { lhs, rhs in
                    formattingSortOrder(lhs.kind) < formattingSortOrder(rhs.kind)
                }
            output += renderSegment(segment, segmentSpans)
        }

        return output
    }

    private static func formattingSortOrder(_ kind: TextFormattingKind) -> Int {
        switch kind {
        case .bold: return 0
        case .italic: return 1
        case .underline: return 2
        case .highlight: return 3
        case .link: return 4
        }
    }
}
