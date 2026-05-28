import SwiftUI
import AppKit
import UniformTypeIdentifiers

private enum OutlineLayoutMetrics {
    static let indentWidth: CGFloat = 24
    static let guideInset: CGFloat = 11
    static let controlHeight: CGFloat = 26
    static let checkboxWidth: CGFloat = 22
    static let chevronWidth: CGFloat = 16
    static let bulletWidth: CGFloat = 15
    static let textGap: CGFloat = 5
    static let checkboxIconSize: CGFloat = 15
    static let chevronIconSize: CGFloat = 10
    static let bulletSize: CGFloat = 6
    static let bulletHoverOutlineSize: CGFloat = 12
    static let controlTopOffset: CGFloat = -2
    static let textTopOffset: CGFloat = 1

    static func guideX(forDepth depth: Int) -> CGFloat {
        CGFloat(depth) * indentWidth + guideInset
    }

    static func textLeading(forDepth depth: Int) -> CGFloat {
        CGFloat(depth) * indentWidth + checkboxWidth + chevronWidth + bulletWidth + textGap
    }
}

struct NodeRowView: View {
    @Bindable var node: OutlineNode
    let depth: Int
    var store: OutlineStore
    let isSelected: Bool
    let isDragging: Bool
    let isDropTarget: Bool
    let dropAbove: Bool
    let dropAsChild: Bool
    let hasSelection: Bool
    let shouldFocus: Bool
    let cursorPosition: Int?
    let searchQuery: String
    let dragCount: Int
    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            // Indentation with hierarchy lines
            if depth > 0 {
                Spacer()
                    .frame(width: CGFloat(depth) * OutlineLayoutMetrics.indentWidth)
            }

