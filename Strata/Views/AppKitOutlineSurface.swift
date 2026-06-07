import AppKit
import SwiftUI

struct AppKitOutlineSurface: NSViewRepresentable {
    var store: OutlineStore

    func makeNSView(context: Context) -> AppKitOutlineScrollView {
        let scrollView = AppKitOutlineScrollView()
        scrollView.updateStore(store)
        return scrollView
    }

    func updateNSView(_ nsView: AppKitOutlineScrollView, context: Context) {
        nsView.updateStore(store)
    }
}

final class AppKitOutlineScrollView: NSScrollView {
    private let outlineView = AppKitOutlineDocumentView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    func updateStore(_ store: OutlineStore) {
        outlineView.store = store
        reloadOutline()
    }

    override func layout() {
        super.layout()
        reloadOutline()
    }

    private func configure() {
        borderType = .noBorder
        drawsBackground = true
        backgroundColor = .textBackgroundColor
        hasVerticalScroller = true
        hasHorizontalScroller = false
        autohidesScrollers = true
        scrollerStyle = .overlay
        verticalScrollElasticity = .allowed
        horizontalScrollElasticity = .none

        contentView.postsBoundsChangedNotifications = true
        documentView = outlineView

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(boundsDidChange),
            name: NSView.boundsDidChangeNotification,
            object: contentView
        )
    }

    private func reloadOutline() {
        let width = max(contentView.bounds.width, bounds.width, 1)
        outlineView.reloadData(availableWidth: width, visibleRect: contentView.bounds)
    }

    @objc private func boundsDidChange() {
        outlineView.visibleRectDidChange(contentView.bounds)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}

final class AppKitOutlineEditorTextView: NSTextView {
    weak var outlineView: AppKitOutlineDocumentView?

    var strataNodeId: UUID? {
        outlineView?.editingNodeId
    }

    override func paste(_ sender: Any?) {
        if pasteOutlineNodesFromPasteboard() {
            return
        }
        super.paste(sender)
    }

    func pasteOutlineNodesFromPasteboard() -> Bool {
        outlineView?.pasteIntoCurrentNodeOrAfter() == true
    }

    func selectAllVisibleNodes() {
        outlineView?.selectAllVisibleNodes()
    }

    func moveCurrentNodeUp() {
        outlineView?.moveEditingNodeUp()
    }

    func moveCurrentNodeDown() {
        outlineView?.moveEditingNodeDown()
    }

    func insertDateString(_ dateString: String) {
        insertText(dateString, replacementRange: selectedRange)
    }

    @objc func wrapBold() { toggleFormatting(.bold) }
    @objc func wrapItalic() { toggleFormatting(.italic) }
    @objc func wrapUnderline() { toggleFormatting(.underline) }
    @objc func wrapHighlight() { toggleFormatting(.highlight) }

    @objc func editLink() {
        guard let storage = textStorage else { return }

        var range = selectedRange
        if range.length == 0, storage.length > 0 {
            let location = min(range.location, storage.length - 1)
            var effectiveRange = NSRange(location: 0, length: 0)
            if storage.attribute(.link, at: location, effectiveRange: &effectiveRange) != nil {
                range = effectiveRange
            }
        }

        guard range.length > 0 else {
            NSSound.beep()
            return
        }

        setSelectedRange(range)
        orderFrontLinkPanel(nil)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        if event.keyCode == 13 && flags == .command {
            window?.performClose(nil)
            return true
        }
        if event.keyCode == 36 && flags == .command {
            outlineView?.toggleDoneForEditingNode()
            return true
        }
        if event.keyCode == 36 && flags == [.command, .shift] {
            outlineView?.toggleNoteForEditingNode()
            return true
        }
        if event.keyCode == 11 && flags == .command {
            wrapBold()
            return true
        }
        if event.keyCode == 34 && flags == .command {
            wrapItalic()
            return true
        }
        if event.keyCode == 32 && flags == .command {
            wrapUnderline()
            return true
        }
        if event.keyCode == 37 && flags == .command {
            wrapHighlight()
            return true
        }
        if event.keyCode == 40 && flags == .command {
            editLink()
            return true
        }
        if event.keyCode == 2 && flags == [.command, .shift] {
            insertDateString(StrataTextField.localizedCurrentDateString())
            return true
        }
        if event.keyCode == 126 && (flags == .command || flags == [.command, .shift]) {
            outlineView?.moveEditingNodeUp()
            return true
        }
        if event.keyCode == 125 && (flags == .command || flags == [.command, .shift]) {
            outlineView?.moveEditingNodeDown()
            return true
        }

        return super.performKeyEquivalent(with: event)
    }

