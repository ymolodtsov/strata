import Foundation
import AppKit

@Observable
class OutlineStore {
    static let nodePasteboardType = NSPasteboard.PasteboardType("family.ma.strata.nodes")

    /// Weak set of all living OutlineStore instances, used to collect open document
    /// paths for session state persistence on quit.
    static let openStores = NSHashTable<OutlineStore>.weakObjects()

    private struct ClipboardPayload: Codable {
        let nodes: [ClipboardNode]
    }

    private struct ClipboardNode: Codable {
        let text: String
        let formatting: [TextFormattingSpan]
        let note: String
        let isDone: Bool
        let isExpanded: Bool
        let children: [ClipboardNode]

        init(node: OutlineNode) {
            text = node.text
            formatting = node.formatting
            note = node.note
            isDone = node.isDone
            isExpanded = node.isExpanded
            children = node.children.map(ClipboardNode.init)
        }

        func makeOutlineNode() -> OutlineNode {
            OutlineNode(
                text: text,
                formatting: formatting,
                note: note,
                isDone: isDone,
                isExpanded: isExpanded,
                children: children.map { $0.makeOutlineNode() }
            )
        }

        func appendPlainTextLines(to lines: inout [String], depth: Int) {
            let indent = String(repeating: "\t", count: depth)
            lines.append("\(indent)\(text)")
            for child in children {
                child.appendPlainTextLines(to: &lines, depth: depth + 1)
            }
        }
    }

    var root: OutlineNode
    var zoomPath: [UUID] = []
    var pendingFocusId: UUID?
    var pendingCursorPosition: Int?
    var currentFilePath: URL?
    var selectedNodeIds: Set<UUID> = []

    private var saveWorkItem: DispatchWorkItem?
    private var terminateObserver: Any?
    private var resignObserver: Any?

    // MARK: - Undo / Redo

    private struct UndoSnapshot {
        let root: OutlineNode
        let zoomPath: [UUID]
    }

    private var undoStack: [UndoSnapshot] = []
    private var redoStack: [UndoSnapshot] = []
    private var treeModifiedSinceLastSnapshot = true
    private static let maxUndoLevels = 50

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    /// Always saves a snapshot (call before structural operations)
    func saveUndoState() {
        pushUndoSnapshot()
    }

    /// Only saves if the tree changed since the last snapshot (call on begin-editing)
    func saveUndoStateIfModified() {
        guard treeModifiedSinceLastSnapshot else { return }
        pushUndoSnapshot()
    }

    private func pushUndoSnapshot() {
        let snap = UndoSnapshot(root: root.snapshot(), zoomPath: zoomPath)
        undoStack.append(snap)
        if undoStack.count > Self.maxUndoLevels {
            undoStack.removeFirst()
        }
        redoStack.removeAll()
        treeModifiedSinceLastSnapshot = false
    }

    func undo() {
        guard let snap = undoStack.popLast() else { return }
        let current = UndoSnapshot(root: root.snapshot(), zoomPath: zoomPath)
        redoStack.append(current)
        restoreSnapshot(snap)
    }

    func redo() {
        guard let snap = redoStack.popLast() else { return }
        let current = UndoSnapshot(root: root.snapshot(), zoomPath: zoomPath)
        undoStack.append(current)
        restoreSnapshot(snap)
    }

    private func restoreSnapshot(_ snap: UndoSnapshot) {
        root = snap.root
        zoomPath = snap.zoomPath
        selectedNodeIds.removeAll()
        draggedNodeIds.removeAll()
        dropTargetId = nil
        treeModifiedSinceLastSnapshot = false
        pendingFocusId = currentRoot.children.first?.id
        save()
    }

    var documentTitle: String {
        guard let url = currentFilePath else { return "Untitled" }
        if url == Self.defaultFileURL { return "Strata" }
        return url.lastPathComponent
    }

    init() {
        root = OutlineNode(text: "Home", children: [
            OutlineNode(text: "")
        ])
        root.children.first?.parent = root
        Self.openStores.add(self)
        setupSaveOnQuit()
    }

    init(root: OutlineNode) {
        self.root = root
        Self.openStores.add(self)
        setupSaveOnQuit()
    }

