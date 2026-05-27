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
        lines.append("\(prefix)\(checkbox)\(node.text)")
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
        html += "<li\(cls)>\(escapeHTML(node.text))"
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
}
