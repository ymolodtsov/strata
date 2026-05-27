import Foundation

enum TextFormattingKind: String, Codable, Hashable {
    case bold
    case italic
    case highlight
}

struct TextFormattingSpan: Codable, Hashable {
    var kind: TextFormattingKind
    var location: Int
    var length: Int
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
