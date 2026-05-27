import SwiftUI
import AppKit

struct OutlineTextField: NSViewRepresentable {
    let nodeId: UUID
    @Binding var text: String
    var isDone: Bool
    var shouldFocus: Bool
    var cursorPosition: Int?

    var onCommit: (Int) -> Void
    var onTab: () -> Void
    var onBackTab: () -> Void
    var onMoveUp: () -> Void
    var onMoveDown: () -> Void
    var onDelete: () -> Void
    var onMergeWithPrevious: () -> Void
    var onToggleDone: () -> Void
    var onMoveNodeUp: () -> Void
    var onMoveNodeDown: () -> Void
    var onZoomIn: () -> Void
    var onEscape: () -> Void
    var onDidFocus: () -> Void
    var onTextChange: () -> Void
    var onSelectAllNodes: () -> Void
    var onBeginEditing: () -> Void
    var onShiftUp: () -> Void
    var onShiftDown: () -> Void
    var onPasteNodes: () -> Void
    var searchQuery: String

    private static let fontSize: CGFloat = 15
    static let font = NSFont.systemFont(ofSize: 15, weight: .regular)
    static let paragraphStyle: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byWordWrapping
        return style
    }()

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> StrataTextField {
        let tf = StrataTextField()
        tf.isBordered = false
        tf.drawsBackground = false
        tf.backgroundColor = .clear
        tf.focusRingType = .none
        tf.lineBreakMode = .byWordWrapping
        tf.cell?.isScrollable = false
        tf.cell?.wraps = true
        tf.usesSingleLineMode = false
        tf.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        tf.delegate = context.coordinator
        tf.placeholderAttributedString = NSAttributedString(
            string: "...",
            attributes: [
                .font: Self.font,
                .foregroundColor: NSColor.secondaryLabelColor
            ]
        )
        tf.onCmdEnter = { context.coordinator.parent.onToggleDone() }
        tf.onCmdShiftUp = { context.coordinator.parent.onMoveNodeUp() }
        tf.onCmdShiftDown = { context.coordinator.parent.onMoveNodeDown() }
        tf.onSelectAllNodes = { context.coordinator.parent.onSelectAllNodes() }
        tf.onZoomIn = { context.coordinator.parent.onZoomIn() }
        tf.onTab = { context.coordinator.parent.onTab() }
        tf.onBackTab = { context.coordinator.parent.onBackTab() }
        tf.onShiftUp = { context.coordinator.parent.onShiftUp() }
        tf.onShiftDown = { context.coordinator.parent.onShiftDown() }
        tf.onPasteNodes = { context.coordinator.parent.onPasteNodes() }

        // Set baseline font once — used for layout sizing and placeholder
        tf.font = Self.font
        tf.textColor = .labelColor

        applyStyle(tf)

        // Also check shouldFocus on creation — when a node moves
        // (indent/unindent), SwiftUI creates a fresh NSView via makeNSView
        // instead of calling updateNSView on the old one.
        if shouldFocus {
            let pos = cursorPosition
            DispatchQueue.main.async {
                tf.window?.makeFirstResponder(tf)
                if let editor = tf.currentEditor() {
                    let target = pos ?? (tf.stringValue as NSString).length
                    editor.selectedRange = NSRange(location: min(target, (tf.stringValue as NSString).length), length: 0)
                }
                onDidFocus()
            }
        }

        return tf
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: StrataTextField, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0, width < CGFloat.greatestFiniteMagnitude else {
            return nil
        }

        nsView.preferredMaxLayoutWidth = width

        if let cell = nsView.cell {
            let rect = NSRect(x: 0, y: 0, width: width, height: CGFloat.greatestFiniteMagnitude)
            let size = cell.cellSize(forBounds: rect)
            return CGSize(width: width, height: max(size.height, 22))
        }
        return nil
    }

    func updateNSView(_ nsView: StrataTextField, context: Context) {
        context.coordinator.parent = self

        nsView.onCmdEnter = { onToggleDone() }
        nsView.onCmdShiftUp = { onMoveNodeUp() }
        nsView.onCmdShiftDown = { onMoveNodeDown() }
        nsView.onSelectAllNodes = { onSelectAllNodes() }
        nsView.onZoomIn = { onZoomIn() }
        nsView.onTab = { onTab() }
        nsView.onBackTab = { onBackTab() }
        nsView.onShiftUp = { onShiftUp() }
        nsView.onShiftDown = { onShiftDown() }
        nsView.onPasteNodes = { onPasteNodes() }

        applyStyle(nsView)

        if shouldFocus {
            let pos = cursorPosition
            DispatchQueue.main.async {
                nsView.window?.makeFirstResponder(nsView)
                if let editor = nsView.currentEditor() {
                    let target = pos ?? (nsView.stringValue as NSString).length
                    editor.selectedRange = NSRange(location: min(target, (nsView.stringValue as NSString).length), length: 0)
                }
                onDidFocus()
            }
        }
    }

    private func applyStyle(_ tf: StrataTextField) {
        let font = Self.font
        let currentText = text
        let searchQ = searchQuery
        let isDone = isDone
        let baseColor: NSColor = isDone ? .tertiaryLabelColor : .labelColor
        let markerColor = NSColor.tertiaryLabelColor

        // NOTE: Do NOT set tf.font or tf.textColor here.
        // Setting tf.font strips all font attributes from attributedStringValue
        // (bold, italic, code), causing a visible flash of unstyled text before
        // the styled version is reapplied. The font is set once in makeNSView;
        // all per-character styling goes through attributedStringValue (non-editing)
        // or textStorage (editing).

        if let editor = tf.currentEditor() as? NSTextView,
           let storage = editor.textStorage {
            // Editing mode — sync text if changed externally (undo/redo)
            var textWasReplaced = false
            if storage.string != currentText {
                let range = editor.selectedRange
                storage.beginEditing()
                storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: currentText)
                storage.endEditing()
                let safeLoc = min(range.location, (currentText as NSString).length)
                editor.setSelectedRange(NSRange(location: safeLoc, length: 0))
                textWasReplaced = true
            }

            // Skip restyling if text and state haven't changed since last restyle
            if !textWasReplaced &&
               tf.lastStyledText == storage.string &&
               tf.lastStyledDone == isDone &&
               tf.lastStyledSearch == searchQ {
                return
            }

            // Restyle text storage attributes
            let savedRange = editor.selectedRange
            let fullRange = NSRange(location: 0, length: storage.length)

            storage.beginEditing()
            storage.addAttributes([.font: font, .foregroundColor: baseColor, .paragraphStyle: Self.paragraphStyle], range: fullRange)
            storage.removeAttribute(.backgroundColor, range: fullRange)
            if !isDone {
                Self.applyMarkdownAttributes(to: storage, baseFont: font, baseColor: baseColor, markerColor: markerColor)
            }
            if !searchQ.isEmpty {
                Self.applySearchHighlight(to: storage, query: searchQ)
            }
            storage.endEditing()

            if savedRange.location + savedRange.length <= storage.length {
                editor.setSelectedRange(savedRange)
            }

            tf.lastStyledText = storage.string
            tf.lastStyledDone = isDone
            tf.lastStyledSearch = searchQ
        } else {
            // Not editing — build styled attributed string directly
            let styled: NSAttributedString
            if isDone {
                styled = NSAttributedString(
                    string: currentText,
                    attributes: [.font: font, .foregroundColor: baseColor, .paragraphStyle: Self.paragraphStyle]
                )
            } else {
                styled = Self.styledAttributedString(
                    from: currentText, baseFont: font,
                    baseColor: baseColor, markerColor: markerColor
                )
            }

            if !searchQ.isEmpty {
                let mutable = NSMutableAttributedString(attributedString: styled)
                Self.applySearchHighlight(to: mutable, query: searchQ)
                tf.attributedStringValue = mutable
            } else {
                tf.attributedStringValue = styled
            }

            // Clear style cache when not editing so next edit session restyles
            tf.lastStyledText = nil
        }
    }

    // MARK: - Markdown Styling

    private static func styledAttributedString(
        from text: String,
        baseFont: NSFont,
        baseColor: NSColor,
        markerColor: NSColor
    ) -> NSAttributedString {
        let attributed = NSMutableAttributedString(
            string: text,
            attributes: [.font: baseFont, .foregroundColor: baseColor, .paragraphStyle: paragraphStyle]
        )
        applyMarkdownAttributes(to: attributed, baseFont: baseFont, baseColor: baseColor, markerColor: markerColor)
        return attributed
    }

    static func applyMarkdownAttributes(
        to attributed: NSMutableAttributedString,
        baseFont: NSFont,
        baseColor: NSColor,
        markerColor: NSColor
    ) {
        let text = attributed.string
        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        guard fullRange.length > 0 else { return }

        var styledRanges: [NSRange] = []

        // 1. Code spans: `text`
        if let codeRegex = try? NSRegularExpression(pattern: "`([^`]+)`") {
            for match in codeRegex.matches(in: text, range: fullRange) {
                let matchRange = match.range
                let contentRange = match.range(at: 1)

                let codeFont = NSFont.monospacedSystemFont(ofSize: baseFont.pointSize - 1, weight: .regular)
                attributed.addAttributes([
                    .font: codeFont,
                    .backgroundColor: NSColor.quaternaryLabelColor
                ], range: contentRange)

                // Dim the backtick markers
                attributed.addAttribute(.foregroundColor, value: markerColor,
                    range: NSRange(location: matchRange.location, length: 1))
                attributed.addAttribute(.foregroundColor, value: markerColor,
                    range: NSRange(location: matchRange.location + matchRange.length - 1, length: 1))

                styledRanges.append(matchRange)
            }
        }

        // 2. Bold: **text**
        if let boldRegex = try? NSRegularExpression(pattern: "\\*\\*(.+?)\\*\\*") {
            for match in boldRegex.matches(in: text, range: fullRange) {
                let matchRange = match.range
                if styledRanges.contains(where: { NSIntersectionRange($0, matchRange).length > 0 }) { continue }

                let contentRange = match.range(at: 1)
                let boldFont = NSFont.systemFont(ofSize: baseFont.pointSize, weight: .semibold)
                attributed.addAttribute(.font, value: boldFont, range: contentRange)

                // Dim the ** markers
                attributed.addAttribute(.foregroundColor, value: markerColor,
                    range: NSRange(location: matchRange.location, length: 2))
                attributed.addAttribute(.foregroundColor, value: markerColor,
                    range: NSRange(location: matchRange.location + matchRange.length - 2, length: 2))

                styledRanges.append(matchRange)
            }
        }

        // 3. Italic: *text* (single *, not **)
        if let italicRegex = try? NSRegularExpression(pattern: "(?<!\\*)\\*(?!\\*)(.+?)(?<!\\*)\\*(?!\\*)") {
            for match in italicRegex.matches(in: text, range: fullRange) {
                let matchRange = match.range
                if styledRanges.contains(where: { NSIntersectionRange($0, matchRange).length > 0 }) { continue }

                let contentRange = match.range(at: 1)
                let italicFont = NSFontManager.shared.convert(baseFont, toHaveTrait: .italicFontMask)
                attributed.addAttribute(.font, value: italicFont, range: contentRange)

                // Dim the * markers
                attributed.addAttribute(.foregroundColor, value: markerColor,
                    range: NSRange(location: matchRange.location, length: 1))
                attributed.addAttribute(.foregroundColor, value: markerColor,
                    range: NSRange(location: matchRange.location + matchRange.length - 1, length: 1))

                styledRanges.append(matchRange)
            }
        }

        // 4. Highlight: ==text==
        if let highlightRegex = try? NSRegularExpression(pattern: "==(.+?)==") {
            for match in highlightRegex.matches(in: text, range: fullRange) {
                let matchRange = match.range
                if styledRanges.contains(where: { NSIntersectionRange($0, matchRange).length > 0 }) { continue }

                let contentRange = match.range(at: 1)
                attributed.addAttribute(.backgroundColor,
                    value: NSColor.systemYellow.withAlphaComponent(0.3), range: contentRange)

                // Dim the == markers
                attributed.addAttribute(.foregroundColor, value: markerColor,
                    range: NSRange(location: matchRange.location, length: 2))
                attributed.addAttribute(.foregroundColor, value: markerColor,
                    range: NSRange(location: matchRange.location + matchRange.length - 2, length: 2))

                styledRanges.append(matchRange)
            }
        }
    }

    static func applySearchHighlight(to attributed: NSMutableAttributedString, query: String) {
        let text = attributed.string
        let nsText = text as NSString
        guard !query.isEmpty, nsText.length > 0 else { return }

        let highlightColor = NSColor.systemOrange.withAlphaComponent(0.3)
        var searchStart = 0

        while searchStart < nsText.length {
            let remaining = NSRange(location: searchStart, length: nsText.length - searchStart)
            let range = nsText.range(of: query, options: .caseInsensitive, range: remaining)
            guard range.location != NSNotFound else { break }
            attributed.addAttribute(.backgroundColor, value: highlightColor, range: range)
            searchStart = range.location + range.length
        }
    }

    // MARK: - Coordinator

    class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: OutlineTextField

        init(parent: OutlineTextField) {
            self.parent = parent
        }

        func controlTextDidBeginEditing(_ obj: Notification) {
            parent.onBeginEditing()

            // Configure field editor: fix text shift + enable wrapping
            if let tf = obj.object as? StrataTextField,
               let editor = tf.currentEditor() as? NSTextView {
                editor.textContainerInset = .zero
                editor.textContainer?.lineFragmentPadding = 0
                editor.textContainer?.widthTracksTextView = true
                editor.isHorizontallyResizable = false
                editor.isVerticallyResizable = true

                // Install right-click context menu monitor for formatting
                tf.installContextMenuMonitor()
            }
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let tf = obj.object as? StrataTextField else { return }
            let newValue = tf.stringValue
            guard newValue != parent.text else { return }
            parent.text = newValue
            parent.onTextChange()
            tf.invalidateIntrinsicContentSize()

            // Immediately restyle to prevent formatting jumps between keystrokes
            Self.restyleEditor(tf, parent: parent)
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            if let tf = obj.object as? StrataTextField {
                tf.removeContextMenuMonitor()
                tf.lastStyledText = nil
            }
        }

        /// Restyle the text storage immediately after a text change to prevent
        /// the brief flash of unstyled text that causes "formatting jumps".
        static func restyleEditor(_ tf: StrataTextField, parent: OutlineTextField) {
            guard let editor = tf.currentEditor() as? NSTextView,
                  let storage = editor.textStorage else { return }

            let savedRange = editor.selectedRange
            let fullRange = NSRange(location: 0, length: storage.length)
            let font = OutlineTextField.font
            let isDone = parent.isDone
            let baseColor: NSColor = isDone ? .tertiaryLabelColor : .labelColor
            let markerColor = NSColor.tertiaryLabelColor
            let searchQ = parent.searchQuery

            storage.beginEditing()
            storage.addAttributes([
                .font: font,
                .foregroundColor: baseColor,
                .paragraphStyle: OutlineTextField.paragraphStyle
            ], range: fullRange)
            storage.removeAttribute(.backgroundColor, range: fullRange)
            if !isDone {
                OutlineTextField.applyMarkdownAttributes(to: storage, baseFont: font, baseColor: baseColor, markerColor: markerColor)
            }
            if !searchQ.isEmpty {
                OutlineTextField.applySearchHighlight(to: storage, query: searchQ)
            }
            storage.endEditing()

            if savedRange.location + savedRange.length <= storage.length {
                editor.setSelectedRange(savedRange)
            }

            tf.lastStyledText = storage.string
            tf.lastStyledDone = isDone
            tf.lastStyledSearch = searchQ
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.insertNewline(_:)):
                let offset = textView.selectedRange.location
                parent.onCommit(offset)
                return true
            case #selector(NSResponder.insertTab(_:)):
                parent.onTab()
                return true
            case #selector(NSResponder.insertBacktab(_:)):
                parent.onBackTab()
                return true
            case #selector(NSResponder.moveUp(_:)):
                parent.onMoveUp()
                return true
            case #selector(NSResponder.moveDown(_:)):
                parent.onMoveDown()
                return true
            case #selector(NSResponder.moveUpAndModifySelection(_:)):
                parent.onShiftUp()
                control.window?.makeFirstResponder(nil)
                return true
            case #selector(NSResponder.moveDownAndModifySelection(_:)):
                parent.onShiftDown()
                control.window?.makeFirstResponder(nil)
                return true
            case #selector(NSResponder.deleteBackward(_:)):
                if parent.text.isEmpty {
                    parent.onDelete()
                    return true
                }
                // Cursor at start of non-empty text -> merge with previous node
                if textView.selectedRange.location == 0 && textView.selectedRange.length == 0 {
                    parent.onMergeWithPrevious()
                    return true
                }
                return false
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onEscape()
                return true
            default:
                return false
            }
        }
    }
}