            // Checkbox — visible on hover or when done
            ZStack {
                if node.isDone {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: OutlineLayoutMetrics.checkboxIconSize))
                        .foregroundStyle(Color.primary.opacity(0.3))
                } else if isHovered {
                    Image(systemName: "circle")
                        .font(.system(size: OutlineLayoutMetrics.checkboxIconSize))
                        .foregroundStyle(Color.primary.opacity(0.12))
                }
            }
            .frame(width: OutlineLayoutMetrics.checkboxWidth, height: OutlineLayoutMetrics.controlHeight)
            .offset(y: OutlineLayoutMetrics.controlTopOffset)
            .contentShape(Rectangle())
            .onTapGesture {
                store.toggleDone(nodeId: node.id)
            }

            // Expand/collapse chevron — always reserve space for alignment
            ZStack {
                if !node.children.isEmpty {
                    Image(systemName: "chevron.right")
                        .font(.system(size: OutlineLayoutMetrics.chevronIconSize, weight: .semibold))
                        .foregroundStyle(Color.primary.opacity(0.25))
                        .rotationEffect(.degrees(node.isExpanded ? 90 : 0))
                        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: node.isExpanded)
                }
            }
            .frame(width: OutlineLayoutMetrics.chevronWidth, height: OutlineLayoutMetrics.controlHeight)
            .offset(y: OutlineLayoutMetrics.controlTopOffset)
            .contentShape(Rectangle())
            .onTapGesture {
                if !node.children.isEmpty {
                    store.toggleExpanded(nodeId: node.id)
                }
            }

            // Bullet — always present, click to focus/zoom in, drag handle
            ZStack {
                Circle()
                    .stroke(Color.primary.opacity(isHovered ? 0.18 : 0), lineWidth: 1.25)
                    .frame(
                        width: OutlineLayoutMetrics.bulletHoverOutlineSize,
                        height: OutlineLayoutMetrics.bulletHoverOutlineSize
                    )

                Circle()
                    .fill(Color.primary.opacity(isHovered ? 0.35 : 0.22))
                    .frame(width: OutlineLayoutMetrics.bulletSize, height: OutlineLayoutMetrics.bulletSize)
            }
            .animation(.easeInOut(duration: 0.12), value: isHovered)
            .frame(width: OutlineLayoutMetrics.bulletWidth, height: OutlineLayoutMetrics.controlHeight)
            .offset(y: OutlineLayoutMetrics.controlTopOffset)
            .contentShape(Rectangle())
            .onTapGesture {
                store.zoomIn(nodeId: node.id)
            }
            .onDrag {
                dragProvider()
            } preview: {
                dragPreview
            }
            .help("Focus on this node")

            Spacer().frame(width: OutlineLayoutMetrics.textGap)

            ZStack(alignment: .leading) {
                OutlineTextField(
                    nodeId: node.id,
                    text: Binding(
                        get: { node.text },
                        set: { node.text = $0 }
                    ),
                    formatting: Binding(
                        get: { node.formatting },
                        set: { node.formatting = $0 }
                    ),
                    isDone: node.isDone,
                    shouldFocus: shouldFocus,
                    cursorPosition: cursorPosition,
                    onCommit: { cursorOffset in
                        store.splitAndInsert(after: node.id, cursorOffset: cursorOffset)
                    },
                    onTab: { store.indent(nodeId: node.id) },
                    onBackTab: { store.unindent(nodeId: node.id) },
                    onMoveUp: {
                        if let prevId = store.previousVisibleNode(before: node.id) {
                            store.pendingFocusId = prevId
                        }
                    },
                    onMoveDown: {
                        if let nextId = store.nextVisibleNode(after: node.id) {
                            store.pendingFocusId = nextId
                        }
                    },
                    onDelete: { store.deleteNode(nodeId: node.id) },
                    onMergeWithPrevious: { store.mergeWithPrevious(nodeId: node.id) },
                    onToggleDone: { store.toggleDone(nodeId: node.id) },
                    onMoveNodeUp: { store.moveUp(nodeId: node.id) },
                    onMoveNodeDown: { store.moveDown(nodeId: node.id) },
                    onZoomIn: { store.zoomIn(nodeId: node.id) },
                    onEscape: {
                        if hasSelection {
                            store.clearSelection()
                        } else if store.isSearchActive {
                            store.isSearchActive = false
                            store.searchQuery = ""
                        } else {
                            // Exit editing → enter selection mode with this node selected.
                            // User can then navigate with Up/Down, extend with Shift+Up/Down,
                            // press Enter to edit, or Escape again to fully deselect.
                            store.selectNode(node.id)
                        }
                    },
                    onDidFocus: {
                        if store.pendingFocusId == node.id {
                            store.pendingFocusId = nil
                            store.pendingCursorPosition = nil
                        }
                    },
                    onTextChange: { store.scheduleSave() },
                    onSelectAllNodes: { store.selectAllVisible() },
                    onBeginEditing: {
                        store.clearSelection()
                        store.saveUndoStateIfModified()
                    },
                    onShiftUp: {
                        if store.hasSelection {
                            store.extendSelectionUp()
                        } else {
                            store.startSelectionUp(from: node.id)
                        }
                    },
                    onShiftDown: {
                        if store.hasSelection {
                            store.extendSelectionDown()
                        } else {
                            store.startSelectionDown(from: node.id)
                        }
                    },
                    onPasteNodes: { store.pasteNodes(after: node.id) },
                    onUndo: { store.undo() },
                    onRedo: { store.redo() },
                    onStructuralEditForUndo: { store.markStructuralEditForUndoRoute() },
                    shouldRouteStructuralUndoToStore: { store.shouldRouteStructuralUndoToStore },
                    shouldRouteStructuralRedoToStore: { store.shouldRouteStructuralRedoToStore },
                    searchQuery: searchQuery
                )
                .id("\(node.id.uuidString)-\(depth)")
                .allowsHitTesting(!hasSelection)

                if hasSelection {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture {
                            handleTextAreaClick()
                        }
                        .onDrag {
                            dragProvider()
                        } preview: {
                            dragPreview
                        }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .offset(y: OutlineLayoutMetrics.textTopOffset)

            // Note indicator
            if !node.note.isEmpty {
                Image(systemName: "note.text")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.primary.opacity(0.2))
                    .padding(.trailing, 4)
            }
        }
        .padding(.vertical, 2)
        .padding(.trailing, 8)
        .background(alignment: .leading) {
            HierarchyGuideLines(depth: depth)
                .stroke(Color.primary.opacity(0.11), lineWidth: 1)
        }
        .background(
            Group {
                if isSelected {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color.accentColor.opacity(0.15))
                }
            }
        )
        .opacity(isDragging ? 0.12 : 1.0)
        .overlay(alignment: dropAbove && !dropAsChild ? .top : .bottom) {
            if isDropTarget && !isDragging {
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(height: 2)
                    .padding(.leading, dropIndicatorLeadingPadding)
            }
        }
        .onDrop(of: [.plainText], delegate: NodeDropDelegate(nodeId: node.id, depth: depth, store: store))
        .onHover { isHovered = $0 }
        .contentShape(Rectangle())
        .draggableWhenSelected(isSelected, provider: {
            dragProvider()
        }, preview: {
            dragPreview
        })
        .simultaneousGesture(
            TapGesture().onEnded {
                handleModifiedRowClick()
            }
        )
        .id(node.id)
    }

    private func handleModifiedRowClick() {
        let flags = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.shift) || flags.contains(.command) else { return }
        store.handleNodeClick(node.id, modifiers: flags)
    }

    private func handleTextAreaClick() {
        let flags = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.shift) || flags.contains(.command) {
            store.handleNodeClick(node.id, modifiers: flags)
        } else if isSelected {
            store.focusNodeForEditing(node.id)
        } else {
            store.selectNode(node.id)
        }
    }

    private func dragProvider() -> NSItemProvider {
        store.beginDrag(nodeId: node.id)
        let label = dragCount == 1 ? node.text : "\(dragCount) Strata nodes"
        return NSItemProvider(object: NSString(string: label))
    }

    private var dropIndicatorLeadingPadding: CGFloat {
        let targetDepth = dropAsChild ? depth + 1 : depth
        return OutlineLayoutMetrics.textLeading(forDepth: targetDepth)
    }

    private var dragPreview: some View {
        let title = node.text.isEmpty ? "Untitled" : node.text

        return HStack(spacing: 10) {
            Image(systemName: dragCount == 1 ? "circle.fill" : "line.3.horizontal")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 18, height: 18)

            VStack(alignment: .leading, spacing: 2) {
                if dragCount > 1 {
                    Text("\(dragCount) nodes")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .frame(maxWidth: 300, alignment: .leading)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(.controlBackgroundColor))
                .shadow(color: .black.opacity(0.18), radius: 14, y: 8)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.primary.opacity(0.10), lineWidth: 1)
        )
    }
}

