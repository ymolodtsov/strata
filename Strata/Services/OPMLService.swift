import Foundation

enum OPMLService {
    enum ParseError: Error {
        case invalidXML
    }

    enum ParseMode {
        case standard
        case workflowy
    }

    // MARK: - Parse

    static func parse(data: Data) throws -> OutlineNode {
        try parse(data: data, mode: .standard)
    }

    static func parse(data: Data, mode: ParseMode) throws -> OutlineNode {
        let parser = OPMLParser(data: data, mode: mode)
        return try parser.parse()
    }

    // MARK: - Serialize

    static func serialize(root: OutlineNode) -> Data {
        var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        xml.reserveCapacity(max(4_096, estimatedSerializedSize(root: root)))
        xml += "<opml version=\"2.0\">\n"
        xml += "  <head>\n"
        xml += "    <title>\(escapeXML(root.text))</title>\n"
        xml += "  </head>\n"
        xml += "  <body>\n"
        for child in root.children {
            serializeNode(child, indent: 2, into: &xml)
        }
        xml += "  </body>\n"
        xml += "</opml>\n"
        return xml.data(using: .utf8) ?? Data()
    }

    private static func estimatedSerializedSize(root: OutlineNode) -> Int {
        var total = 160 + root.text.utf8.count

        func visit(_ node: OutlineNode, depth: Int) {
            total += 64 + (depth * 4) + node.text.utf8.count + node.note.utf8.count
            total += node.formatting.count * 80
            for child in node.children {
                visit(child, depth: depth + 1)
            }
        }

        for child in root.children {
            visit(child, depth: 2)
        }

        return total
    }

    private static func serializeNode(_ node: OutlineNode, indent: Int, into xml: inout String) {
        guard !isEmptyLeaf(node) else { return }

        let pad = String(repeating: "  ", count: indent)
        var attrs = "text=\"\(escapeXML(node.text))\""

        let formatting = node.formatting.normalized(forTextLength: (node.text as NSString).length)
        if !formatting.isEmpty,
           let data = try? JSONEncoder().encode(formatting),
           let json = String(data: data, encoding: .utf8) {
            attrs += " _strata_formatting=\"\(escapeXML(json))\""
        }
        if !node.note.isEmpty {
            attrs += " _note=\"\(escapeXML(node.note))\""
        }
        if node.isDone {
            attrs += " _complete=\"true\""
        }
        if !node.isExpanded && !node.children.isEmpty {
            attrs += " _collapsed=\"true\""
        }

        if node.children.isEmpty {
            xml += "\(pad)<outline \(attrs)/>\n"
        } else {
            xml += "\(pad)<outline \(attrs)>\n"
            for child in node.children {
                serializeNode(child, indent: indent + 1, into: &xml)
            }
            xml += "\(pad)</outline>\n"
        }
    }

    private static func isEmptyLeaf(_ node: OutlineNode) -> Bool {
        node.text.isEmpty &&
        node.note.isEmpty &&
        node.formatting.isEmpty &&
        node.children.isEmpty &&
        !node.isDone
    }

    private static func escapeXML(_ string: String) -> String {
        guard string.rangeOfCharacter(from: xmlEscapedCharacters) != nil else {
            return string
        }

        return string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    private static let xmlEscapedCharacters = CharacterSet(charactersIn: "&<>\"'")
}

// MARK: - XML Parser

private class OPMLParser: NSObject, XMLParserDelegate {
    private let data: Data
    private let mode: OPMLService.ParseMode
    private var root: OutlineNode
    private var nodeStack: [OutlineNode] = []
    private var inBody = false
    private var inHead = false
    private var inTitle = false
    private var titleBuffer = ""

    init(data: Data, mode: OPMLService.ParseMode) {
        self.data = data
        self.mode = mode
        self.root = OutlineNode(text: "Home")
        super.init()
    }