// MARK: - StrataTextField

class StrataTextField: NSTextField {
    private var lastKnownWidth: CGFloat = 0

    // Style tracking to avoid redundant restyling in updateNSView
    var lastStyledText: String?
    var lastStyledDone: Bool?
    var lastStyledSearch: String?

    // Context menu event monitor
    private var rightClickMonitor: Any?

    override var intrinsicContentSize: NSSize {
        if preferredMaxLayoutWidth > 0, let cell = cell {
            let rect = NSRect(x: 0, y: 0, width: preferredMaxLayoutWidth, height: CGFloat.greatestFiniteMagnitude)
            let size = cell.cellSize(forBounds: rect)
            return NSSize(width: NSView.noIntrinsicMetric, height: max(size.height, 22))
        }
        return super.intrinsicContentSize
    }

    override func layout() {
        super.layout()
        if bounds.width != lastKnownWidth && bounds.width > 0 {
            lastKnownWidth = bounds.width
            preferredMaxLayoutWidth = bounds.width
            invalidateIntrinsicContentSize()
        }
    }

    deinit {
        removeContextMenuMonitor()
    }

    var onCmdEnter: (() -> Void)?
    var onCmdShiftUp: (() -> Void)?
    var onCmdShiftDown: (() -> Void)?
    var onSelectAllNodes: (() -> Void)?
    var onZoomIn: (() -> Void)?
    var onTab: (() -> Void)?
    var onBackTab: (() -> Void)?
    var onShiftUp: (() -> Void)?
    var onShiftDown: (() -> Void)?
    var onPasteNodes: (() -> Void)?

