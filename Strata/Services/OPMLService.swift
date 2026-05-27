import Foundation

enum OPMLService {

    // MARK: - Parse

    static func parse(data: Data) throws -> OutlineNode {
        let parser = OPMLParser(data: data)
        return parser.parse()
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
        let pad = String(repeating: "  ", count: indent)
        var attrs = "text=\"\(escapeXML(node.text))\""

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

    func parse() -> OutlineNode {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
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

        let text = attributeDict["text"] ?? ""
        let note = attributeDict["_note"] ?? ""
        let isDone = attributeDict["_complete"] == "true"
        let isCollapsed = attributeDict["_collapsed"] == "true"

        let node = OutlineNode(
            text: text,
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
}