    private func setupSaveOnQuit() {
        terminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.saveWorkItem?.cancel()
            self?.save()
        }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.saveWorkItem?.cancel()
            self?.save()
        }
    }

    deinit {
        if let obs = terminateObserver { NotificationCenter.default.removeObserver(obs) }
        if let obs = resignObserver { NotificationCenter.default.removeObserver(obs) }
    }

    var hasSelection: Bool { !selectedNodeIds.isEmpty }

    // MARK: - Zoom

    var currentRoot: OutlineNode {
        var node = root
        for id in zoomPath {
            if let child = node.find(id: id) {
                node = child
            }
        }
        return node
    }

    var breadcrumbs: [(id: UUID, text: String)] {
        // Walk parent chain from currentRoot up to root for a complete path
        var chain: [OutlineNode] = []
        var node: OutlineNode? = currentRoot
        while let n = node {
            chain.append(n)
            if n.id == root.id { break }
            node = n.parent
        }
        chain.reverse()
        return chain.map { n in
            let label = n.text.isEmpty ? (n.id == root.id ? "Home" : "Untitled") : n.text
            return (id: n.id, text: label)
        }
    }

    func zoomIn(nodeId: UUID) {
        guard let node = root.find(id: nodeId) else { return }
        clearSelection()
        zoomPath.append(nodeId)

        if node.children.isEmpty {
            let empty = OutlineNode(text: "")
            empty.parent = node
            node.children.append(empty)
            pendingFocusId = empty.id
        } else {
            pendingFocusId = node.children.first?.id
        }
    }

    /// Remove the empty placeholder child created when zooming into a leaf node
    private func cleanupEmptyZoomChild() {
        let leaving = currentRoot
        if leaving.children.count == 1,
           let only = leaving.children.first,
           only.text.isEmpty && only.children.isEmpty {
            leaving.children.removeAll()
        }
    }

    func zoomOut() {
        guard !zoomPath.isEmpty else { return }
        cleanupEmptyZoomChild()
        clearSelection()
        zoomPath.removeLast()
    }

    func zoomToRoot() {
        cleanupEmptyZoomChild()
        clearSelection()
        zoomPath.removeAll()
    }

    func zoomTo(nodeId: UUID) {
        cleanupEmptyZoomChild()
        clearSelection()
        if nodeId == root.id {
            zoomPath.removeAll()
            return
        }
        // Build path from root to target node via parent chain
        if let target = root.find(id: nodeId) {
            var path: [UUID] = []
            var current: OutlineNode? = target
            while let c = current, c.id != root.id {
                path.append(c.id)
                current = c.parent
            }
            path.reverse()
            zoomPath = path
        }
    }

    private func pruneZoomPath() {
        var validPath: [UUID] = []
        var node = root
        for id in zoomPath {
            if let child = node.find(id: id) {
                validPath.append(id)
                node = child
            } else {
                break
            }
        }
        if validPath.count != zoomPath.count {
            zoomPath = validPath
        }
    }

    // MARK: - Flat visible nodes

    func visibleNodes() -> [(node: OutlineNode, depth: Int)] {
        var result: [(OutlineNode, Int)] = []
        if isSearching {
            let matches = searchMatchingIds(in: currentRoot, query: searchQuery.lowercased())
            for child in currentRoot.children {
                flattenMatching(child, depth: 0, matches: matches, into: &result)
            }
        } else {
            for child in currentRoot.children {
                flattenVisible(child, depth: 0, into: &result)
            }
        }
        return result
    }

    private func flattenVisible(_ node: OutlineNode, depth: Int, into result: inout [(OutlineNode, Int)]) {
        if hideCompleted && node.isDone { return }
        result.append((node, depth))
        if node.isExpanded {
            for child in node.children {
                flattenVisible(child, depth: depth + 1, into: &result)
            }
        }
    }

    private func searchMatchingIds(in root: OutlineNode, query: String) -> Set<UUID> {
        var ids = Set<UUID>()
        searchMatchHelper(root, query: query, ids: &ids)
        return ids
    }

    private func searchMatchHelper(_ node: OutlineNode, query: String, ids: inout Set<UUID>) {
        let textMatch = node.text.lowercased().contains(query)
        let noteMatch = node.note.lowercased().contains(query)
        if textMatch || noteMatch {
            var current: OutlineNode? = node
            while let n = current {
                ids.insert(n.id)
                current = n.parent
            }
        }
        for child in node.children {
            searchMatchHelper(child, query: query, ids: &ids)
        }
    }

    private func flattenMatching(_ node: OutlineNode, depth: Int, matches: Set<UUID>, into result: inout [(OutlineNode, Int)]) {
        guard matches.contains(node.id) else { return }
        if hideCompleted && node.isDone { return }
        result.append((node, depth))
        for child in node.children {
            flattenMatching(child, depth: depth + 1, matches: matches, into: &result)
        }
    }

    func previousVisibleNode(before nodeId: UUID) -> UUID? {
        let nodes = visibleNodes()
        guard let index = nodes.firstIndex(where: { $0.node.id == nodeId }), index > 0 else { return nil }
        return nodes[index - 1].node.id
    }

    func nextVisibleNode(after nodeId: UUID) -> UUID? {
        let nodes = visibleNodes()
        guard let index = nodes.firstIndex(where: { $0.node.id == nodeId }), index < nodes.count - 1 else { return nil }
        return nodes[index + 1].node.id
    }

    // MARK: - Selection

    private var selectionAnchorId: UUID?
    private var selectionCursorId: UUID?

    func selectAllVisible() {
        let nodes = visibleNodes()
        guard !nodes.isEmpty else { return }
        selectedNodeIds = Set(nodes.map { $0.node.id })
        selectionAnchorId = nodes.first?.node.id
        selectionCursorId = nodes.last?.node.id
        NSApp.keyWindow?.makeFirstResponder(nil)
    }

    func clearSelection() {
        selectedNodeIds.removeAll()
        selectionAnchorId = nil
        selectionCursorId = nil
    }

    /// Enter selection mode with a single node selected (e.g. after pressing Escape)
    func selectNode(_ nodeId: UUID) {
        selectedNodeIds = [nodeId]
        selectionAnchorId = nodeId
        selectionCursorId = nodeId
        NSApp.keyWindow?.makeFirstResponder(nil)
    }

    func selectRange(to nodeId: UUID) {
        if selectionAnchorId == nil {
            selectionAnchorId = firstSelectedVisibleNodeId() ?? nodeId
        }
        selectionCursorId = nodeId
        recomputeSelection()
        NSApp.keyWindow?.makeFirstResponder(nil)
    }

    func toggleSelection(nodeId: UUID) {
        if selectedNodeIds.contains(nodeId) {
            selectedNodeIds.remove(nodeId)
            if selectedNodeIds.isEmpty {
                clearSelection()
            } else {
                selectionAnchorId = firstSelectedVisibleNodeId()
                selectionCursorId = nodeId
            }
        } else {
            selectedNodeIds.insert(nodeId)
            selectionAnchorId = nodeId
            selectionCursorId = nodeId
        }
        NSApp.keyWindow?.makeFirstResponder(nil)
    }

    func handleNodeClick(_ nodeId: UUID, modifiers: NSEvent.ModifierFlags) {
        let flags = modifiers.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.shift) {
            selectRange(to: nodeId)
        } else if flags.contains(.command) {
            toggleSelection(nodeId: nodeId)
        } else {
            selectNode(nodeId)
        }
    }

    private func firstSelectedVisibleNodeId() -> UUID? {
        visibleNodes().first(where: { selectedNodeIds.contains($0.node.id) })?.node.id
    }

    /// Start block selection from a text field by pressing Shift+Up
    func startSelectionUp(from nodeId: UUID) {
        let visible = visibleNodes()
        guard let index = visible.firstIndex(where: { $0.node.id == nodeId }),
              index > 0 else { return }

        selectionAnchorId = nodeId
        selectionCursorId = visible[index - 1].node.id
        recomputeSelection()
        NSApp.keyWindow?.makeFirstResponder(nil)
    }

    /// Start block selection from a text field by pressing Shift+Down
    func startSelectionDown(from nodeId: UUID) {
        let visible = visibleNodes()
        guard let index = visible.firstIndex(where: { $0.node.id == nodeId }),
              index < visible.count - 1 else { return }

        selectionAnchorId = nodeId
        selectionCursorId = visible[index + 1].node.id
        recomputeSelection()
        NSApp.keyWindow?.makeFirstResponder(nil)
    }

    /// Extend the selection upward (Shift+Up in selection mode)
    func extendSelectionUp() {
        let visible = visibleNodes()
        guard let cursorId = selectionCursorId,
              let cursorIdx = visible.firstIndex(where: { $0.node.id == cursorId }),
              cursorIdx > 0 else { return }

        selectionCursorId = visible[cursorIdx - 1].node.id
        recomputeSelection()
    }

    /// Extend the selection downward (Shift+Down in selection mode)
    func extendSelectionDown() {
        let visible = visibleNodes()
        guard let cursorId = selectionCursorId,
              let cursorIdx = visible.firstIndex(where: { $0.node.id == cursorId }),
              cursorIdx < visible.count - 1 else { return }

        selectionCursorId = visible[cursorIdx + 1].node.id
        recomputeSelection()
    }

    /// Move single-node selection up (Up arrow in selection mode)
    func moveSelectionUp() {
        let visible = visibleNodes()
        guard let topIdx = visible.indices.first(where: { selectedNodeIds.contains(visible[$0].node.id) }),
              topIdx > 0 else { return }

        let newId = visible[topIdx - 1].node.id
        selectionAnchorId = newId
        selectionCursorId = newId
        selectedNodeIds = [newId]
    }

    /// Move single-node selection down (Down arrow in selection mode)
    func moveSelectionDown() {
        let visible = visibleNodes()
        guard let bottomIdx = visible.indices.last(where: { selectedNodeIds.contains(visible[$0].node.id) }),
              bottomIdx < visible.count - 1 else { return }

        let newId = visible[bottomIdx + 1].node.id
        selectionAnchorId = newId
        selectionCursorId = newId
        selectedNodeIds = [newId]
    }

    /// Exit selection mode and focus the first selected node for editing
    func focusFirstSelected() {
        let visible = visibleNodes()
        if let firstIdx = visible.indices.first(where: { selectedNodeIds.contains(visible[$0].node.id) }) {
            pendingFocusId = visible[firstIdx].node.id
        }
        clearSelection()
    }

    private func recomputeSelection() {
        guard let anchorId = selectionAnchorId,
              let cursorId = selectionCursorId else { return }
        let visible = visibleNodes()
        guard let anchorIdx = visible.firstIndex(where: { $0.node.id == anchorId }),
              let cursorIdx = visible.firstIndex(where: { $0.node.id == cursorId }) else { return }

        let range = min(anchorIdx, cursorIdx)...max(anchorIdx, cursorIdx)
        selectedNodeIds = Set(range.map { visible[$0].node.id })
    }

    func deleteSelected() {
        saveUndoState()
        // Group by parent and sort by descending index to avoid invalidation
        var parentMap: [UUID: [(index: Int, nodeId: UUID)]] = [:]
        for id in selectedNodeIds {
            guard let node = root.find(id: id),
                  let parent = node.parent,
                  !selectedNodeIds.contains(parent.id),
                  let index = parent.indexOfChild(id) else { continue }
            parentMap[parent.id, default: []].append((index, id))
        }

        for (_, entries) in parentMap {
            let sorted = entries.sorted { $0.index > $1.index }
            for entry in sorted {
                if let node = root.find(id: entry.nodeId),
                   let parent = node.parent {
                    if let idx = parent.indexOfChild(entry.nodeId) {
                        parent.children.remove(at: idx)
                    }
                }
            }
        }

        pruneZoomPath()

        let cr = currentRoot
        if cr.children.isEmpty {
            let empty = OutlineNode(text: "")
            empty.parent = cr
            cr.children.append(empty)
            pendingFocusId = empty.id
        } else {
            pendingFocusId = cr.children.first?.id
        }

        clearSelection()
        scheduleSave()
    }

    func toggleDoneSelected() {
        saveUndoState()
        let anyUndone = selectedNodeIds.contains { id in
            root.find(id: id)?.isDone == false
        }
        for id in selectedNodeIds {
            root.find(id: id)?.setDone(anyUndone)
        }
        clearSelection()
        scheduleSave()
    }

    func copySelectedAsText() {
        let nodes = topLevelSelectedNodes()
        guard !nodes.isEmpty else { return }

        let payload = ClipboardPayload(nodes: nodes.map(ClipboardNode.init))
        var lines: [String] = []
        for node in payload.nodes {
            node.appendPlainTextLines(to: &lines, depth: 0)
        }

        NSPasteboard.general.clearContents()
        if let data = try? JSONEncoder().encode(payload) {
            NSPasteboard.general.setData(data, forType: Self.nodePasteboardType)
        }
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }

    private func topLevelSelectedNodes() -> [OutlineNode] {
        visibleNodes().compactMap { item in
            let node = item.node
            guard selectedNodeIds.contains(node.id) else { return nil }

            var ancestor = node.parent
            while let current = ancestor, current.id != root.id {
                if selectedNodeIds.contains(current.id) {
                    return nil
                }
                ancestor = current.parent
            }
            return node
        }
    }

    func moveSelectedUp() {
        let blocks = selectedSiblingBlocks().sorted { $0.firstIndex < $1.firstIndex }
        guard blocks.contains(where: { $0.firstIndex > 0 }) else { return }

        saveUndoState()
        var changed = false
        for block in blocks where block.firstIndex > 0 {
            moveSiblingBlock(block, to: block.firstIndex - 1)
            changed = true
        }

        if changed {
            scheduleSave()
        }
    }

    func moveSelectedDown() {
        let blocks = selectedSiblingBlocks().sorted { $0.firstIndex > $1.firstIndex }
        guard blocks.contains(where: { $0.lastIndex < $0.parent.children.count - 1 }) else { return }

        saveUndoState()
        var changed = false
        for block in blocks where block.lastIndex < block.parent.children.count - 1 {
            moveSiblingBlock(block, to: block.firstIndex + 1)
            changed = true
        }

        if changed {
            scheduleSave()
        }
    }

    private struct SelectedSiblingBlock {
        let parent: OutlineNode
        let nodes: [OutlineNode]
        let firstIndex: Int
        let lastIndex: Int
    }

    private func selectedSiblingBlocks() -> [SelectedSiblingBlock] {
        let selected = topLevelSelectedNodes()
        guard !selected.isEmpty else { return [] }

        var entriesByParent: [UUID: (parent: OutlineNode, entries: [(index: Int, node: OutlineNode)])] = [:]
        for node in selected {
            guard let parent = node.parent,
                  let index = parent.indexOfChild(node.id) else { continue }
            entriesByParent[parent.id, default: (parent, [])].entries.append((index, node))
        }

        var blocks: [SelectedSiblingBlock] = []
        for (_, group) in entriesByParent {
            let entries = group.entries.sorted { $0.index < $1.index }
            var current: [(index: Int, node: OutlineNode)] = []

            for entry in entries {
                if let previous = current.last, entry.index != previous.index + 1 {
                    blocks.append(makeSelectedSiblingBlock(parent: group.parent, entries: current))
                    current.removeAll()
                }
                current.append(entry)
            }

            if !current.isEmpty {
                blocks.append(makeSelectedSiblingBlock(parent: group.parent, entries: current))
            }
        }

        return blocks
    }

    private func makeSelectedSiblingBlock(
        parent: OutlineNode,
        entries: [(index: Int, node: OutlineNode)]
    ) -> SelectedSiblingBlock {
        SelectedSiblingBlock(
            parent: parent,
            nodes: entries.map(\.node),
            firstIndex: entries[0].index,
            lastIndex: entries[entries.count - 1].index
        )
    }

    private func moveSiblingBlock(_ block: SelectedSiblingBlock, to destinationIndex: Int) {
        for node in block.nodes.reversed() {
            if let index = block.parent.indexOfChild(node.id) {
                block.parent.children.remove(at: index)
            }
        }

        let safeIndex = min(max(destinationIndex, 0), block.parent.children.count)
        for (offset, node) in block.nodes.enumerated() {
            node.parent = block.parent
            block.parent.children.insert(node, at: min(safeIndex + offset, block.parent.children.count))
        }
    }

    // MARK: - Cut / Paste

    func cutSelected() {
        copySelectedAsText()
        deleteSelected() // already saves undo state
    }

    func pasteNodes(after nodeId: UUID) {
        if pasteOutlineNodes(after: nodeId) {
            return
        }

        guard let pasteText = NSPasteboard.general.string(forType: .string),
              !pasteText.isEmpty,
              let refNode = root.find(id: nodeId),
              let refParent = refNode.parent,
              let refIndex = refParent.indexOfChild(nodeId) else { return }

        let topLevel = nodesFromPlainText(pasteText)
        guard !topLevel.isEmpty else { return }

        saveUndoState()
        insertNodes(topLevel, into: refParent, at: refIndex + 1)
        scheduleSave()
    }

    @discardableResult
    private func pasteOutlineNodes(after nodeId: UUID) -> Bool {
        guard let refNode = root.find(id: nodeId),
              let refParent = refNode.parent,
              let refIndex = refParent.indexOfChild(nodeId),
              let data = NSPasteboard.general.data(forType: Self.nodePasteboardType),
              let payload = try? JSONDecoder().decode(ClipboardPayload.self, from: data) else { return false }

        let topLevel = payload.nodes.map { $0.makeOutlineNode() }
        guard !topLevel.isEmpty else { return false }

        saveUndoState()
        insertNodes(topLevel, into: refParent, at: refIndex + 1)
        scheduleSave()
        return true
    }

    private func nodesFromPlainText(_ pasteText: String) -> [OutlineNode] {
        let lines = pasteText.components(separatedBy: .newlines)
        var items: [(text: String, indent: Int)] = []
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            var indent = 0
            var spaces = 0
            for char in line {
                if char == "\t" { indent += 1; spaces = 0 }
                else if char == " " { spaces += 1; if spaces >= 4 { indent += 1; spaces = 0 } }
                else { break }
            }
            items.append((trimmed, indent))
        }

        guard !items.isEmpty else { return [] }

        let baseIndent = items[0].indent
        items = items.map { ($0.text, max(0, $0.indent - baseIndent)) }

        var stack: [(OutlineNode, Int)] = []
        var topLevel: [OutlineNode] = []

        for item in items {
            let newNode = OutlineNode(text: item.text)
            while let last = stack.last, last.1 >= item.indent {
                stack.removeLast()
            }
            if let parentEntry = stack.last {
                newNode.parent = parentEntry.0
                parentEntry.0.children.append(newNode)
                parentEntry.0.isExpanded = true
            } else {
                topLevel.append(newNode)
            }
            stack.append((newNode, item.indent))
        }

        return topLevel
    }

    private func insertNodes(_ topLevel: [OutlineNode], into parent: OutlineNode, at index: Int) {
        for (offset, node) in topLevel.enumerated() {
            node.parent = parent
            parent.children.insert(node, at: min(index + offset, parent.children.count))
        }
        if let last = topLevel.last {
            pendingFocusId = last.id
        }
    }

    func pasteAfterSelection() {
        let visible = visibleNodes()
        if let lastIdx = visible.indices.last(where: { selectedNodeIds.contains(visible[$0].node.id) }) {
            let afterId = visible[lastIdx].node.id
            clearSelection()
            pasteNodes(after: afterId)
        } else if let last = visible.last {
            pasteNodes(after: last.node.id)
        }
    }

    func pasteAfterFocused() {
        // Paste after the first visible node (fallback when no focus info)
        if let first = visibleNodes().first {
            pasteNodes(after: first.node.id)
        }
    }

    // MARK: - Search

    var isSearchActive = false
    var searchQuery = ""
    var isSearching: Bool { isSearchActive && !searchQuery.isEmpty }

    // MARK: - Notes

    var editingNoteId: UUID?

    func toggleNote(nodeId: UUID) {
        if editingNoteId == nodeId {
            editingNoteId = nil
        } else {
            editingNoteId = nodeId
        }
    }

    // MARK: - Settings

    var hideCompleted = false

    // MARK: - Drag and Drop

    var draggedNodeIds: Set<UUID> = []
    var dropTargetId: UUID?
    var dropAbove: Bool = true

    func beginDrag(nodeId: UUID) {
        if selectedNodeIds.contains(nodeId) {
            draggedNodeIds = selectedNodeIds
        } else {
            clearSelection()
            draggedNodeIds = [nodeId]
        }
    }

    func endDrag() {
        draggedNodeIds.removeAll()
        dropTargetId = nil
    }

    func canDrop(on targetId: UUID) -> Bool {
        guard !draggedNodeIds.isEmpty else { return false }

        for id in draggedNodeIds {
            if id == targetId { return false }
            if let node = root.find(id: id), node.find(id: targetId) != nil {
                return false
            }
        }

        return true
    }

    func performDrop() -> Bool {
        guard let targetId = dropTargetId, !draggedNodeIds.isEmpty else {
            endDrag()
            return false
        }

        guard canDrop(on: targetId) else {
            endDrag()
            return false
        }

        // Collect top-level dragged nodes in visible order (skip children of other dragged nodes)
        let visible = visibleNodes()
        var topLevel: [OutlineNode] = []
        for item in visible {
            guard draggedNodeIds.contains(item.node.id) else { continue }
            var isDescendant = false
            var ancestor = item.node.parent
            while let a = ancestor, a.id != root.id {
                if draggedNodeIds.contains(a.id) { isDescendant = true; break }
                ancestor = a.parent
            }
            if !isDescendant {
                topLevel.append(item.node)
            }
        }

        guard !topLevel.isEmpty else { endDrag(); return false }

        saveUndoState()

        // Remove from old parents
        for node in topLevel {
            if let parent = node.parent, let idx = parent.indexOfChild(node.id) {
                parent.children.remove(at: idx)
            }
        }

        // Re-find target after removals and insert
        guard let target = root.find(id: targetId),
              let targetParent = target.parent,
              let targetIdx = targetParent.indexOfChild(targetId) else {
            endDrag()
            return false
        }

        let insertIdx = dropAbove ? targetIdx : targetIdx + 1
        for (offset, node) in topLevel.enumerated() {
            node.parent = targetParent
            targetParent.children.insert(node, at: min(insertIdx + offset, targetParent.children.count))
        }

        endDrag()
        clearSelection()
        scheduleSave()
        return true
    }

    // MARK: - Node operations

    /// Split a node at the cursor position: text before stays, text after goes to a new sibling.
    /// When cursor is at the end this behaves like "add empty sibling".
    func splitAndInsert(after nodeId: UUID, cursorOffset: Int) {
        saveUndoState()
        guard let node = root.find(id: nodeId),
              let parent = node.parent,
              let index = parent.indexOfChild(nodeId) else { return }

        let nsText = node.text as NSString
        let safeOffset = min(cursorOffset, nsText.length)
        let beforeText = nsText.substring(to: safeOffset)
        let afterText = nsText.substring(from: safeOffset)

        node.text = beforeText

        let newNode = OutlineNode(text: afterText)
        newNode.parent = parent
        parent.children.insert(newNode, at: index + 1)
        pendingFocusId = newNode.id
        pendingCursorPosition = 0
        scheduleSave()
    }

    /// Merge this node's text into the previous visible node. Children transfer too.
    func mergeWithPrevious(nodeId: UUID) {
        let visible = visibleNodes()
        guard let idx = visible.firstIndex(where: { $0.node.id == nodeId }),
              idx > 0 else { return }

        saveUndoState()

        let node = visible[idx].node
        let prevNode = visible[idx - 1].node
        let mergePoint = (prevNode.text as NSString).length

        prevNode.text += node.text

        // Transfer children to the previous node
        for child in node.children {
            child.parent = prevNode
            prevNode.children.append(child)
        }
        if !node.children.isEmpty {
            prevNode.isExpanded = true
        }

        // Remove the merged node
        if let parent = node.parent, let childIdx = parent.indexOfChild(nodeId) {
            parent.children.remove(at: childIdx)
        }

        pendingFocusId = prevNode.id
        pendingCursorPosition = mergePoint
        scheduleSave()
    }

    @discardableResult
    func addSibling(after nodeId: UUID) -> UUID? {
        splitAndInsert(after: nodeId, cursorOffset: (root.find(id: nodeId)?.text as NSString?)?.length ?? 0)
        return nil
    }

    @discardableResult
    func addChild(to nodeId: UUID) -> UUID? {
        saveUndoState()
        guard let node = root.find(id: nodeId) else { return nil }

        let newNode = OutlineNode(text: "")
        newNode.parent = node
        node.children.insert(newNode, at: 0)
        node.isExpanded = true
        pendingFocusId = newNode.id
        scheduleSave()
        return newNode.id
    }

    func indent(nodeId: UUID) {
        saveUndoState()
        guard indentNodeWithoutUndo(nodeId: nodeId) else { return }
        pendingFocusId = nodeId
        scheduleSave()
    }

    @discardableResult
    private func indentNodeWithoutUndo(nodeId: UUID) -> Bool {
        guard let node = root.find(id: nodeId),
              let parent = node.parent,
              let index = parent.indexOfChild(nodeId),
              index > 0 else { return false }

        let newParent = parent.children[index - 1]
        parent.children.remove(at: index)
        node.parent = newParent
        newParent.children.append(node)
        newParent.isExpanded = true
        return true
    }

    func unindent(nodeId: UUID) {
        saveUndoState()
        guard unindentNodeWithoutUndo(nodeId: nodeId) else { return }
        pendingFocusId = nodeId
        scheduleSave()
    }

    @discardableResult
    private func unindentNodeWithoutUndo(nodeId: UUID) -> Bool {
        guard let node = root.find(id: nodeId),
              let parent = node.parent,
              parent.id != root.id,
              parent.id != currentRoot.id,
              let grandparent = parent.parent,
              let parentIndex = grandparent.indexOfChild(parent.id),
              let nodeIndex = parent.indexOfChild(nodeId) else { return false }

        let siblingsAfter = Array(parent.children[(nodeIndex + 1)...])
        parent.children.removeSubrange(nodeIndex...)

        for sibling in siblingsAfter {
            sibling.parent = node
            node.children.append(sibling)
        }
        if !siblingsAfter.isEmpty {
            node.isExpanded = true
        }

        node.parent = grandparent
        grandparent.children.insert(node, at: parentIndex + 1)
        return true
    }

    func indentSelected() {
        let selected = visibleNodes()
            .map(\.node.id)
            .filter { selectedNodeIds.contains($0) }
        guard !selected.isEmpty else { return }

        saveUndoState()
        var changed = false
        for id in selected {
            changed = indentNodeWithoutUndo(nodeId: id) || changed
        }
        if changed {
            clearSelection()
            scheduleSave()
        }
    }

    func unindentSelected() {
        let selected = visibleNodes()
            .map(\.node.id)
            .filter { selectedNodeIds.contains($0) }
            .reversed()
        guard !selected.isEmpty else { return }

        saveUndoState()
        var changed = false
        for id in selected {
            changed = unindentNodeWithoutUndo(nodeId: id) || changed
        }
        if changed {
            clearSelection()
            scheduleSave()
        }
    }

    func deleteNode(nodeId: UUID) {
        saveUndoState()
        guard let node = root.find(id: nodeId),
              let parent = node.parent,
              let index = parent.indexOfChild(nodeId) else { return }

        if parent.id == currentRoot.id && parent.children.count == 1 {
            return
        }

        parent.children.remove(at: index)
        pruneZoomPath()

        if index > 0 {
            pendingFocusId = parent.children[index - 1].id
        } else if !parent.children.isEmpty {
            pendingFocusId = parent.children[0].id
        } else if parent.id != root.id {
            pendingFocusId = parent.id
        }
        scheduleSave()
    }

    func moveUp(nodeId: UUID) {
        saveUndoState()
        guard let node = root.find(id: nodeId),
              let parent = node.parent,
              let index = parent.indexOfChild(nodeId),
              index > 0 else { return }

        parent.children.swapAt(index, index - 1)
        pendingFocusId = node.id
        scheduleSave()
    }

    func moveDown(nodeId: UUID) {
        saveUndoState()
        guard let node = root.find(id: nodeId),
              let parent = node.parent,
              let index = parent.indexOfChild(nodeId),
              index < parent.children.count - 1 else { return }

        parent.children.swapAt(index, index + 1)
        pendingFocusId = node.id
        scheduleSave()
    }

    func toggleDone(nodeId: UUID) {
        saveUndoState()
        guard let node = root.find(id: nodeId) else { return }
        node.toggleDone()
        scheduleSave()
    }

    func toggleExpanded(nodeId: UUID) {
        guard let node = root.find(id: nodeId) else { return }
        node.isExpanded.toggle()
        scheduleSave()
    }

    // MARK: - Persistence

    private static var defaultDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("Strata")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var defaultFileURL: URL {
        defaultDirectory.appendingPathComponent("default.opml")
    }

    func scheduleSave() {
        treeModifiedSinceLastSnapshot = true
        saveWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.save()
        }
        saveWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: item)
    }

    func save() {
        guard let url = currentFilePath else { return }
        let data = OPMLService.serialize(root: root)
        try? data.write(to: url)
    }

    func save(to url: URL) {
        currentFilePath = url
        let data = OPMLService.serialize(root: root)
        try? data.write(to: url)
        RecentFiles.shared.add(url)
    }

    /// User-triggered save — prompts for file path if this is an unsaved document
    func saveExplicitly() {
        if currentFilePath == nil {
            saveFileAs()
        } else {
            save()
        }
    }

    static func load() -> OutlineStore {
        load(from: defaultFileURL)
    }

    static func load(from url: URL) -> OutlineStore {
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let root = try? OPMLService.parse(data: data) else {
            return OutlineStore()
        }
        let store = OutlineStore(root: root)
        store.currentFilePath = url
        return store
    }

    /// Open a file into this window, replacing the current content
    func openFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.init(filenameExtension: "opml")!]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        if panel.runModal() == .OK, let url = panel.url {
            loadFile(from: url)
        }
    }

    /// Replace the current document content with a file
    func loadFile(from url: URL) {
        guard let data = try? Data(contentsOf: url),
              let newRoot = try? OPMLService.parse(data: data) else { return }

        // Save current document before switching
        save()

        root = newRoot
        currentFilePath = url
        zoomPath = []
        undoStack.removeAll()
        redoStack.removeAll()
        selectedNodeIds.removeAll()
        draggedNodeIds.removeAll()
        dropTargetId = nil
        treeModifiedSinceLastSnapshot = true
        pendingFocusId = root.children.first?.id
        RecentFiles.shared.add(url)
    }

    func saveFileAs() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.init(filenameExtension: "opml")!]
        if let currentURL = currentFilePath {
            panel.nameFieldStringValue = currentURL.lastPathComponent
        } else {
            panel.nameFieldStringValue = "outline.opml"
        }

        if panel.runModal() == .OK, let url = panel.url {
            save(to: url)
        }
    }

    /// Duplicate the current document to a new file without moving the original.
    func duplicate() -> URL? {
        save()

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.init(filenameExtension: "opml")!]

        if let currentURL = currentFilePath {
            let baseName = currentURL.deletingPathExtension().lastPathComponent
            panel.nameFieldStringValue = "\(baseName) copy.opml"
        } else {
            panel.nameFieldStringValue = "outline copy.opml"
        }

        if panel.runModal() == .OK, let url = panel.url {
            let data = OPMLService.serialize(root: root)
            try? data.write(to: url)
            RecentFiles.shared.add(url)
            return url
        }
        return nil
    }

    // MARK: - Export

    func exportAs(format: String) {
        let panel = NSSavePanel()
        let baseName = documentTitle == "Strata" ? "outline" : documentTitle
        let content: String
        switch format {
        case "txt":
            panel.allowedContentTypes = [.plainText]
            panel.nameFieldStringValue = "\(baseName).txt"
            content = ExportService.plainText(root: root)
        case "md":
            panel.allowedContentTypes = [.init(filenameExtension: "md") ?? .plainText]
            panel.nameFieldStringValue = "\(baseName).md"
            content = ExportService.markdown(root: root)
        case "html":
            panel.allowedContentTypes = [.html]
            panel.nameFieldStringValue = "\(baseName).html"
            content = ExportService.html(root: root)
        default:
            return
        }

        if panel.runModal() == .OK, let url = panel.url {
            try? content.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
