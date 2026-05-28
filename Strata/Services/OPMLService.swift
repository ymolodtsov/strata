import Foundation

enum OPMLService {
    enum ParseError: Error {
        case invalidXML
    }

    // MARK: - Parse

    static func parse(data: Data) throws -> OutlineNode {
        let parser = OPMLParser(data: data)
        return try parser.parse()
    }

    // MARK: - Serialize

    static func serialize(root: OutlineNode) -> Data {
        var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
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
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}

// MARK: - XML Parser

private class OPMLParser: NSObject, XMLParserDelegate {
    private let data: Data
    private var root: OutlineNode
    private var nodeStack: [OutlineNode] = []
    private var inBody = false
    private var inHead = false
    private var inTitle = false
    private var titleBuffer = ""

    init(data: Data) {
        self.data = data
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

        var text = attributeDict["text"] ?? ""
        var formatting: [TextFormattingSpan]
        if let json = attributeDict["_strata_formatting"],
           let data = json.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([TextFormattingSpan].self, from: data) {
            formatting = decoded.normalized(forTextLength: (text as NSString).length)
        } else {
            formatting = []
            let converted = Self.convertLegacyMarkdownFormatting(in: text)
            text = converted.text
            formatting = converted.formatting.normalized(forTextLength: (text as NSString).length)
        }
        let note = attributeDict["_note"] ?? ""
        let isDone = attributeDict["_complete"] == "true"
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

    private static func convertLegacyMarkdownFormatting(in input: String) -> (text: String, formatting: [TextFormattingSpan]) {
        var text = input
        var formatting: [TextFormattingSpan] = []

        func apply(_ pattern: String, kind: TextFormattingKind) {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
            let nsText = text as NSString
            let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
            guard !matches.isEmpty else { return }

            for match in matches.reversed() {
                let current = text as NSString
                let contentRange = match.range(at: 1)
                let content = current.substring(with: contentRange)
                let replacementLength = (content as NSString).length
                let removedLength = match.range.length - replacementLength

                text = current.replacingCharacters(in: match.range, with: content)
                formatting = formatting.map { span in
                    var shifted = span
                    if shifted.location >= match.range.location + match.range.length {
                        shifted.location -= removedLength
                    }
                    return shifted
                }
                formatting.append(TextFormattingSpan(kind: kind, location: match.range.location, length: replacementLength))
            }
        }

        apply("\\*\\*(?=\\S)(.+?)(?<=\\S)\\*\\*", kind: .bold)
        apply("==(?=\\S)(.+?)(?<=\\S)==", kind: .highlight)
        apply("(?<!\\*)\\*(?![\\s*])(.+?)(?<![\\s*])\\*(?!\\*)", kind: .italic)

        return (text, formatting.normalized(forTextLength: (text as NSString).length))
    }
}
