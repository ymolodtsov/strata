import Foundation

enum TextFormattingKind: String, Codable, Hashable {
    case bold
    case italic
    case highlight
    case link
}

struct TextFormattingSpan: Codable, Hashable {
    var kind: TextFormattingKind
    var location: Int
    var length: Int
    var url: String? = nil
}

extension Array where Element == TextFormattingSpan {
    func normalized(forTextLength textLength: Int) -> [TextFormattingSpan] {
        guard textLength > 0 else { return [] }

        return compactMap { span in
            let location = Swift.max(0, Swift.min(span.location, textLength))
            let end = Swift.max(location, Swift.min(span.location + span.length, textLength))
            let length = end - location
            guard length > 0 else { return nil }
            return TextFormattingSpan(kind: span.kind, location: location, length: length, url: span.url)
        }
        .sorted {
            if $0.location == $1.location {
                return $0.kind.rawValue < $1.kind.rawValue
            }
            return $0.location < $1.location
        }
    }

    func offset(by offset: Int, textLength: Int) -> [TextFormattingSpan] {
        map {
            TextFormattingSpan(kind: $0.kind, location: $0.location + offset, length: $0.length, url: $0.url)
        }
        .normalized(forTextLength: textLength)
    }

    func split(at offset: Int, textLength: Int) -> (before: [TextFormattingSpan], after: [TextFormattingSpan]) {
        let safeOffset = Swift.max(0, Swift.min(offset, textLength))
        let spans = normalized(forTextLength: textLength)
        var before: [TextFormattingSpan] = []
        var after: [TextFormattingSpan] = []

        for span in spans {
            let start = span.location
            let end = span.location + span.length

            if end <= safeOffset {
                before.append(span)
            } else if start >= safeOffset {
                after.append(TextFormattingSpan(
                    kind: span.kind,
                    location: start - safeOffset,
                    length: span.length,
                    url: span.url
                ))
            } else {
                let beforeLength = safeOffset - start
                let afterLength = end - safeOffset
                if beforeLength > 0 {
                    before.append(TextFormattingSpan(
                        kind: span.kind,
                        location: start,
                        length: beforeLength,
                        url: span.url
                    ))
                }
                if afterLength > 0 {
                    after.append(TextFormattingSpan(
                        kind: span.kind,
                        location: 0,
                        length: afterLength,
                        url: span.url
                    ))
                }
            }
        }

        return (
            before.normalized(forTextLength: safeOffset),
            after.normalized(forTextLength: textLength - safeOffset)
        )
    }
}

@Observable
class OutlineNode: Identifiable {
    let id: UUID
    var text: String
    var formatting: [TextFormattingSpan]
    var note: String
    var isDone: Bool
    var isExpanded: Bool
    var children: [OutlineNode]
    weak var parent: OutlineNode?

    init(
        id: UUID = UUID(),
        text: String = "",
        formatting: [TextFormattingSpan] = [],
        note: String = "",
        isDone: Bool = false,
        isExpanded: Bool = true,
        children: [OutlineNode] = []
    ) {
        self.id = id
        self.text = text
        self.formatting = formatting
        self.note = note
        self.isDone = isDone
        self.isExpanded = isExpanded
        self.children = children
        for child in children {
            child.parent = self
        }
    }

    func setDone(_ done: Bool) {
        isDone = done
        for child in children {
            child.setDone(done)
        }
    }

    func toggleDone() {
        setDone(!isDone)
    }

    func find(id targetId: UUID) -> OutlineNode? {
        if self.id == targetId { return self }
        for child in children {
            if let found = child.find(id: targetId) { return found }
        }
        return nil
    }

    func indexOfChild(_ childId: UUID) -> Int? {
        children.firstIndex(where: { $0.id == childId })
    }

    /// Deep copy preserving all IDs (for undo snapshots)
    func snapshot() -> OutlineNode {
        let copy = OutlineNode(
            id: id,
            text: text,
            formatting: formatting,
            note: note,
            isDone: isDone,
            isExpanded: isExpanded
        )
        copy.children = children.map { child in
            let childCopy = child.snapshot()
            childCopy.parent = copy
            return childCopy
        }
        return copy
    }

    /// Deep copy with new IDs
    func deepCopy() -> OutlineNode {
        let copy = OutlineNode(
            id: UUID(),
            text: text,
            formatting: formatting,
            note: note,
            isDone: isDone,
            isExpanded: isExpanded
        )
        copy.children = children.map { child in
            let childCopy = child.deepCopy()
            childCopy.parent = copy
            return childCopy
        }
        return copy
    }
}
