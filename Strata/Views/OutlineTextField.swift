import SwiftUI
import AppKit

struct OutlineTextField: NSViewRepresentable {
    let nodeId: UUID
    @Binding var text: String
    @Binding var formatting: [TextFormattingSpan]
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

    static let formattingAttribute = NSAttributedString.Key("family.ma.strata.formattingKind")

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
        return CGSize(width: width, height: nsView.measuredTextHeight(for: width))
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
        let currentFormatting = formatting
        let searchQ = searchQuery
        let isDone = isDone
        let baseColor: NSColor = isDone ? .tertiaryLabelColor : .labelColor

        // NOTE: Do NOT set tf.font or tf.textColor here.
        // Setting tf.font strips all font attributes from attributedStringValue
        // (bold, italic, highlight), causing a visible flash of unstyled text before
        // the styled version is reapplied. The font is set once in makeNSView;
        // all per-character styling goes through attributedStringValue (non-editing)
        // or textStorage (editing).

        if let editor = tf.currentEditor() as? NSTextView,
           let storage = editor.textStorage {
            // Editing mode — sync text if changed externally (undo/redo)
            var textWasReplaced = false
            if storage.string != currentText {
                let range = editor.selectedRange
                editor.undoManager?.disableUndoRegistration()
                storage.beginEditing()
                storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: currentText)
                storage.endEditing()
                editor.undoManager?.enableUndoRegistration()
                let safeLoc = min(range.location, (currentText as NSString).length)
                editor.setSelectedRange(NSRange(location: safeLoc, length: 0))
                textWasReplaced = true
            }

            // Skip restyling if text and state haven't changed since last restyle
            if !textWasReplaced &&
               tf.lastStyledText == storage.string &&
               tf.lastStyledFormatting == currentFormatting &&
               tf.lastStyledDone == isDone &&
               tf.lastStyledSearch == searchQ {
                return
            }

            // Restyle text storage attributes
            let savedRange = editor.selectedRange
            let fullRange = NSRange(location: 0, length: storage.length)

            editor.undoManager?.disableUndoRegistration()
            storage.beginEditing()
            storage.addAttributes([.font: font, .foregroundColor: baseColor, .paragraphStyle: Self.paragraphStyle], range: fullRange)
            storage.removeAttribute(.backgroundColor, range: fullRange)
            storage.removeAttribute(Self.formattingAttribute, range: fullRange)
            if !isDone {
                Self.applyFormatting(currentFormatting, to: storage, baseFont: font)
            }
            if !searchQ.isEmpty {
                Self.applySearchHighlight(to: storage, query: searchQ)
            }
            storage.endEditing()
            editor.undoManager?.enableUndoRegistration()

            if savedRange.location + savedRange.length <= storage.length {
                editor.setSelectedRange(savedRange)
            }

            editor.typingAttributes = [
                .font: font,
                .foregroundColor: baseColor,
                .paragraphStyle: Self.paragraphStyle
            ]