    private func toggleFormatting(_ kind: TextFormattingKind) {
        guard let storage = textStorage else { return }
        let range = selectedRange

        if range.length == 0 {
            toggleTypingAttribute(kind)
            return
        }

        storage.beginEditing()
        switch kind {
        case .bold:
            toggleFontTrait(.boldFontMask, in: range, storage: storage)
        case .italic:
            toggleFontTrait(.italicFontMask, in: range, storage: storage)
        case .underline:
            if storage.attribute(.underlineStyle, at: range.location, effectiveRange: nil) == nil {
                storage.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range)
                storage.addAttribute(OutlineTextField.formattingAttribute, value: kind.rawValue, range: range)
            } else {
                storage.removeAttribute(.underlineStyle, range: range)
                storage.removeAttribute(OutlineTextField.formattingAttribute, range: range)
            }
        case .highlight:
            if storage.attribute(.backgroundColor, at: range.location, effectiveRange: nil) == nil {
                storage.addAttribute(.backgroundColor, value: NSColor.systemYellow.withAlphaComponent(0.3), range: range)
                storage.addAttribute(OutlineTextField.formattingAttribute, value: kind.rawValue, range: range)
            } else {
                storage.removeAttribute(.backgroundColor, range: range)
                storage.removeAttribute(OutlineTextField.formattingAttribute, range: range)
            }
        case .link:
            storage.endEditing()
            editLink()
            return
        }
        storage.endEditing()
        didChangeText()
        setSelectedRange(range)
    }

    private func toggleTypingAttribute(_ kind: TextFormattingKind) {
        var attributes = typingAttributes
        let baseFont = (attributes[.font] as? NSFont) ?? OutlineTextField.font

        switch kind {
        case .bold:
            attributes[.font] = toggledFontTrait(.boldFontMask, font: baseFont)
        case .italic:
            attributes[.font] = toggledFontTrait(.italicFontMask, font: baseFont)
        case .underline:
            if attributes[.underlineStyle] == nil {
                attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
                attributes[OutlineTextField.formattingAttribute] = TextFormattingKind.underline.rawValue
            } else {
                attributes.removeValue(forKey: .underlineStyle)
                attributes.removeValue(forKey: OutlineTextField.formattingAttribute)
            }
        case .highlight:
            if attributes[.backgroundColor] == nil {
                attributes[.backgroundColor] = NSColor.systemYellow.withAlphaComponent(0.3)
                attributes[OutlineTextField.formattingAttribute] = TextFormattingKind.highlight.rawValue
            } else {
                attributes.removeValue(forKey: .backgroundColor)
                attributes.removeValue(forKey: OutlineTextField.formattingAttribute)
            }
        case .link:
            attributes.removeValue(forKey: .link)
            attributes.removeValue(forKey: .underlineStyle)
            attributes.removeValue(forKey: OutlineTextField.manualLinkURLAttribute)
            attributes.removeValue(forKey: OutlineTextField.formattingAttribute)
        }

        typingAttributes = attributes
    }

    private func toggleFontTrait(_ trait: NSFontTraitMask, in range: NSRange, storage: NSTextStorage) {
        storage.enumerateAttribute(.font, in: range) { value, subrange, _ in
            let font = (value as? NSFont) ?? OutlineTextField.font
            storage.addAttribute(.font, value: toggledFontTrait(trait, font: font), range: subrange)
        }
    }

    private func toggledFontTrait(_ trait: NSFontTraitMask, font: NSFont) -> NSFont {
        let manager = NSFontManager.shared
        if manager.traits(of: font).contains(trait) {
            return manager.convert(font, toNotHaveTrait: trait)
        }
        return manager.convert(font, toHaveTrait: trait)
    }
}

