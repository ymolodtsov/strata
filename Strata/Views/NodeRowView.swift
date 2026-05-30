import SwiftUI
import AppKit
import UniformTypeIdentifiers

private enum OutlineLayoutMetrics {
    static let outlineCoordinateSpace = "StrataOutlineRows"
    static let indentWidth: CGFloat = 24
    static let controlHeight: CGFloat = 26
    static let checkboxWidth: CGFloat = 20
    static let chevronWidth: CGFloat = 18
    static let bulletWidth: CGFloat = 18
    static let textGap: CGFloat = 5
    static let checkboxIconSize: CGFloat = 15
    static let chevronIconSize: CGFloat = 10
    static let bulletSize: CGFloat = 6
    static let bulletHoverOutlineSize: CGFloat = 12
    static let chevronXOffset: CGFloat = 3
    static let controlTopOffset: CGFloat = -2
    static let textTopOffset: CGFloat = 1
    static let rowVerticalPadding: CGFloat = 2

    static func guideX(forDepth depth: Int) -> CGFloat {
        CGFloat(depth) * indentWidth + checkboxWidth + chevronWidth + (bulletWidth / 2)
    }

    static func dotCenterY(in frame: CGRect) -> CGFloat {
        frame.minY + rowVerticalPadding + (controlHeight / 2) + controlTopOffset
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
            .offset(x: OutlineLayoutMetrics.chevronXOffset, y: OutlineLayoutMetrics.controlTopOffset)
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
                handleBulletClick()
            }
            .onDrag {
                dragProvider()
            } preview: {
                dragPreview
            }

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
                    onToggleNote: { store.toggleNote(nodeId: node.id) },
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
        .padding(.vertical, OutlineLayoutMetrics.rowVerticalPadding)
        .padding(.trailing, 8)
        .background(rowFramePreference)
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
        .id(node.id)
    }

    private func handleBulletClick() {
        let flags = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.shift) || flags.contains(.command) {
            store.handleNodeClick(node.id, modifiers: flags)
        } else {
            store.zoomIn(nodeId: node.id)
        }
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

private struct RowFramePreferenceKey: PreferenceKey {
    static var defaultValue: [UUID: CGRect] = [:]

    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private extension NodeRowView {
    var rowFramePreference: some View {
        GeometryReader { proxy in
            Color.clear.preference(
                key: RowFramePreferenceKey.self,
                value: [node.id: proxy.frame(in: .named(OutlineLayoutMetrics.outlineCoordinateSpace))]
            )
        }
    }
}

private struct HierarchyGuideOverlay: Shape {
    let segments: [HierarchyGuideSegment]

    func path(in rect: CGRect) -> Path {
        var path = Path()

        for segment in segments {
            path.move(to: CGPoint(x: segment.x, y: segment.startY))
            path.addLine(to: CGPoint(x: segment.x, y: segment.endY))
        }

        return path
    }
}

private struct HierarchyGuideSegment: Sendable, Equatable {
    let x: CGFloat
    let startY: CGFloat
    let endY: CGFloat
}

private enum HierarchyGuideLayout {
    private struct FramedGuideItem {
        let item: VisibleItem
        let frame: CGRect
    }

    static func segments(items: [VisibleItem], rowFrames: [UUID: CGRect]) -> [HierarchyGuideSegment] {
        guard items.count > 1, !rowFrames.isEmpty else { return [] }

        let framedItems = items.compactMap { item -> FramedGuideItem? in
            guard let frame = rowFrames[item.id] else { return nil }
            return FramedGuideItem(item: item, frame: frame)
        }

        guard framedItems.count > 1 else { return [] }

        let maxDepth = framedItems.map(\.item.depth).max() ?? 0
        guard maxDepth > 0 else { return [] }

        var segments: [HierarchyGuideSegment] = []
        segments.reserveCapacity(framedItems.count / 2)

        for guideDepth in 0..<maxDepth {
            var index = framedItems.startIndex

            while index < framedItems.endIndex {
                var startY: CGFloat?

                while index < framedItems.endIndex {
                    let current = framedItems[index]
                    let currentDepth = current.item.depth

                    if currentDepth > guideDepth {
                        startY = current.frame.minY - 1
                        break
                    }

                    if currentDepth == guideDepth,
                       current.item.node.isExpanded,
                       index + 1 < framedItems.endIndex,
                       framedItems[index + 1].item.depth > guideDepth {
                        startY = OutlineLayoutMetrics.dotCenterY(in: current.frame) + (OutlineLayoutMetrics.bulletSize / 2) + 6
                        index += 1
                        break
                    }

                    index += 1
                }

                guard let startY else { break }

                var lastVisibleDescendant: FramedGuideItem?
                while index < framedItems.endIndex {
                    let current = framedItems[index]
                    guard current.item.depth > guideDepth else { break }
                    lastVisibleDescendant = current
                    index += 1
                }

                guard let lastVisibleDescendant else { continue }

                let x = OutlineLayoutMetrics.guideX(forDepth: guideDepth)
                let endY = lastVisibleDescendant.frame.maxY - 4
                guard endY > startY else { continue }

                segments.append(HierarchyGuideSegment(x: x, startY: startY, endY: endY))
            }
        }

        return segments
    }

    static func framesAreVisuallyEqual(_ lhs: [UUID: CGRect], _ rhs: [UUID: CGRect]) -> Bool {
        guard lhs.count == rhs.count else { return false }

        for (id, leftFrame) in lhs {
            guard let rightFrame = rhs[id],
                  leftFrame.isVisuallyEqual(to: rightFrame) else { return false }
        }

        return true
    }
}

private extension CGRect {
    func isVisuallyEqual(to other: CGRect, tolerance: CGFloat = 0.5) -> Bool {
        abs(minX - other.minX) < tolerance &&
        abs(minY - other.minY) < tolerance &&
        abs(width - other.width) < tolerance &&
        abs(height - other.height) < tolerance
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
        .onAppear {
            focusIfRequested()
        }
        .onChange(of: store.pendingNoteFocusId) { _, _ in
            focusIfRequested()
        }
    }

    private func focusIfRequested() {
        guard store.pendingNoteFocusId == node.id else { return }
        DispatchQueue.main.async {
            isFocused = true
            if store.pendingNoteFocusId == node.id {
                store.pendingNoteFocusId = nil
            }
        }
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
    @State private var rowFrames: [UUID: CGRect] = [:]

    var body: some View {
        let items = store.visibleNodes().map { VisibleItem(node: $0.node, depth: $0.depth) }
        let guideSegments = HierarchyGuideLayout.segments(items: items, rowFrames: rowFrames)
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

        ZStack(alignment: .topLeading) {
            HierarchyGuideOverlay(segments: guideSegments)
                .stroke(Color.primary.opacity(0.11), lineWidth: 1)
                .allowsHitTesting(false)

            LazyVStack(alignment: .leading, spacing: 0) {
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
        .coordinateSpace(name: OutlineLayoutMetrics.outlineCoordinateSpace)
        .onPreferenceChange(RowFramePreferenceKey.self) { frames in
            if !HierarchyGuideLayout.framesAreVisuallyEqual(rowFrames, frames) {
                rowFrames = frames
            }
        }
    }
}
