import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct NodeRowView: View {
    @Bindable var node: OutlineNode
    let depth: Int
    var store: OutlineStore
    @State private var isHovered = false

    private var isSelected: Bool {
        store.selectedNodeIds.contains(node.id)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            // Indentation with hierarchy lines
            if depth > 0 {
                HStack(spacing: 0) {
                    ForEach(0..<depth, id: \.self) { _ in
                        ZStack {
                            Rectangle()
                                .fill(Color.primary.opacity(0.07))
                                .frame(width: 1)
                        }
                        .frame(width: 24)
                    }
                }
            }

            // Checkbox — visible on hover or when done
            ZStack {
                if node.isDone {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(Color.primary.opacity(0.3))
                } else if isHovered {
                    Image(systemName: "circle")
                        .font(.system(size: 14))
                        .foregroundStyle(Color.primary.opacity(0.12))
                }
            }
            .frame(width: 22, height: 22)
            .contentShape(Rectangle())
            .onTapGesture {
                store.toggleDone(nodeId: node.id)
            }

            // Expand/collapse chevron — always reserve space for alignment
            ZStack {
                if !node.children.isEmpty {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.primary.opacity(0.25))
                        .rotationEffect(.degrees(node.isExpanded ? 90 : 0))
                        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: node.isExpanded)
                }
            }
            .frame(width: 16, height: 22)
            .contentShape(Rectangle())
            .onTapGesture {
                if !node.children.isEmpty {
                    store.toggleExpanded(nodeId: node.id)
                }
            }

            // Bullet — always present, click to focus/zoom in, drag handle
            ZStack {
                Circle()
                    .fill(Color.primary.opacity(isHovered ? 0.35 : 0.22))
                    .frame(width: 6, height: 6)
                    .animation(.easeInOut(duration: 0.15), value: isHovered)
            }
            .frame(width: 14, height: 22)
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

            Spacer().frame(width: 6)

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
                    shouldFocus: store.pendingFocusId == node.id,
                    cursorPosition: store.pendingFocusId == node.id ? store.pendingCursorPosition : nil,
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
                        if store.hasSelection {
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
                    searchQuery: store.isSearchActive ? store.searchQuery : ""
                )
                .allowsHitTesting(!store.hasSelection)

                if store.hasSelection {
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
        .background(
            Group {
                if isSelected {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color.accentColor.opacity(0.15))
                }
            }
        )
        .opacity(store.draggedNodeIds.contains(node.id) ? 0.12 : 1.0)
        .overlay(alignment: store.dropAbove ? .top : .bottom) {
            if store.dropTargetId == node.id && !store.draggedNodeIds.contains(node.id) {
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(height: 2)
                    .padding(.leading, CGFloat(depth) * 24 + 22)
            }
        }
        .onDrop(of: [.plainText], delegate: NodeDropDelegate(nodeId: node.id, store: store))
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
        } else {
            store.selectNode(node.id)
        }
    }

    private func dragProvider() -> NSItemProvider {
        store.beginDrag(nodeId: node.id)
        let count = max(store.draggedNodeIds.count, 1)
        let label = count == 1 ? node.text : "\(count) Strata nodes"
        return NSItemProvider(object: NSString(string: label))
    }

    private var dragPreview: some View {
        let count = max(store.draggedNodeIds.count, 1)
        let title = node.text.isEmpty ? "Untitled" : node.text

        return HStack(spacing: 10) {
            Image(systemName: count == 1 ? "circle.fill" : "line.3.horizontal")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 18, height: 18)

            VStack(alignment: .leading, spacing: 2) {
                if count > 1 {
                    Text("\(count) nodes")
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
    let store: OutlineStore

    func dropEntered(info: DropInfo) {
        guard store.canDrop(on: nodeId) else { return }
        store.dropTargetId = nodeId
        store.dropAbove = info.location.y < 13
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard store.canDrop(on: nodeId) else {
            return DropProposal(operation: .cancel)
        }
        store.dropTargetId = nodeId
        store.dropAbove = info.location.y < 13
        return DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        store.performDrop()
    }

    func dropExited(info: DropInfo) {
        if store.dropTargetId == nodeId {
            store.dropTargetId = nil
        }
    }
}

// MARK: - Note Editor

struct NoteEditorView: View {
    @Bindable var node: OutlineNode
    let depth: Int
    var store: OutlineStore
    @FocusState private var isFocused: Bool

    private var leadingPad: CGFloat {
        CGFloat(depth) * 24 + 22 + 16 + 14 + 6
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
        ForEach(items) { item in
            VStack(alignment: .leading, spacing: 0) {
                NodeRowView(node: item.node, depth: item.depth, store: store)
                if !item.node.note.isEmpty || store.editingNoteId == item.node.id {
                    NoteEditorView(node: item.node, depth: item.depth, store: store)
                }
            }
        }
    }
}