final class AppKitOutlineNoteTextView: NSTextView {
    weak var outlineView: AppKitOutlineDocumentView?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.keyCode == 13 && flags == .command {
            window?.performClose(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

private struct AppKitOutlineMetrics {
    static let indentWidth: CGFloat = 24
    static let checkboxWidth: CGFloat = 20
    static let chevronWidth: CGFloat = 18
    static let bulletWidth: CGFloat = 18
    static let textGap: CGFloat = 5
    static let rowVerticalPadding: CGFloat = 2
    static let rowControlHeight: CGFloat = 26
    static let topPaddingExpanded: CGFloat = 16
    static let topPaddingZoomed: CGFloat = 8
    static let bottomPadding: CGFloat = 60
    static let horizontalPadding: CGFloat = 28
    static let rightPadding: CGFloat = 16
    static let noteSpacing: CGFloat = 3
    static let noteMinimumHeight: CGFloat = 22
    static let noteFont = NSFont.systemFont(ofSize: 13)

    static func textX(depth: Int) -> CGFloat {
        horizontalPadding
            + CGFloat(depth) * indentWidth
            + checkboxWidth
            + chevronWidth
            + bulletWidth
            + textGap
    }

    static func guideX(level: Int) -> CGFloat {
        horizontalPadding
            + CGFloat(level) * indentWidth
            + checkboxWidth
            + chevronWidth
            + (bulletWidth / 2)
    }
}

private struct AppKitOutlineRow {
    let node: OutlineNode
    let depth: Int
    var frame: CGRect
    var checkboxFrame: CGRect
    var chevronFrame: CGRect
    var bulletFrame: CGRect
    var textFrame: CGRect
    var noteFrame: CGRect?
}

final class AppKitOutlineDocumentView: NSView, NSTextViewDelegate {
    weak var store: OutlineStore?

    private var rows: [AppKitOutlineRow] = []
    private var rowById: [UUID: AppKitOutlineRow] = [:]
    private var measurementCache: [String: CGFloat] = [:]
    private var trackingArea: NSTrackingArea?
    private var lastAvailableWidth: CGFloat = 0
    private var lastVisibleRect: CGRect = .zero
    private var suppressTextDidChange = false

    fileprivate var editingNodeId: UUID?
    private var editorTextView: AppKitOutlineEditorTextView?
    private var noteTextView: AppKitOutlineNoteTextView?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    func reloadData(availableWidth: CGFloat, visibleRect: CGRect) {
        guard let store else { return }
        let normalizedWidth = max(availableWidth, 1)
        if Int(lastAvailableWidth.rounded()) != Int(normalizedWidth.rounded()) {
            measurementCache.removeAll(keepingCapacity: true)
        }
        lastAvailableWidth = normalizedWidth
        lastVisibleRect = visibleRect

        rebuildRows(store: store, availableWidth: lastAvailableWidth)
        applyPendingFocusIfNeeded()
        applyPendingNoteFocusIfNeeded()
        updateEditorFrame()
        updateNoteEditorFrame()
        setNeedsDisplay(bounds)
    }

    func visibleRectDidChange(_ rect: CGRect) {
        lastVisibleRect = rect
        setNeedsDisplay(rect.insetBy(dx: 0, dy: -80))
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let store else { return }

        NSColor.textBackgroundColor.setFill()
        dirtyRect.fill()

        let drawRect = dirtyRect.insetBy(dx: 0, dy: -80)
        for row in rows where row.frame.intersects(drawRect) {
            drawRow(row, store: store)
        }
    }

    override func mouseMoved(with event: NSEvent) {
        guard let store else { return }
        let point = convert(event.locationInWindow, from: nil)
        let hovered = row(at: point)?.node.id
        if store.hoveredRowId != hovered {
            store.hoveredRowId = hovered
            setNeedsDisplay(bounds)
        }
    }

    override func mouseExited(with event: NSEvent) {
        guard let store else { return }
        if store.hoveredRowId != nil {
            store.hoveredRowId = nil
            setNeedsDisplay(bounds)
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard let store else { return }

        let point = convert(event.locationInWindow, from: nil)
        guard let row = row(at: point) else {
            finishEditing(commit: true)
            finishNoteEditing(commit: true)
            store.clearSelection()
            reloadPreservingViewport()
            return
        }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        if let noteFrame = row.noteFrame, noteFrame.contains(point) {
            finishEditing(commit: true)
            beginNoteEditing(row.node.id)
            return
        }

        if row.checkboxFrame.contains(point) {
            finishEditing(commit: true)
            finishNoteEditing(commit: true)
            store.toggleDone(nodeId: row.node.id)
            reloadPreservingViewport()
            return
        }

        if row.chevronFrame.contains(point), !row.node.children.isEmpty {
            finishEditing(commit: true)
            finishNoteEditing(commit: true)
            store.toggleExpanded(nodeId: row.node.id)
            reloadPreservingViewport()
            return
        }

        if row.bulletFrame.contains(point) {
            finishEditing(commit: true)
            finishNoteEditing(commit: true)
            if flags.contains(.shift) || flags.contains(.command) {
                store.handleNodeClick(row.node.id, modifiers: flags)
            } else {
                store.zoomIn(nodeId: row.node.id)
            }
            reloadPreservingViewport()
            return
        }

        if flags.contains(.shift) || flags.contains(.command) {
            finishEditing(commit: true)
            finishNoteEditing(commit: true)
            store.handleNodeClick(row.node.id, modifiers: flags)
            reloadPreservingViewport()
            return
        }

        let cursor = characterIndex(at: point, in: row)
        beginEditing(row.node.id, cursorPosition: cursor)
    }

    override func keyDown(with event: NSEvent) {
        guard let store else {
            super.keyDown(with: event)
            return
        }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        if event.keyCode == 53 {
            finishEditing(commit: true)
            if store.hasSelection {
                store.clearSelection()
            }
            reloadPreservingViewport()
            return
        }

        guard store.hasSelection else {
            super.keyDown(with: event)
            return
        }

        switch (event.keyCode, flags) {
        case (126, []) :
            store.moveSelectionUp()
        case (125, []) :
            store.moveSelectionDown()
        case (126, .shift):
            store.extendSelectionUp()
        case (125, .shift):
            store.extendSelectionDown()
        case (126, .command), (126, [.command, .shift]):
            store.moveSelectedUp()
        case (125, .command), (125, [.command, .shift]):
            store.moveSelectedDown()
        case (36, []):
            store.focusFirstSelected()
        case (51, []):
            store.deleteSelected()
        case (36, .command):
            store.toggleDoneSelected()
        case (48, []):
            store.indentSelected()
        case (48, .shift):
            store.unindentSelected()
        default:
            super.keyDown(with: event)
            return
        }

        reloadPreservingViewport()
    }

    func textDidChange(_ notification: Notification) {
        guard !suppressTextDidChange,
              let textView = notification.object as? NSTextView,
              let store else { return }

        if textView === noteTextView {
            guard let nodeId = store.editingNoteId,
                  let node = store.root.find(id: nodeId) else { return }
            node.note = textView.string
            store.scheduleSave()
            rebuildRows(store: store, availableWidth: lastAvailableWidth)
            updateNoteEditorFrame()
            setNeedsDisplay(bounds)
            return
        }

        guard let nodeId = editingNodeId,
              let node = store.root.find(id: nodeId) else { return }

        node.text = textView.string
        node.formatting = Self.extractFormatting(from: textView.textStorage)
        store.scheduleSave()
        rebuildRows(store: store, availableWidth: lastAvailableWidth)
        updateEditorFrame()
        setNeedsDisplay(bounds)
    }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if textView === noteTextView {
            switch commandSelector {
            case #selector(NSResponder.cancelOperation(_:)):
                finishNoteEditing(commit: true)
                reloadPreservingViewport()
                return true
            default:
                return false
            }
        }

        guard let nodeId = editingNodeId,
              let store else { return false }

        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            syncCurrentEditorText()
            let offset = textView.selectedRange.location
            store.splitAndInsert(after: nodeId, cursorOffset: offset)
            reloadPreservingViewport()
            return true

        case #selector(NSResponder.insertTab(_:)):
            syncCurrentEditorText()
            if store.indent(nodeId: nodeId) {
                reloadPreservingViewport()
            }
            return true

        case #selector(NSResponder.insertBacktab(_:)):
            syncCurrentEditorText()
            if store.unindent(nodeId: nodeId) {
                reloadPreservingViewport()
            }
            return true

        case #selector(NSResponder.moveUp(_:)):
            syncCurrentEditorText()
            if let prevId = store.previousVisibleNode(before: nodeId) {
                beginEditing(prevId, cursorPosition: nil)
            }
            return true

        case #selector(NSResponder.moveDown(_:)):
            syncCurrentEditorText()
            if let nextId = store.nextVisibleNode(after: nodeId) {
                beginEditing(nextId, cursorPosition: nil)
            }
            return true

        case #selector(NSResponder.deleteBackward(_:)):
            if textView.string.isEmpty {
                store.deleteNode(nodeId: nodeId)
                reloadPreservingViewport()
                return true
            }
            if textView.selectedRange.location == 0 && textView.selectedRange.length == 0 {
                syncCurrentEditorText()
                store.mergeWithPrevious(nodeId: nodeId)
                reloadPreservingViewport()
                return true
            }
            return false

        case #selector(NSResponder.cancelOperation(_:)):
            finishEditing(commit: true)
            store.selectNode(nodeId)
            reloadPreservingViewport()
            return true

        default:
            return false
        }
    }

    fileprivate func pasteIntoCurrentNodeOrAfter() -> Bool {
        guard let nodeId = editingNodeId,
              let store else { return false }
        let pasteboard = NSPasteboard.general
        if pasteboard.data(forType: OutlineStore.nodePasteboardType) != nil {
            syncCurrentEditorText()
            let pasted = store.pasteNodes(after: nodeId)
            if pasted {
                store.markStructuralEditForUndoRoute()
                reloadPreservingViewport()
            }
            return pasted
        }
        if let text = pasteboard.string(forType: .string),
           text.contains(where: { $0 == "\n" || $0 == "\r" }) {
            syncCurrentEditorText()
            let pasted = store.pasteNodes(after: nodeId)
            if pasted {
                store.markStructuralEditForUndoRoute()
                reloadPreservingViewport()
            }
            return pasted
        }
        return false
    }

    fileprivate func selectAllVisibleNodes() {
        finishEditing(commit: true)
        finishNoteEditing(commit: true)
        store?.selectAllVisible()
        reloadPreservingViewport()
    }

    fileprivate func toggleDoneForEditingNode() {
        guard let nodeId = editingNodeId,
              let store else { return }
        syncCurrentEditorText()
        store.toggleDone(nodeId: nodeId)
        store.markStructuralEditForUndoRoute()
        reloadPreservingViewport()
    }

    fileprivate func toggleNoteForEditingNode() {
        guard let nodeId = editingNodeId,
              let store else { return }
        syncCurrentEditorText()
        store.toggleNote(nodeId: nodeId)
        reloadPreservingViewport()
    }

    fileprivate func moveEditingNodeUp() {
        guard let nodeId = editingNodeId,
              let store else { return }
        syncCurrentEditorText()
        if store.moveUp(nodeId: nodeId) {
            store.markStructuralEditForUndoRoute()
            reloadPreservingViewport()
        }
    }

    fileprivate func moveEditingNodeDown() {
        guard let nodeId = editingNodeId,
              let store else { return }
        syncCurrentEditorText()
        if store.moveDown(nodeId: nodeId) {
            store.markStructuralEditForUndoRoute()
            reloadPreservingViewport()
        }
    }

    private func rebuildRows(store: OutlineStore, availableWidth: CGFloat) {
        if measurementCache.count > 50000 {
            measurementCache.removeAll(keepingCapacity: true)
        }

        let visibleNodes = store.visibleNodes()
        var nextRows: [AppKitOutlineRow] = []
        var y = store.zoomPath.isEmpty ? AppKitOutlineMetrics.topPaddingExpanded : AppKitOutlineMetrics.topPaddingZoomed
        let width = max(availableWidth, 1)

        for item in visibleNodes {
            let textX = AppKitOutlineMetrics.textX(depth: item.depth)
            let textWidth = max(80, width - textX - AppKitOutlineMetrics.rightPadding)
            let textHeight = measuredTextHeight(
                for: item.node,
                width: textWidth,
                searchQuery: store.isSearchActive ? store.searchQuery : ""
            )
            let isEditingNote = store.editingNoteId == item.node.id
            let noteHeight = item.node.note.isEmpty && !isEditingNote
                ? 0
                : max(AppKitOutlineMetrics.noteMinimumHeight, measuredNoteHeight(item.node.note, width: textWidth))
            let rowContentHeight = max(AppKitOutlineMetrics.rowControlHeight, textHeight)
            let rowHeight = AppKitOutlineMetrics.rowVerticalPadding
                + rowContentHeight
                + (noteHeight > 0 ? AppKitOutlineMetrics.noteSpacing + noteHeight : 0)
                + AppKitOutlineMetrics.rowVerticalPadding

            let rowFrame = CGRect(x: 0, y: y, width: width, height: rowHeight)
            let controlY = y + AppKitOutlineMetrics.rowVerticalPadding
            let depthX = AppKitOutlineMetrics.horizontalPadding + CGFloat(item.depth) * AppKitOutlineMetrics.indentWidth
            let checkboxFrame = CGRect(x: depthX, y: controlY, width: AppKitOutlineMetrics.checkboxWidth, height: AppKitOutlineMetrics.rowControlHeight)
            let chevronFrame = CGRect(x: checkboxFrame.maxX, y: controlY, width: AppKitOutlineMetrics.chevronWidth, height: AppKitOutlineMetrics.rowControlHeight)
            let bulletFrame = CGRect(x: chevronFrame.maxX, y: controlY, width: AppKitOutlineMetrics.bulletWidth, height: AppKitOutlineMetrics.rowControlHeight)
            let textFrame = CGRect(x: textX, y: controlY, width: textWidth, height: textHeight)
            let noteFrame: CGRect? = noteHeight > 0
                ? CGRect(x: textX, y: textFrame.maxY + AppKitOutlineMetrics.noteSpacing, width: textWidth, height: noteHeight)
                : nil

            nextRows.append(AppKitOutlineRow(
                node: item.node,
                depth: item.depth,
                frame: rowFrame,
                checkboxFrame: checkboxFrame,
                chevronFrame: chevronFrame,
                bulletFrame: bulletFrame,
                textFrame: textFrame,
                noteFrame: noteFrame
            ))
            y += rowHeight
        }

        rows = nextRows
        rowById = Dictionary(uniqueKeysWithValues: nextRows.map { ($0.node.id, $0) })

        let targetHeight = max(y + AppKitOutlineMetrics.bottomPadding, enclosingScrollView?.contentView.bounds.height ?? 0)
        frame = CGRect(x: 0, y: 0, width: width, height: targetHeight)
    }

    private func reloadPreservingViewport() {
        guard let scrollView = enclosingScrollView else {
            reloadData(availableWidth: lastAvailableWidth, visibleRect: lastVisibleRect)
            return
        }
        reloadData(availableWidth: scrollView.contentView.bounds.width, visibleRect: scrollView.contentView.bounds)
    }

    private func applyPendingFocusIfNeeded() {
        guard let store,
              let focusId = store.pendingFocusId,
              rowById[focusId] != nil else { return }
        let cursorPosition = store.pendingCursorPosition
        let shouldScroll = store.shouldScrollToPendingFocus
        store.clearPendingFocus()
        beginEditing(focusId, cursorPosition: cursorPosition, scrollIntoView: false)
        if shouldScroll, let row = rowById[focusId] {
            scrollToVisible(row.frame.insetBy(dx: 0, dy: -20))
        }
    }

    private func applyPendingNoteFocusIfNeeded() {
        guard let store,
              let noteId = store.pendingNoteFocusId,
              rowById[noteId] != nil else { return }
        store.pendingNoteFocusId = nil
        beginNoteEditing(noteId)
    }

    private func beginEditing(_ nodeId: UUID, cursorPosition: Int?, scrollIntoView: Bool = false) {
        guard let store,
              let node = store.root.find(id: nodeId),
              let row = rowById[nodeId] else { return }

        if editingNodeId != nodeId {
            finishEditing(commit: true)
        }
        finishNoteEditing(commit: true)

        store.editingNodeId = nodeId
        store.focusedEditorNodeId = nodeId
        store.clearSelection()
        store.saveUndoStateIfModified()
        editingNodeId = nodeId

        let textView = ensureEditorTextView()
        suppressTextDidChange = true
        textView.textStorage?.setAttributedString(editorAttributedString(for: node, store: store))
        suppressTextDidChange = false
        textView.frame = editorFrame(for: row)
        textView.isHidden = false

        if textView.superview == nil {
            addSubview(textView)
        }
        window?.makeFirstResponder(textView)

        let length = (textView.string as NSString).length
        let target = min(cursorPosition ?? length, length)
        textView.setSelectedRange(NSRange(location: target, length: 0))
        textView.typingAttributes = OutlineTextField.typingAttributes(
            in: textView.textStorage ?? NSTextStorage(),
            near: textView.selectedRange,
            fallbackFont: OutlineTextField.font,
            fallbackColor: node.isDone ? .tertiaryLabelColor : .labelColor
        )

        if scrollIntoView {
            scrollToVisible(row.frame.insetBy(dx: 0, dy: -20))
        }
        setNeedsDisplay(row.frame)
    }

    private func finishEditing(commit: Bool) {
        if commit {
            syncCurrentEditorText()
        }
        if let store, let editingNodeId {
            if store.editingNodeId == editingNodeId {
                store.editingNodeId = nil
            }
            if store.focusedEditorNodeId == editingNodeId {
                store.focusedEditorNodeId = nil
            }
        }
        editingNodeId = nil
        editorTextView?.isHidden = true
        if window?.firstResponder === editorTextView {
            window?.makeFirstResponder(self)
        }
        setNeedsDisplay(bounds)
    }

    private func beginNoteEditing(_ nodeId: UUID) {
        guard let store,
              let node = store.root.find(id: nodeId),
              rowById[nodeId] != nil else { return }

        finishEditing(commit: true)
        store.editingNoteId = nodeId
        store.pendingNoteFocusId = nil
        store.clearSelection()

        rebuildRows(store: store, availableWidth: lastAvailableWidth)

        let textView = ensureNoteTextView()
        suppressTextDidChange = true
        textView.string = node.note
        suppressTextDidChange = false
        textView.font = AppKitOutlineMetrics.noteFont
        textView.textColor = .secondaryLabelColor
        updateNoteEditorFrame()
        textView.isHidden = false
        if textView.superview == nil {
            addSubview(textView)
        }
        window?.makeFirstResponder(textView)
        let length = (textView.string as NSString).length
        textView.setSelectedRange(NSRange(location: length, length: 0))
        setNeedsDisplay(bounds)
    }

    private func finishNoteEditing(commit: Bool) {
        if commit {
            syncCurrentNoteText()
        }
        if let store, let editingNoteId = store.editingNoteId {
            store.editingNoteId = nil
            store.pendingNoteFocusId = nil
            setNeedsDisplay(rowById[editingNoteId]?.frame ?? bounds)
        }
        noteTextView?.isHidden = true
        if window?.firstResponder === noteTextView {
            window?.makeFirstResponder(self)
        }
    }

    private func syncCurrentEditorText() {
        guard let nodeId = editingNodeId,
              let textView = editorTextView,
              let store,
              let node = store.root.find(id: nodeId) else { return }
        node.text = textView.string
        node.formatting = Self.extractFormatting(from: textView.textStorage)
    }

    private func syncCurrentNoteText() {
        guard let textView = noteTextView,
              let store,
              let nodeId = store.editingNoteId,
              let node = store.root.find(id: nodeId) else { return }
        node.note = textView.string
    }

    private func ensureEditorTextView() -> AppKitOutlineEditorTextView {
        if let editorTextView {
            return editorTextView
        }

        let textView = AppKitOutlineEditorTextView(frame: .zero)
        textView.outlineView = self
        textView.delegate = self
        textView.drawsBackground = false
        textView.isRichText = true
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = false
        textView.font = OutlineTextField.font
        textView.textColor = .labelColor
        textView.insertionPointColor = .controlAccentColor
        editorTextView = textView
        return textView
    }

    private func ensureNoteTextView() -> AppKitOutlineNoteTextView {
        if let noteTextView {
            return noteTextView
        }

        let textView = AppKitOutlineNoteTextView(frame: .zero)
        textView.outlineView = self
        textView.delegate = self
        textView.drawsBackground = false
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = false
        textView.font = AppKitOutlineMetrics.noteFont
        textView.textColor = .secondaryLabelColor
        textView.insertionPointColor = .controlAccentColor
        noteTextView = textView
        return textView
    }

    private func updateEditorFrame() {
        guard let editingNodeId,
              let row = rowById[editingNodeId],
              let textView = editorTextView else { return }
        textView.frame = editorFrame(for: row)
    }

    private func updateNoteEditorFrame() {
        guard let store,
              let noteId = store.editingNoteId,
              let row = rowById[noteId],
              let textView = noteTextView else {
            noteTextView?.isHidden = true
            return
        }
        if let noteFrame = row.noteFrame {
            textView.frame = noteFrame.insetBy(dx: 0, dy: -1)
            textView.isHidden = false
        } else {
            textView.isHidden = true
        }
    }

    private func editorFrame(for row: AppKitOutlineRow) -> CGRect {
        row.textFrame.insetBy(dx: 0, dy: -1)
    }

    private func drawRow(_ row: AppKitOutlineRow, store: OutlineStore) {
        if store.selectedNodeIds.contains(row.node.id) {
            NSColor.controlAccentColor.withAlphaComponent(0.15).setFill()
            NSBezierPath(roundedRect: row.frame.insetBy(dx: 2, dy: 0), xRadius: 5, yRadius: 5).fill()
        }

        drawGuideLines(for: row)
        drawCheckbox(for: row, store: store)
        drawChevron(for: row)
        drawBullet(for: row, store: store)

        if editingNodeId != row.node.id {
            let attributed = displayAttributedString(for: row.node, store: store)
            attributed.draw(with: row.textFrame, options: [.usesLineFragmentOrigin, .usesFontLeading])
        }

        if let noteFrame = row.noteFrame, store.editingNoteId != row.node.id {
            let note = NSAttributedString(
                string: row.node.note.isEmpty ? "Add a note..." : row.node.note,
                attributes: [
                    .font: AppKitOutlineMetrics.noteFont,
                    .foregroundColor: row.node.note.isEmpty ? NSColor.tertiaryLabelColor : NSColor.secondaryLabelColor,
                    .paragraphStyle: OutlineTextField.paragraphStyle
                ]
            )
            note.draw(with: noteFrame, options: [.usesLineFragmentOrigin, .usesFontLeading])
        }
    }

    private func drawGuideLines(for row: AppKitOutlineRow) {
        guard row.depth > 0 else { return }
        NSColor.labelColor.withAlphaComponent(0.08).setStroke()
        for level in 0..<row.depth {
            let x = AppKitOutlineMetrics.guideX(level: level)
            let path = NSBezierPath()
            path.lineWidth = 1
            path.move(to: CGPoint(x: x, y: row.frame.minY))
            path.line(to: CGPoint(x: x, y: row.frame.maxY))
            path.stroke()
        }
    }

    private func drawCheckbox(for row: AppKitOutlineRow, store: OutlineStore) {
        guard row.node.isDone || store.hoveredRowId == row.node.id else { return }
        let rect = row.checkboxFrame.insetBy(dx: 3.5, dy: 5.5)
        let path = NSBezierPath(ovalIn: rect)
        path.lineWidth = 1.4

        if row.node.isDone {
            NSColor.labelColor.withAlphaComponent(0.30).setFill()
            path.fill()
            NSColor.textBackgroundColor.withAlphaComponent(0.85).setStroke()
            let check = NSBezierPath()
            check.lineWidth = 1.5
            check.lineCapStyle = .round
            check.lineJoinStyle = .round
            check.move(to: CGPoint(x: rect.minX + rect.width * 0.28, y: rect.midY))
            check.line(to: CGPoint(x: rect.minX + rect.width * 0.44, y: rect.maxY - rect.height * 0.30))
            check.line(to: CGPoint(x: rect.maxX - rect.width * 0.22, y: rect.minY + rect.height * 0.28))
            check.stroke()
        } else {
            NSColor.labelColor.withAlphaComponent(0.10).setStroke()
            path.stroke()
        }
    }

    private func drawChevron(for row: AppKitOutlineRow) {
        guard !row.node.children.isEmpty else { return }
        let rect = row.chevronFrame
        let center = CGPoint(x: rect.midX + 1, y: rect.midY)
        let path = NSBezierPath()
        path.lineWidth = 1.6
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        NSColor.labelColor.withAlphaComponent(0.25).setStroke()

        if row.node.isExpanded {
            path.move(to: CGPoint(x: center.x - 4, y: center.y - 2))
            path.line(to: CGPoint(x: center.x, y: center.y + 2))
            path.line(to: CGPoint(x: center.x + 4, y: center.y - 2))
        } else {
            path.move(to: CGPoint(x: center.x - 2, y: center.y - 4))
            path.line(to: CGPoint(x: center.x + 2, y: center.y))
            path.line(to: CGPoint(x: center.x - 2, y: center.y + 4))
        }
        path.stroke()
    }

    private func drawBullet(for row: AppKitOutlineRow, store: OutlineStore) {
        let center = CGPoint(x: row.bulletFrame.midX, y: row.bulletFrame.midY)
        if store.hoveredRowId == row.node.id {
            NSColor.labelColor.withAlphaComponent(0.18).setStroke()
            let outline = NSBezierPath(ovalIn: CGRect(x: center.x - 6, y: center.y - 6, width: 12, height: 12))
            outline.lineWidth = 1.25
            outline.stroke()
        }
        NSColor.labelColor.withAlphaComponent(store.hoveredRowId == row.node.id ? 0.35 : 0.22).setFill()
        NSBezierPath(ovalIn: CGRect(x: center.x - 3, y: center.y - 3, width: 6, height: 6)).fill()
    }

    private func row(at point: CGPoint) -> AppKitOutlineRow? {
        var low = 0
        var high = rows.count - 1
        while low <= high {
            let mid = (low + high) / 2
            let row = rows[mid]
            if point.y < row.frame.minY {
                high = mid - 1
            } else if point.y > row.frame.maxY {
                low = mid + 1
            } else {
                return row
            }
        }
        return nil
    }

    private func measuredTextHeight(for node: OutlineNode, width: CGFloat, searchQuery: String) -> CGFloat {
        let key = "\(node.id.uuidString)|\(Int(width.rounded()))|\(node.text)|\(node.formatting)|\(node.isDone)|\(searchQuery)"
        if let cached = measurementCache[key] {
            return cached
        }
        let attributed = displayAttributedString(for: node, store: store)
        let height = Self.measure(attributed: attributed, width: width)
        measurementCache[key] = height
        return height
    }

    private func measuredNoteHeight(_ note: String, width: CGFloat) -> CGFloat {
        let attributed = NSAttributedString(
            string: note.isEmpty ? " " : note,
            attributes: [
                .font: AppKitOutlineMetrics.noteFont,
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: OutlineTextField.paragraphStyle
            ]
        )
        return Self.measure(attributed: attributed, width: width)
    }

    private func displayAttributedString(for node: OutlineNode, store: OutlineStore?) -> NSAttributedString {
        let baseColor: NSColor = node.isDone ? .tertiaryLabelColor : .labelColor
        let attributed = NSMutableAttributedString(attributedString: OutlineTextField.styledAttributedString(
            from: node.text.isEmpty ? " " : node.text,
            baseFont: OutlineTextField.font,
            baseColor: baseColor,
            formatting: node.formatting
        ))
        if let store, store.isSearchActive, !store.searchQuery.isEmpty {
            OutlineTextField.applySearchHighlight(to: attributed, query: store.searchQuery)
        }
        return attributed
    }

    private func editorAttributedString(for node: OutlineNode, store: OutlineStore) -> NSAttributedString {
        let baseColor: NSColor = node.isDone ? .tertiaryLabelColor : .labelColor
        let attributed = NSMutableAttributedString(attributedString: OutlineTextField.styledAttributedString(
            from: node.text,
            baseFont: OutlineTextField.font,
            baseColor: baseColor,
            formatting: node.formatting
        ))
        if store.isSearchActive, !store.searchQuery.isEmpty {
            OutlineTextField.applySearchHighlight(to: attributed, query: store.searchQuery)
        }
        return attributed
    }

    private static func measure(attributed: NSAttributedString, width: CGFloat) -> CGFloat {
        let storage = NSTextStorage(attributedString: attributed)
        let layoutManager = NSLayoutManager()
        let textContainer = NSTextContainer(size: NSSize(width: max(width, 1), height: CGFloat.greatestFiniteMagnitude))
        textContainer.lineFragmentPadding = 0
        textContainer.widthTracksTextView = false
        textContainer.heightTracksTextView = false
        layoutManager.addTextContainer(textContainer)
        storage.addLayoutManager(layoutManager)
        layoutManager.ensureLayout(for: textContainer)
        let rect = layoutManager.usedRect(for: textContainer)
        return max(ceil(rect.height) + 6, AppKitOutlineMetrics.rowControlHeight)
    }

    private func characterIndex(at point: CGPoint, in row: AppKitOutlineRow) -> Int {
        let attributed = displayAttributedString(for: row.node, store: store)
        let storage = NSTextStorage(attributedString: attributed)
        let layoutManager = NSLayoutManager()
        let textContainer = NSTextContainer(size: NSSize(width: row.textFrame.width, height: CGFloat.greatestFiniteMagnitude))
        textContainer.lineFragmentPadding = 0
        layoutManager.addTextContainer(textContainer)
        storage.addLayoutManager(layoutManager)
        layoutManager.ensureLayout(for: textContainer)
        let local = CGPoint(x: max(0, point.x - row.textFrame.minX), y: max(0, point.y - row.textFrame.minY))
        let index = layoutManager.characterIndex(
            for: local,
            in: textContainer,
            fractionOfDistanceBetweenInsertionPoints: nil
        )
        return min(index, (row.node.text as NSString).length)
    }

    private static func extractFormatting(from storage: NSTextStorage?) -> [TextFormattingSpan] {
        guard let storage else { return [] }
        var spans: [TextFormattingSpan] = []
        let fullRange = NSRange(location: 0, length: storage.length)
        guard fullRange.length > 0 else { return [] }

        storage.enumerateAttribute(.font, in: fullRange) { value, range, _ in
            guard range.length > 0, let font = value as? NSFont else { return }
            let traits = NSFontManager.shared.traits(of: font)
            if traits.contains(.boldFontMask) {
                spans.append(TextFormattingSpan(kind: .bold, location: range.location, length: range.length))
            }
            if traits.contains(.italicFontMask) {
                spans.append(TextFormattingSpan(kind: .italic, location: range.location, length: range.length))
            }
        }

        storage.enumerateAttribute(OutlineTextField.formattingAttribute, in: fullRange) { value, range, _ in
            guard range.length > 0,
                  let rawValue = value as? String,
                  let kind = TextFormattingKind(rawValue: rawValue) else { return }
            switch kind {
            case .highlight:
                spans.append(TextFormattingSpan(kind: .highlight, location: range.location, length: range.length))
            case .underline:
                spans.append(TextFormattingSpan(kind: .underline, location: range.location, length: range.length))
            case .bold, .italic, .link:
                return
            }
        }

        storage.enumerateAttribute(.link, in: fullRange) { value, range, _ in
            guard range.length > 0 else { return }
            let urlString = (value as? URL)?.absoluteString ?? (value as? String)
            guard let urlString, !urlString.isEmpty else { return }
            spans.append(TextFormattingSpan(kind: .link, location: range.location, length: range.length, url: urlString))
        }

        return spans.normalized(forTextLength: fullRange.length)
    }
}