            tf.lastStyledText = storage.string
            tf.lastStyledFormatting = currentFormatting
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
                    baseColor: baseColor, formatting: currentFormatting
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
            tf.lastStyledFormatting = nil
        }
    }

    // MARK: - Rich Text Styling

    private static func styledAttributedString(
        from text: String,
        baseFont: NSFont,
        baseColor: NSColor,
        formatting: [TextFormattingSpan]
    ) -> NSAttributedString {
        let attributed = NSMutableAttributedString(
            string: text,
            attributes: [.font: baseFont, .foregroundColor: baseColor, .paragraphStyle: paragraphStyle]
        )
        applyFormatting(formatting, to: attributed, baseFont: baseFont)
        return attributed
    }

    static func applyFormatting(
        _ formatting: [TextFormattingSpan],
        to attributed: NSMutableAttributedString,
        baseFont: NSFont
    ) {
        let nsText = attributed.string as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        guard fullRange.length > 0 else { return }

        func applyFontTrait(_ trait: NSFontTraitMask, to range: NSRange) {
            attributed.enumerateAttribute(.font, in: range) { value, subrange, _ in
                let currentFont = (value as? NSFont) ?? baseFont
                let converted = NSFontManager.shared.convert(currentFont, toHaveTrait: trait)
                attributed.addAttribute(.font, value: converted, range: subrange)
            }
        }

        for span in formatting {
            let range = NSRange(location: span.location, length: span.length)
            guard range.location >= 0,
                  range.length > 0,
                  range.location + range.length <= fullRange.length else { continue }

            switch span.kind {
            case .bold:
                applyFontTrait(.boldFontMask, to: range)
            case .italic:
                applyFontTrait(.italicFontMask, to: range)
            case .highlight:
                attributed.addAttribute(.backgroundColor, value: NSColor.systemYellow.withAlphaComponent(0.3), range: range)
            }
            attributed.addAttribute(formattingAttribute, value: span.kind.rawValue, range: range)
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
                StrataTextField.currentEditingField = tf
                editor.textContainerInset = .zero
                editor.textContainer?.lineFragmentPadding = 0
                editor.textContainer?.widthTracksTextView = true
                editor.isHorizontallyResizable = false
                editor.isVerticallyResizable = true
                editor.isRichText = true

                // Install right-click context menu monitor for formatting
                tf.installContextMenuMonitor()
                tf.installSelectionRestyleObserver { [weak tf, weak self] in
                    guard let tf, let self else { return }
                    Self.restyleEditor(tf, parent: self.parent)
                }

                // NSTextField's shared field editor starts from stringValue, not the
                // display attributedStringValue. Style it immediately so focusing a row
                // does not make markdown markers flash or stay raw until the next edit.
                Self.restyleEditor(tf, parent: parent)
                if Self.convertMarkdownSyntax(in: editor) {
                    parent.text = editor.string
                    parent.formatting = Self.extractFormatting(from: editor.textStorage)
                    parent.onTextChange()
                }
            }
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let tf = obj.object as? StrataTextField,
                  let editor = tf.currentEditor() as? NSTextView else { return }
            _ = Self.convertMarkdownSyntax(in: editor)
            let newValue = tf.stringValue
            let newFormatting = Self.extractFormatting(from: editor.textStorage)
            guard newValue != parent.text || newFormatting != parent.formatting else { return }
            parent.text = newValue
            parent.formatting = newFormatting
            parent.onTextChange()
            tf.invalidateIntrinsicContentSize()

            // Immediately restyle to prevent formatting jumps between keystrokes
            Self.restyleEditor(tf, parent: parent)
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            if let tf = obj.object as? StrataTextField {
                tf.removeContextMenuMonitor()
                tf.removeSelectionRestyleObserver()
                tf.lastStyledText = nil
                tf.lastStyledFormatting = nil
                if StrataTextField.currentEditingField === tf {
                    StrataTextField.currentEditingField = nil
                }
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
            let searchQ = parent.searchQuery

            editor.undoManager?.disableUndoRegistration()
            storage.beginEditing()
            storage.addAttributes([
                .font: font,
                .foregroundColor: baseColor,
                .paragraphStyle: OutlineTextField.paragraphStyle
            ], range: fullRange)
            storage.removeAttribute(.backgroundColor, range: fullRange)
            storage.removeAttribute(OutlineTextField.formattingAttribute, range: fullRange)
            if !isDone {
                OutlineTextField.applyFormatting(parent.formatting, to: storage, baseFont: font)
            }
            if !searchQ.isEmpty {
                OutlineTextField.applySearchHighlight(to: storage, query: searchQ)
            }
            storage.endEditing()
            editor.undoManager?.enableUndoRegistration()

            if savedRange.location + savedRange.length <= storage.length {
                editor.setSelectedRange(savedRange)
            }

            editor.typingAttributes = [
                .font: font,
                .foregroundColor: baseColor,
                .paragraphStyle: OutlineTextField.paragraphStyle
            ]

            tf.lastStyledText = storage.string
            tf.lastStyledFormatting = parent.formatting
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
                guard Self.shouldPromoteTextSelectionToNodeSelection(textView, direction: .up) else {
                    return false
                }
                parent.onShiftUp()
                control.window?.makeFirstResponder(nil)
                return true
            case #selector(NSResponder.moveDownAndModifySelection(_:)):
                guard Self.shouldPromoteTextSelectionToNodeSelection(textView, direction: .down) else {
                    return false
                }
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

        private enum SelectionDirection {
            case up
            case down
        }

        private static func shouldPromoteTextSelectionToNodeSelection(
            _ textView: NSTextView,
            direction: SelectionDirection
        ) -> Bool {
            let range = textView.selectedRange
            let textLength = (textView.string as NSString).length

            switch direction {
            case .up:
                return range.location == 0
            case .down:
                return range.location + range.length >= textLength
            }
        }

        @discardableResult
        private static func convertMarkdownSyntax(in editor: NSTextView) -> Bool {
            guard let storage = editor.textStorage else { return false }
            var changed = false
            changed = convertMarkdownPattern(
                "\\*\\*(?=\\S)(.+?)(?<=\\S)\\*\\*",
                markerLength: 2,
                kind: .bold,
                in: editor,
                storage: storage
            ) || changed
            changed = convertMarkdownPattern(
                "==(?=\\S)(.+?)(?<=\\S)==",
                markerLength: 2,
                kind: .highlight,
                in: editor,
                storage: storage
            ) || changed
            changed = convertMarkdownPattern(
                "(?<!\\*)\\*(?![\\s*])(.+?)(?<![\\s*])\\*(?!\\*)",
                markerLength: 1,
                kind: .italic,
                in: editor,
                storage: storage
            ) || changed
            return changed
        }

        private static func convertMarkdownPattern(
            _ pattern: String,
            markerLength: Int,
            kind: TextFormattingKind,
            in editor: NSTextView,
            storage: NSMutableAttributedString
        ) -> Bool {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
            let text = storage.string
            let nsText = text as NSString
            let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
            guard !matches.isEmpty else { return false }

            var selection = editor.selectedRange
            for match in matches.reversed() {
                let contentRange = match.range(at: 1)
                let content = nsText.substring(with: contentRange)
                let newRange = NSRange(location: match.range.location, length: (content as NSString).length)
                storage.replaceCharacters(in: match.range, with: content)
                OutlineTextField.applyFormatting(
                    [TextFormattingSpan(kind: kind, location: newRange.location, length: newRange.length)],
                    to: storage,
                    baseFont: OutlineTextField.font
                )

                let removedLength = match.range.length - newRange.length
                let matchEnd = match.range.location + match.range.length
                if selection.location >= matchEnd {
                    selection.location -= removedLength
                } else if selection.location > match.range.location {
                    selection.location = min(newRange.location + newRange.length, max(newRange.location, selection.location - markerLength))
                }
            }

            editor.setSelectedRange(NSRange(location: min(selection.location, storage.length), length: 0))
            return true
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
                      rawValue == TextFormattingKind.highlight.rawValue else { return }
                spans.append(TextFormattingSpan(kind: .highlight, location: range.location, length: range.length))
            }

            return spans.sorted {
                if $0.location == $1.location {
                    return $0.kind.rawValue < $1.kind.rawValue
                }
                return $0.location < $1.location
            }
        }
    }
}