    // MARK: - Context Menu

    func installContextMenuMonitor() {
        removeContextMenuMonitor()
        rightClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown]) { [weak self] event in
            guard let self = self,
                  let editor = self.currentEditor() as? NSTextView,
                  let eventWindow = event.window,
                  eventWindow == self.window else {
                return event
            }
            let locationInEditor = editor.convert(event.locationInWindow, from: nil)
            if editor.bounds.contains(locationInEditor) {
                let menu = self.buildContextMenu()
                NSMenu.popUpContextMenu(menu, with: event, for: editor)
                return nil
            }
            return event
        }
    }

    func removeContextMenuMonitor() {
        if let monitor = rightClickMonitor {
            NSEvent.removeMonitor(monitor)
            rightClickMonitor = nil
        }
    }

    private func buildContextMenu() -> NSMenu {
        let menu = NSMenu()

        let boldItem = NSMenuItem(title: "Bold", action: #selector(wrapBold), keyEquivalent: "b")
        boldItem.keyEquivalentModifierMask = .command
        boldItem.target = self
        menu.addItem(boldItem)

        let italicItem = NSMenuItem(title: "Italic", action: #selector(wrapItalic), keyEquivalent: "i")
        italicItem.keyEquivalentModifierMask = .command
        italicItem.target = self
        menu.addItem(italicItem)

        let codeItem = NSMenuItem(title: "Code", action: #selector(wrapCode), keyEquivalent: "e")
        codeItem.keyEquivalentModifierMask = .command
        codeItem.target = self
        menu.addItem(codeItem)

        let highlightItem = NSMenuItem(title: "Highlight", action: #selector(wrapHighlight), keyEquivalent: "")
        highlightItem.target = self
        menu.addItem(highlightItem)

        menu.addItem(NSMenuItem.separator())

        menu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "")
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "")

        return menu
    }

    // MARK: - Formatting (Toggle)

    @objc func wrapBold() { toggleWrap(prefix: "**", suffix: "**") }
    @objc func wrapItalic() { toggleWrap(prefix: "*", suffix: "*") }
    @objc func wrapCode() { toggleWrap(prefix: "`", suffix: "`") }
    @objc func wrapHighlight() { toggleWrap(prefix: "==", suffix: "==") }

    /// Toggle inline formatting markers around the selection or cursor.
    /// If the selection is already wrapped with the given prefix/suffix, unwrap it.
    /// If no selection, toggle empty markers at the cursor position.
    private func toggleWrap(prefix: String, suffix: String) {
        guard let editor = currentEditor() as? NSTextView,
              let storage = editor.textStorage else { return }
        let range = editor.selectedRange
        let text = storage.string as NSString
        let prefixLen = (prefix as NSString).length
        let suffixLen = (suffix as NSString).length

        if range.length > 0 {
            let selectedText = text.substring(with: range)
            let nsSelected = selectedText as NSString

            // Case 1: Markers surround the selection (just outside it)
            let beforeStart = range.location - prefixLen
            let afterEnd = range.location + range.length
            if beforeStart >= 0 && afterEnd + suffixLen <= text.length {
                let beforeText = text.substring(with: NSRange(location: beforeStart, length: prefixLen))
                let afterText = text.substring(with: NSRange(location: afterEnd, length: suffixLen))
                if beforeText == prefix && afterText == suffix {
                    // Unwrap: remove the surrounding markers
                    let fullRange = NSRange(location: beforeStart, length: prefixLen + range.length + suffixLen)
                    if editor.shouldChangeText(in: fullRange, replacementString: selectedText) {
                        storage.replaceCharacters(in: fullRange, with: selectedText)
                        editor.didChangeText()
                        editor.setSelectedRange(NSRange(location: beforeStart, length: nsSelected.length))
                    }
                    return
                }
            }

            // Case 2: Selection includes the markers at its edges
            if nsSelected.length >= prefixLen + suffixLen {
                let startMarker = nsSelected.substring(to: prefixLen)
                let endMarker = nsSelected.substring(from: nsSelected.length - suffixLen)
                if startMarker == prefix && endMarker == suffix {
                    let inner = nsSelected.substring(with: NSRange(location: prefixLen, length: nsSelected.length - prefixLen - suffixLen))
                    if editor.shouldChangeText(in: range, replacementString: inner) {
                        storage.replaceCharacters(in: range, with: inner)
                        editor.didChangeText()
                        editor.setSelectedRange(NSRange(location: range.location, length: (inner as NSString).length))
                    }
                    return
                }
            }

            // Not wrapped — wrap it
            let wrapped = prefix + selectedText + suffix
            if editor.shouldChangeText(in: range, replacementString: wrapped) {
                storage.replaceCharacters(in: range, with: wrapped)
                editor.didChangeText()
                editor.setSelectedRange(NSRange(location: range.location + prefixLen, length: nsSelected.length))
            }
        } else {
            // No selection — check if cursor is between empty markers
            if range.location >= prefixLen && range.location + suffixLen <= text.length {
                let before = text.substring(with: NSRange(location: range.location - prefixLen, length: prefixLen))
                let after = text.substring(with: NSRange(location: range.location, length: suffixLen))
                if before == prefix && after == suffix {
                    // Remove the empty markers
                    let markerRange = NSRange(location: range.location - prefixLen, length: prefixLen + suffixLen)
                    if editor.shouldChangeText(in: markerRange, replacementString: "") {
                        storage.replaceCharacters(in: markerRange, with: "")
                        editor.didChangeText()
                        editor.setSelectedRange(NSRange(location: range.location - prefixLen, length: 0))
                    }
                    return
                }
            }

            // Insert markers and place cursor between them
            let insertion = prefix + suffix
            if editor.shouldChangeText(in: range, replacementString: insertion) {
                storage.replaceCharacters(in: range, with: insertion)
                editor.didChangeText()
                editor.setSelectedRange(NSRange(location: range.location + prefixLen, length: 0))
            }
        }
    }

    // MARK: - Key Handling

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Only handle shortcuts when THIS text field is being edited
        guard currentEditor() != nil else {
            return super.performKeyEquivalent(with: event)
        }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        // Tab — indent node
        if event.keyCode == 48 && flags.isEmpty {
            onTab?()
            return true
        }
        // Shift+Tab — unindent node
        if event.keyCode == 48 && flags == .shift {
            onBackTab?()
            return true
        }
        // Shift+Up — start block selection upward
        if event.keyCode == 126 && flags == .shift {
            onShiftUp?()
            self.window?.makeFirstResponder(nil)
            return true
        }
        // Shift+Down — start block selection downward
        if event.keyCode == 125 && flags == .shift {
            onShiftDown?()
            self.window?.makeFirstResponder(nil)
            return true
        }
        // Cmd+Enter — toggle done
        if event.keyCode == 36 && flags == .command {
            onCmdEnter?()
            return true
        }
        // Cmd+B — Bold (fallback if Format menu doesn't intercept)
        if event.keyCode == 11 && flags == .command {
            wrapBold()
            return true
        }
        // Cmd+I — Italic
        if event.keyCode == 34 && flags == .command {
            wrapItalic()
            return true
        }
        // Cmd+E — Code
        if event.keyCode == 14 && flags == .command {
            wrapCode()
            return true
        }
        // Cmd+Shift+H — Highlight
        if event.keyCode == 4 && flags == [.command, .shift] {
            wrapHighlight()
            return true
        }
        // Cmd+Shift+Up — move node up
        if event.keyCode == 126 && flags == [.command, .shift] {
            onCmdShiftUp?()
            return true
        }
        // Cmd+Shift+Down — move node down
        if event.keyCode == 125 && flags == [.command, .shift] {
            onCmdShiftDown?()
            return true
        }
        // Cmd+] — zoom in
        if event.keyCode == 30 && flags == .command {
            onZoomIn?()
            return true
        }
        // Cmd+V — multi-line paste creates nodes; single-line is normal paste
        if event.keyCode == 9 && flags == .command {
            if let text = NSPasteboard.general.string(forType: .string),
               text.contains("\n") || text.contains("\r") {
                onPasteNodes?()
                return true
            }
            return false
        }
        // Cmd+A — second press selects all nodes
        if event.keyCode == 0 && flags == .command {
            if let editor = currentEditor() {
                let fullRange = NSRange(location: 0, length: editor.string.count)
                if editor.selectedRange == fullRange {
                    onSelectAllNodes?()
                    return true
                }
            }
            return false
        }

        return super.performKeyEquivalent(with: event)
    }
}
