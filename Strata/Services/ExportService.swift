import Foundation

enum ExportService {

    // MARK: - Plain Text (tab-indented)

    static func plainText(root: OutlineNode) -> String {
        var lines: [String] = []
        for child in root.children {
            appendPlainText(child, indent: 0, into: &lines)
        }
        return lines.joined(separator: "\n")
    }

    private static func appendPlainText(_ node: OutlineNode, indent: Int, into lines: inout [String]) {
        let prefix = String(repeating: "\t", count: indent)
        let marker = node.isDone ? "[x] " : ""
        lines.append("\(prefix)\(marker)\(node.text)")
        if !node.note.isEmpty {
            for noteLine in node.note.components(separatedBy: .newlines) {
                lines.append("\(prefix)\t\(noteLine)")
            }
        }
        for child in node.children {
            appendPlainText(child, indent: indent + 1, into: &lines)
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
        for child in root.children {
            appendMarkdown(child, indent: 0, into: &lines)
        }
        return lines.joined(separator: "\n")
    }

    private static func appendMarkdown(_ node: OutlineNode, indent: Int, into lines: inout [String]) {
        let prefix = String(repeating: "  ", count: indent)
        let checkbox = node.isDone ? "- [x] " : "- "
        lines.append("\(prefix)\(checkbox)\(formattedMarkdown(node.text, formatting: node.formatting))")
        if !node.note.isEmpty {
            for noteLine in node.note.components(separatedBy: .newlines) {
                lines.append("\(prefix)  \(noteLine)")
            }
        }
        for child in node.children {
            appendMarkdown(child, indent: indent + 1, into: &lines)
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
            for child in root.children {
                appendHTML(child, into: &html)
            }
            html += "</ul>\n"
        }
        html += "</body>\n</html>\n"
        return html
    }

    private static func appendHTML(_ node: OutlineNode, into html: inout String) {
        let cls = node.isDone ? " class=\"done\"" : ""
        html += "<li\(cls)>\(formattedHTML(node.text, formatting: node.formatting))"
        if !node.note.isEmpty {
            html += "\n<div class=\"note\">\(escapeHTML(node.note))</div>"
        }
        if !node.children.isEmpty {
            html += "\n<ul>\n"
            for child in node.children {
                appendHTML(child, into: &html)
            }
            html += "</ul>\n"
        }
        html += "</li>\n"
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

        for index in 0..<(sortedBoundaries.count - 1) {
            let start = sortedBoundaries[index]
            let end = sortedBoundaries[index + 1]
            guard end > start else { continue }

            let segment = nsText.substring(with: NSRange(location: start, length: end - start))
            let activeSpans = spans
                .filter { $0.location <= start && $0.location + $0.length >= end }
                .sorted { lhs, rhs in
                    formattingSortOrder(lhs.kind) < formattingSortOrder(rhs.kind)
                }
            output += renderSegment(segment, activeSpans)
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