    func parse() throws -> OutlineNode {
        let parser = XMLParser(data: data)
        parser.delegate = self
        guard parser.parse() else {
            throw parser.parserError ?? OPMLService.ParseError.invalidXML
        }
        // Apply parsed title to root
        if !titleBuffer.isEmpty {
            root.text = titleBuffer
        }
        return root
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes attributeDict: [String: String] = [:]) {
        if elementName == "head" {
            inHead = true
            return
        }
        if inHead && elementName == "title" {
            inTitle = true
            titleBuffer = ""
            return
        }
        if elementName == "body" {
            inBody = true
            nodeStack = [root]
            return
        }

        guard inBody, elementName == "outline" else { return }

        let importedNodeText = importedText(from: attributeDict["text"] ?? "")
        let text = importedNodeText.text
        var formatting: [TextFormattingSpan]
        if let json = attributeDict["_strata_formatting"],
           let data = json.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([TextFormattingSpan].self, from: data) {
            formatting = decoded.normalized(forTextLength: (text as NSString).length)
        } else {
            formatting = importedNodeText.formatting
        }
        let rawNote = attributeDict["_note"] ?? attributeDict["note"] ?? ""
        let note = importedText(from: rawNote).text
        let isDone = isTruthy(attributeDict["_complete"]) ||
            isTruthy(attributeDict["complete"]) ||
            isTruthy(attributeDict["completed"])
        let isCollapsed = attributeDict["_collapsed"] == "true"

        let node = OutlineNode(
            text: text,
            formatting: formatting,
            note: note,
            isDone: isDone,
            isExpanded: !isCollapsed
        )

        if let currentParent = nodeStack.last {
            node.parent = currentParent
            currentParent.children.append(node)
        }

        nodeStack.append(node)
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inTitle {
            titleBuffer += string
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName: String?) {
        if elementName == "title" && inHead {
            inTitle = false
            return
        }
        if elementName == "head" {
            inHead = false
            return
        }
        if elementName == "body" {
            inBody = false
            return
        }
        if inBody && elementName == "outline" {
            nodeStack.removeLast()
        }
    }

    private func importedText(from rawText: String) -> (text: String, formatting: [TextFormattingSpan]) {
        switch mode {
        case .standard:
            return (rawText, [])
        case .workflowy:
            return parseInlineHTMLMarkup(rawText)
        }
    }

    private func isTruthy(_ value: String?) -> Bool {
        guard let value else { return false }
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "true", "yes", "1", "done", "completed":
            return true
        default:
            return false
        }
    }

    private struct OpenFormattingTag {
        let tagName: String
        let kind: TextFormattingKind
        let location: Int
        let url: String?
    }

    private struct ParsedTag {
        let name: String
        let isClosing: Bool
        let isSelfClosing: Bool
        let attributes: [String: String]
    }

    private func parseInlineHTMLMarkup(_ source: String) -> (text: String, formatting: [TextFormattingSpan]) {
        guard source.contains("<") else { return (source, []) }

        var text = ""
        var formatting: [TextFormattingSpan] = []
        var openTags: [OpenFormattingTag] = []
        var index = source.startIndex
        var parsedKnownTag = false

        func currentLocation() -> Int {
            (text as NSString).length
        }

        func appendText(_ segment: Substring) {
            text += String(segment).replacingOccurrences(of: "&nbsp;", with: " ")
        }

        while index < source.endIndex {
            guard let tagStart = source[index...].firstIndex(of: "<") else {
                appendText(source[index...])
                break
            }

            if index < tagStart {
                appendText(source[index..<tagStart])
            }

            guard let tagEnd = source[tagStart...].firstIndex(of: ">") else {
                appendText(source[tagStart...])
                break
            }

            let rawTag = source[source.index(after: tagStart)..<tagEnd]
            if let tag = parseTag(rawTag) {
                if tag.name == "br" {
                    text += "\n"
                    parsedKnownTag = true
                } else {
                    let kinds = formattingKinds(for: tag.name, attributes: tag.attributes)
                    guard !kinds.isEmpty else { continue }
                    parsedKnownTag = true
                    if tag.isClosing {
                        closeTag(named: tag.name, currentLocation: currentLocation(), openTags: &openTags, formatting: &formatting)
                    } else if !tag.isSelfClosing {
                        for kind in kinds {
                            openTags.append(OpenFormattingTag(
                                tagName: tag.name,
                                kind: kind,
                                location: currentLocation(),
                                url: kind == .link ? tag.attributes["href"] : nil
                            ))
                        }
                    }
                }
            } else {
                text += source[tagStart...tagEnd]
            }

            index = source.index(after: tagEnd)
        }

        let endLocation = currentLocation()
        while let openTag = openTags.popLast() {
            appendSpan(openTag, endLocation: endLocation, to: &formatting)
        }

        guard parsedKnownTag else { return (source, []) }
        let textLength = (text as NSString).length
        let normalizedFormatting = formatting
            .filter { !isWorkflowyTagLink($0, in: text) }
            .normalized(forTextLength: textLength)
        return (text, normalizedFormatting)
    }