private struct HierarchyGuideLines: Shape {
    let depth: Int

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard depth > 0 else { return path }

        for guideDepth in 0..<depth {
            let x = OutlineLayoutMetrics.guideX(forDepth: guideDepth)
            path.move(to: CGPoint(x: x, y: rect.minY))
            path.addLine(to: CGPoint(x: x, y: rect.maxY))
        }

        return path
    }
}

private extension View {
    @ViewBuilder
    func draggableWhenSelected<Preview: View>(
        _ isSelected: Bool,
        provider: @escaping () -> NSItemProvider,
        preview: @escaping () -> Preview
    ) -> some View {
        if isSelected {
            self.onDrag(provider, preview: preview)
        } else {
            self
        }
    }
}

struct NodeDropDelegate: DropDelegate {
    let nodeId: UUID
    let depth: Int
    let store: OutlineStore

    func dropEntered(info: DropInfo) {
        guard store.canDrop(on: nodeId) else { return }
        updateDropTarget(info: info)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard store.canDrop(on: nodeId) else {
            return DropProposal(operation: .cancel)
        }
        updateDropTarget(info: info)
        return DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        store.performDrop()
    }

    func dropExited(info: DropInfo) {
        store.clearDropTarget(nodeId)
    }

    private func updateDropTarget(info: DropInfo) {
        let above = info.location.y < 13
        let asChild = !above && info.location.x >= childDropThreshold
        store.updateDropTarget(nodeId, above: above, asChild: asChild)
    }

    private var childDropThreshold: CGFloat {
        CGFloat(depth) * OutlineLayoutMetrics.indentWidth + 122
    }
}

// MARK: - Note Editor

struct NoteEditorView: View {
    @Bindable var node: OutlineNode
    let depth: Int
    var store: OutlineStore
    @FocusState private var isFocused: Bool

    private var leadingPad: CGFloat {
        OutlineLayoutMetrics.textLeading(forDepth: depth)
    }

    var body: some View {
        HStack(spacing: 0) {
            Spacer().frame(width: leadingPad)
            TextField("Add a note...", text: Binding(
                get: { node.note },
                set: {
                    node.note = $0
                    store.scheduleSave()
                }
            ), axis: .vertical)
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
            .lineLimit(1...10)
            .focused($isFocused)
            .padding(.trailing, 8)
        }
        .padding(.bottom, 2)
    }
}

// MARK: - Flat Outline

struct VisibleItem: Identifiable {
    let node: OutlineNode
    let depth: Int
    var id: UUID { node.id }
}

struct FlatOutline: View {
    var store: OutlineStore

    var body: some View {
        let items = store.visibleNodes().map { VisibleItem(node: $0.node, depth: $0.depth) }
        let selectedIds = store.selectedNodeIds
        let draggedIds = store.draggedNodeIds
        let selectedCount = selectedIds.count
        let dropTargetId = store.dropTargetId
        let dropAbove = store.dropAbove
        let dropAsChild = store.dropAsChild
        let hasSelection = !selectedIds.isEmpty
        let pendingFocusId = store.pendingFocusId
        let pendingCursorPosition = store.pendingCursorPosition
        let searchQuery = store.isSearchActive ? store.searchQuery : ""

        ForEach(items) { item in
            VStack(alignment: .leading, spacing: 0) {
                let isSelected = selectedIds.contains(item.node.id)
                NodeRowView(
                    node: item.node,
                    depth: item.depth,
                    store: store,
                    isSelected: isSelected,
                    isDragging: draggedIds.contains(item.node.id),
                    isDropTarget: dropTargetId == item.node.id,
                    dropAbove: dropAbove,
                    dropAsChild: dropAsChild,
                    hasSelection: hasSelection,
                    shouldFocus: pendingFocusId == item.node.id,
                    cursorPosition: pendingFocusId == item.node.id ? pendingCursorPosition : nil,
                    searchQuery: searchQuery,
                    dragCount: isSelected ? max(selectedCount, 1) : 1
                )
                if !item.node.note.isEmpty || store.editingNoteId == item.node.id {
                    NoteEditorView(node: item.node, depth: item.depth, store: store)
                }
            }
        }
    }
}