// MARK: - StrataTextField

class StrataTextField: NSTextField {
    static weak var currentEditingField: StrataTextField?

    private var lastKnownWidth: CGFloat = 0

    // Style tracking to avoid redundant restyling in updateNSView
    var lastStyledText: String?
    var lastStyledFormatting: [TextFormattingSpan]?
    var lastStyledDone: Bool?
    var lastStyledSearch: String?

    // Context menu event monitor
    private var rightClickMonitor: Any?
    private var selectionRestyleObserver: NSObjectProtocol?
    private var pendingSelectionRestyle = false
    private var isRestylingSelection = false

    override var intrinsicContentSize: NSSize {
        if preferredMaxLayoutWidth > 0 {
            return NSSize(
                width: NSView.noIntrinsicMetric,
                height: measuredTextHeight(for: preferredMaxLayoutWidth)
            )
        }
        return super.intrinsicContentSize
    }

    func measuredTextHeight(for width: CGFloat) -> CGFloat {
        let measurementWidth = max(width, 1)
        let attributed: NSAttributedString

        if let editor = currentEditor() as? NSTextView, let storage = editor.textStorage {
            attributed = storage
        } else if attributedStringValue.length > 0 {
            attributed = attributedStringValue
        } else {
            attributed = NSAttributedString(
                string: stringValue.isEmpty ? " " : stringValue,
                attributes: [
                    .font: font ?? OutlineTextField.font,
                    .paragraphStyle: OutlineTextField.paragraphStyle
                ]
            )
        }

        let rect = attributed.boundingRect(
            with: NSSize(width: measurementWidth, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )

        return max(ceil(rect.height), 22)
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
        removeSelectionRestyleObserver()
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

    func installSelectionRestyleObserver(_ restyle: @escaping () -> Void) {
        removeSelectionRestyleObserver()
        guard let editor = currentEditor() as? NSTextView else { return }

        selectionRestyleObserver = NotificationCenter.default.addObserver(
            forName: NSTextView.didChangeSelectionNotification,
            object: editor,
            queue: .main
        ) { [weak self] _ in
            self?.scheduleSelectionRestyle(restyle)
        }
    }

    func removeSelectionRestyleObserver() {
        if let observer = selectionRestyleObserver {
            NotificationCenter.default.removeObserver(observer)
            selectionRestyleObserver = nil
        }
        pendingSelectionRestyle = false
        isRestylingSelection = false
    }

    private func scheduleSelectionRestyle(_ restyle: @escaping () -> Void) {
        guard !isRestylingSelection, !pendingSelectionRestyle else { return }
        pendingSelectionRestyle = true

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pendingSelectionRestyle = false
            self.isRestylingSelection = true
            restyle()
            self.isRestylingSelection = false
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

    @objc func wrapBold() { toggleFormatting(.bold) }
    @objc func wrapItalic() { toggleFormatting(.italic) }
    @objc func wrapHighlight() { toggleFormatting(.highlight) }

    private func toggleFormatting(_ kind: TextFormattingKind) {
        guard let editor = currentEditor() as? NSTextView,
              let storage = editor.textStorage else { return }
        let range = editor.selectedRange

        if range.length == 0 {
            toggleTypingAttribute(kind, in: editor)
            return
        }

        storage.beginEditing()
        switch kind {
        case .bold:
            toggleFontTrait(.boldFontMask, in: range, storage: storage)
        case .italic:
            toggleFontTrait(.italicFontMask, in: range, storage: storage)
        case .highlight:
            if storage.attribute(.backgroundColor, at: range.location, effectiveRange: nil) == nil {
                storage.addAttribute(.backgroundColor, value: NSColor.systemYellow.withAlphaComponent(0.3), range: range)
                storage.addAttribute(OutlineTextField.formattingAttribute, value: kind.rawValue, range: range)
            } else {
                storage.removeAttribute(.backgroundColor, range: range)
                storage.removeAttribute(OutlineTextField.formattingAttribute, range: range)
            }
        }
        storage.endEditing()
        editor.didChangeText()
        editor.setSelectedRange(range)
    }

    private func toggleTypingAttribute(_ kind: TextFormattingKind, in editor: NSTextView) {
        var attributes = editor.typingAttributes
        let baseFont = (attributes[.font] as? NSFont) ?? OutlineTextField.font

        switch kind {
        case .bold:
            attributes[.font] = toggledFontTrait(.boldFontMask, font: baseFont)
        case .italic:
            attributes[.font] = toggledFontTrait(.italicFontMask, font: baseFont)
        case .highlight:
            if attributes[.backgroundColor] == nil {
                attributes[.backgroundColor] = NSColor.systemYellow.withAlphaComponent(0.3)
            } else {
                attributes.removeValue(forKey: .backgroundColor)
            }
        }

        editor.typingAttributes = attributes
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

    // MARK: - Key Handling

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Only handle shortcuts when THIS text field is being edited
        guard currentEditor() != nil else {
            return super.performKeyEquivalent(with: event)
        }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        // Cmd+Z / Cmd+Shift+Z — keep text undo inside the field editor
        if event.keyCode == 6 && flags == .command {
            currentEditor()?.undoManager?.undo()
            return true
        }
        if event.keyCode == 6 && flags == [.command, .shift] {
            currentEditor()?.undoManager?.redo()
            return true
        }

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
            guard shouldPromoteTextSelectionToNodeSelection(.up) else {
                return false
            }
            onShiftUp?()
            self.window?.makeFirstResponder(nil)
            return true
        }
        // Shift+Down — start block selection downward
        if event.keyCode == 125 && flags == .shift {
            guard shouldPromoteTextSelectionToNodeSelection(.down) else {
                return false
            }
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
        // Cmd+Shift+H — Highlight
        if event.keyCode == 4 && flags == [.command, .shift] {
            wrapHighlight()
            return true
        }
        // Cmd+Up — move node up (Workflowy-style)
        if event.keyCode == 126 && flags == .command {
            onCmdShiftUp?()
            return true
        }
        // Cmd+Down — move node down (Workflowy-style)
        if event.keyCode == 125 && flags == .command {
            onCmdShiftDown?()
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
        // Cmd+V — outline-node or multi-line paste creates nodes; single-line text is normal paste
        if event.keyCode == 9 && flags == .command {
            if NSPasteboard.general.data(forType: OutlineStore.nodePasteboardType) != nil {
                onPasteNodes?()
                return true
            }
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

    private enum SelectionDirection {
        case up
        case down
    }

    private func shouldPromoteTextSelectionToNodeSelection(_ direction: SelectionDirection) -> Bool {
        guard let editor = currentEditor() else { return false }
        let range = editor.selectedRange
        let textLength = (editor.string as NSString).length

        switch direction {
        case .up:
            return range.location == 0
        case .down:
            return range.location + range.length >= textLength
        }
    }
}