    private func parseTag(_ rawTag: Substring) -> ParsedTag? {
        var content = rawTag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty,
              !content.hasPrefix("!"),
              !content.hasPrefix("?") else { return nil }

        let isClosing = content.hasPrefix("/")
        if isClosing {
            content.removeFirst()
            content = content.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let isSelfClosing = content.hasSuffix("/")
        if isSelfClosing {
            content.removeLast()
            content = content.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard let nameEnd = content.firstIndex(where: { $0.isWhitespace || $0 == "/" }) else {
            return ParsedTag(name: content.lowercased(), isClosing: isClosing, isSelfClosing: isSelfClosing, attributes: [:])
        }

        let name = String(content[..<nameEnd]).lowercased()
        let attributeSource = String(content[nameEnd...])
        return ParsedTag(
            name: name,
            isClosing: isClosing,
            isSelfClosing: isSelfClosing,
            attributes: parseAttributes(attributeSource)
        )
    }

    private func parseAttributes(_ source: String) -> [String: String] {
        var attributes: [String: String] = [:]
        var index = source.startIndex

        func skipWhitespace() {
            while index < source.endIndex, source[index].isWhitespace {
                index = source.index(after: index)
            }
        }

        while index < source.endIndex {
            skipWhitespace()
            let keyStart = index
            while index < source.endIndex,
                  !source[index].isWhitespace,
                  source[index] != "=" {
                index = source.index(after: index)
            }
            guard keyStart < index else { break }
            let key = String(source[keyStart..<index]).lowercased()
            skipWhitespace()
            guard index < source.endIndex, source[index] == "=" else {
                attributes[key] = ""
                continue
            }
            index = source.index(after: index)
            skipWhitespace()
            guard index < source.endIndex else {
                attributes[key] = ""
                break
            }

            let value: String
            if source[index] == "\"" || source[index] == "'" {
                let quote = source[index]
                index = source.index(after: index)
                let valueStart = index
                while index < source.endIndex, source[index] != quote {
                    index = source.index(after: index)
                }
                value = String(source[valueStart..<index])
                if index < source.endIndex {
                    index = source.index(after: index)
                }
            } else {
                let valueStart = index
                while index < source.endIndex, !source[index].isWhitespace {
                    index = source.index(after: index)
                }
                value = String(source[valueStart..<index])
            }
            attributes[key] = value
        }

        return attributes
    }

    private func formattingKinds(for tagName: String, attributes: [String: String]) -> [TextFormattingKind] {
        switch tagName {
        case "b", "strong":
            return [.bold]
        case "i", "em":
            return [.italic]
        case "u":
            return [.underline]
        case "mark":
            return [.highlight]
        case "span":
            let style = attributes["style"]?.lowercased() ?? ""
            let cssClass = attributes["class"]?.lowercased() ?? ""
            var kinds: [TextFormattingKind] = []
            if style.contains("font-weight") && (style.contains("bold") || style.contains("700")) {
                kinds.append(.bold)
            }
            if style.contains("font-style") && style.contains("italic") {
                kinds.append(.italic)
            }
            if style.contains("text-decoration") && style.contains("underline") {
                kinds.append(.underline)
            }
            if style.contains("background") || cssClass.contains("highlight") {
                kinds.append(.highlight)
            }
            return kinds
        case "a":
            return attributes["href"] == nil ? [] : [.link]
        default:
            return []
        }
    }

    private func closeTag(
        named tagName: String,
        currentLocation: Int,
        openTags: inout [OpenFormattingTag],
        formatting: inout [TextFormattingSpan]
    ) {
        var didCloseTrailingTags = false
        while let openTag = openTags.last, openTag.tagName == tagName {
            appendSpan(openTags.removeLast(), endLocation: currentLocation, to: &formatting)
            didCloseTrailingTags = true
        }
        if didCloseTrailingTags { return }

        guard let index = openTags.lastIndex(where: { $0.tagName == tagName }) else { return }
        let openTag = openTags.remove(at: index)
        appendSpan(openTag, endLocation: currentLocation, to: &formatting)
    }

    private func appendSpan(
        _ openTag: OpenFormattingTag,
        endLocation: Int,
        to formatting: inout [TextFormattingSpan]
    ) {
        let length = endLocation - openTag.location
        guard length > 0 else { return }
        formatting.append(TextFormattingSpan(
            kind: openTag.kind,
            location: openTag.location,
            length: length,
            url: openTag.url
        ))
    }

    private func isWorkflowyTagLink(_ span: TextFormattingSpan, in text: String) -> Bool {
        guard span.kind == .link else { return false }
        let textLength = (text as NSString).length
        guard span.location >= 0,
              span.length > 1,
              span.location + span.length <= textLength else { return false }

        let value = (text as NSString).substring(with: NSRange(location: span.location, length: span.length))
        guard value.first == "#" || value.first == "@" else { return false }
        return value.rangeOfCharacter(from: .whitespacesAndNewlines) == nil
    }

}
