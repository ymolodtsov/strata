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
    var onTab: () -> Bool
    var onBackTab: () -> Bool
    var onMoveUp: () -> Void
    var onMoveDown: () -> Void
    var onDelete: () -> Void
    var onMergeWithPrevious: () -> Void
    var onToggleDone: () -> Void
    var onMoveNodeUp: () -> Bool
    var onMoveNodeDown: () -> Bool
    var onZoomIn: () -> Void
    var onEscape: () -> Void
    var onDidFocus: () -> Void
    var onTextChange: () -> Void
    var onSelectAllNodes: () -> Void
    var onBeginEditing: () -> Void
    var onShiftUp: () -> Void
    var onShiftDown: () -> Void
    var onPasteNodes: () -> Bool
    var onUndo: () -> Void
    var onRedo: () -> Void
    var onStructuralEditForUndo: () -> Void
    var shouldRouteStructuralUndoToStore: () -> Bool
    var shouldRouteStructuralRedoToStore: () -> Bool
    var searchQuery: String

    static let font = NSFont.systemFont(ofSize: 15, weight: .regular)
    static let paragraphStyle: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byWordWrapping
        return style
    }()

    static let formattingAttribute = NSAttributedString.Key("family.ma.strata.formattingKind")
    static let manualLinkURLAttribute = NSAttributedString.Key("family.ma.strata.linkURL")
    private static let linkDetector = try? NSDataDetector(
        types: NSTextCheckingResult.CheckingType.link.rawValue
    )

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
        tf.allowsEditingTextAttributes = true
        tf.usesSingleLineMode = false
        tf.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        tf.delegate = context.coordinator
        tf.placeholderAttributedString = NSAttributedString(
            string: "...",
            attributes: [
                .font: Self.font,
                .foregroundColor: NSColor.secondaryLabelColor.withAlphaComponent(0.45)
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
        tf.onUndo = { context.coordinator.parent.onUndo() }
        tf.onRedo = { context.coordinator.parent.onRedo() }
        tf.onStructuralEditForUndo = { context.coordinator.parent.onStructuralEditForUndo() }
        tf.shouldRouteStructuralUndoToStore = { context.coordinator.parent.shouldRouteStructuralUndoToStore() }
        tf.shouldRouteStructuralRedoToStore = { context.coordinator.parent.shouldRouteStructuralRedoToStore() }

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
        nsView.onUndo = { onUndo() }
        nsView.onRedo = { onRedo() }
        nsView.onStructuralEditForUndo = { onStructuralEditForUndo() }
        nsView.shouldRouteStructuralUndoToStore = { shouldRouteStructuralUndoToStore() }
        nsView.shouldRouteStructuralRedoToStore = { shouldRouteStructuralRedoToStore() }

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
            let targetText = currentText

            editor.undoManager?.disableUndoRegistration()
            tf.beginProgrammaticStyle()
            storage.beginEditing()
            Self.setStyledText(
                targetText,
                in: storage,
                formatting: currentFormatting,
                isDone: isDone,
                baseFont: font,
                baseColor: baseColor,
                searchQuery: searchQ
            )
            storage.endEditing()
            tf.endProgrammaticStyle()
            editor.undoManager?.enableUndoRegistration()

            let safeLocation = min(savedRange.location, storage.length)
            let safeLength = min(savedRange.length, storage.length - safeLocation)
            editor.setSelectedRange(NSRange(location: safeLocation, length: safeLength))

            editor.typingAttributes = Self.typingAttributes(
                in: storage,
                near: editor.selectedRange,
                fallbackFont: font,
                fallbackColor: baseColor
            )

            tf.lastStyledText = storage.string
            tf.lastStyledFormatting = currentFormatting
            tf.lastStyledDone = isDone
            tf.lastStyledSearch = searchQ
            tf.invalidateMeasurementCache()
            tf.invalidateIntrinsicContentSize()
        } else {
            // Not editing — build styled attributed string directly
            let shouldInvalidateSize =
                tf.lastStyledText != currentText ||
                tf.lastStyledFormatting != currentFormatting ||
                tf.lastStyledDone != isDone ||
                tf.lastStyledSearch != searchQ

            let styled: NSAttributedString
            if isDone {
                styled = Self.styledAttributedString(
                    from: currentText,
                    baseFont: font,
                    baseColor: baseColor,
                    formatting: [],
                    isDone: true
                )
            } else {
                styled = Self.styledAttributedString(
                    from: currentText, baseFont: font,
                    baseColor: baseColor,
                    formatting: currentFormatting,
                    isDone: false
                )
            }

            if !searchQ.isEmpty {
                let mutable = NSMutableAttributedString(attributedString: styled)
                Self.applySearchHighlight(to: mutable, query: searchQ)
                tf.attributedStringValue = mutable
            } else {
                tf.attributedStringValue = styled
            }

            tf.lastStyledText = currentText
            tf.lastStyledFormatting = currentFormatting
            tf.lastStyledDone = isDone
            tf.lastStyledSearch = searchQ
            if shouldInvalidateSize {
                tf.invalidateMeasurementCache()
                tf.invalidateIntrinsicContentSize()
            }
        }
    }

    // MARK: - Rich Text Styling

    private static func styledAttributedString(
        from text: String,
        baseFont: NSFont,
        baseColor: NSColor,
        formatting: [TextFormattingSpan],
        isDone: Bool = false
    ) -> NSAttributedString {
        let attributed = NSMutableAttributedString(
            string: text,
            attributes: [.font: baseFont, .foregroundColor: baseColor, .paragraphStyle: paragraphStyle]
        )
        if !isDone {
            applyFormatting(formatting, to: attributed, baseFont: baseFont)
        }
        applyDetectedLinks(to: attributed)
        return attributed
    }

    static func setStyledText(
        _ text: String,
        in storage: NSTextStorage,
        formatting: [TextFormattingSpan],
        isDone: Bool,
        baseFont: NSFont,
        baseColor: NSColor,
        searchQuery: String
    ) {
        let attributed = NSMutableAttributedString(attributedString: styledAttributedString(
            from: text,
            baseFont: baseFont,
            baseColor: baseColor,
            formatting: formatting,
            isDone: isDone
        ))
        if !searchQuery.isEmpty {
            applySearchHighlight(to: attributed, query: searchQuery)
        }
        storage.setAttributedString(attributed)
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

        for span in formatting.normalized(forTextLength: fullRange.length) {
            let range = NSRange(location: span.location, length: span.length)

            switch span.kind {
            case .bold:
                applyFontTrait(.boldFontMask, to: range)
            case .italic:
                applyFontTrait(.italicFontMask, to: range)
            case .highlight:
                attributed.addAttribute(.backgroundColor, value: NSColor.systemYellow.withAlphaComponent(0.3), range: range)
            case .link:
                guard let urlString = span.url?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !urlString.isEmpty,
                      let url = URL(string: urlString) else { break }
                attributed.addAttributes([
                    .link: url,
                    .foregroundColor: NSColor.linkColor,
                    .underlineStyle: NSUnderlineStyle.single.rawValue,
                    manualLinkURLAttribute: url.absoluteString
                ], range: range)
            }
            attributed.addAttribute(formattingAttribute, value: span.kind.rawValue, range: range)
        }
    }

    static func applyDetectedLinks(to attributed: NSMutableAttributedString) {
        let text = attributed.string
        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        guard fullRange.length > 0 else { return }

        linkDetector?.enumerateMatches(in: text, range: fullRange) { match, _, _ in
            guard let match,
                  let url = match.url,
                  match.range.location != NSNotFound,
                  match.range.length > 0,
                  match.range.location + match.range.length <= fullRange.length else { return }
            let existingKind = attributed.attribute(formattingAttribute, at: match.range.location, effectiveRange: nil) as? String
            if existingKind == TextFormattingKind.link.rawValue { return }

            attributed.addAttributes([
                .link: url,
                .foregroundColor: NSColor.linkColor,
                .underlineStyle: NSUnderlineStyle.single.rawValue
            ], range: match.range)
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

    static func typingAttributes(
        in storage: NSTextStorage,
        near selection: NSRange,
        fallbackFont: NSFont,
        fallbackColor: NSColor
    ) -> [NSAttributedString.Key: Any] {
        let length = storage.length
        guard length > 0 else {
            return [
                .font: fallbackFont,
                .foregroundColor: fallbackColor,
                .paragraphStyle: paragraphStyle
            ]
        }

        let index: Int
        if selection.location < length {
            index = selection.location
        } else {
            index = max(0, length - 1)
        }

        var attributes = storage.attributes(at: index, effectiveRange: nil)
        attributes[.font] = attributes[.font] ?? fallbackFont
        attributes[.foregroundColor] = attributes[.foregroundColor] ?? fallbackColor
        attributes[.paragraphStyle] = paragraphStyle
        attributes.removeValue(forKey: .link)
        attributes.removeValue(forKey: .underlineStyle)
        attributes.removeValue(forKey: manualLinkURLAttribute)
        if attributes[formattingAttribute] as? String == TextFormattingKind.link.rawValue {
            attributes.removeValue(forKey: formattingAttribute)
        }
        return attributes
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
                tf.beginProgrammaticStyle()
                defer { tf.endProgrammaticStyle() }

                StrataTextField.currentEditingField = tf
                editor.textContainerInset = .zero
                editor.textContainer?.lineFragmentPadding = 0
                editor.textContainer?.widthTracksTextView = true
                editor.isHorizontallyResizable = false
                editor.isVerticallyResizable = true
                editor.isRichText = true
                editor.usesFontPanel = false
                editor.linkTextAttributes = [
                    .foregroundColor: NSColor.linkColor,
                    .underlineStyle: NSUnderlineStyle.single.rawValue
                ]
                editor.menu = tf.buildContextMenu()

                // Install right-click context menu monitor for formatting
                tf.installContextMenuMonitor()
                tf.installLinkClickMonitor()
                tf.installSelectionObserver { [weak tf, weak self] in
                    guard let tf, let self else { return }
                    Self.updateTypingAttributes(tf, parent: self.parent)
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
            guard !tf.isApplyingProgrammaticStyle else { return }
            let convertedMarkdown = Self.convertMarkdownSyntax(in: editor)
            let newValue = tf.stringValue
            let newFormatting = Self.extractFormatting(from: editor.textStorage)
            guard newValue != parent.text || newFormatting != parent.formatting else { return }
            let formattingChanged = newFormatting != parent.formatting
            parent.text = newValue
            parent.formatting = newFormatting
            parent.onTextChange()
            tf.invalidateMeasurementCache()
            tf.invalidateIntrinsicContentSize()

            // Plain typing already updates the field editor's attributed storage.
            // Full restyling is only needed when markdown markers were converted,
            // formatting spans changed, or search highlighting must be reapplied.
            if convertedMarkdown || formattingChanged || !parent.searchQuery.isEmpty {
                Self.restyleEditor(tf, parent: parent)
            } else {
                tf.lastStyledText = newValue
                tf.lastStyledFormatting = newFormatting
                tf.lastStyledDone = parent.isDone
                tf.lastStyledSearch = parent.searchQuery
                Self.updateTypingAttributes(tf, parent: parent)
            }
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            if let tf = obj.object as? StrataTextField {
                tf.removeContextMenuMonitor()
                tf.removeLinkClickMonitor()
                tf.removeSelectionObserver()
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
            let font = OutlineTextField.font
            let isDone = parent.isDone
            let baseColor: NSColor = isDone ? .tertiaryLabelColor : .labelColor
            let searchQ = parent.searchQuery
            let currentText = storage.string

            editor.undoManager?.disableUndoRegistration()
            tf.beginProgrammaticStyle()
            storage.beginEditing()
            OutlineTextField.setStyledText(
                currentText,
                in: storage,
                formatting: parent.formatting,
                isDone: isDone,
                baseFont: font,
                baseColor: baseColor,
                searchQuery: searchQ
            )
            storage.endEditing()
            tf.endProgrammaticStyle()
            editor.undoManager?.enableUndoRegistration()

            let safeLocation = min(savedRange.location, storage.length)
            let safeLength = min(savedRange.length, storage.length - safeLocation)
            editor.setSelectedRange(NSRange(location: safeLocation, length: safeLength))

            editor.typingAttributes = OutlineTextField.typingAttributes(
                in: storage,
                near: editor.selectedRange,
                fallbackFont: font,
                fallbackColor: baseColor
            )

            tf.lastStyledText = storage.string
            tf.lastStyledFormatting = parent.formatting
            tf.lastStyledDone = isDone
            tf.lastStyledSearch = searchQ
            tf.invalidateMeasurementCache()
            tf.invalidateIntrinsicContentSize()
        }

        static func updateTypingAttributes(_ tf: StrataTextField, parent: OutlineTextField) {
            guard let editor = tf.currentEditor() as? NSTextView,
                  let storage = editor.textStorage else { return }

            let baseColor: NSColor = parent.isDone ? .tertiaryLabelColor : .labelColor
            editor.typingAttributes = OutlineTextField.typingAttributes(
                in: storage,
                near: editor.selectedRange,
                fallbackFont: OutlineTextField.font,
                fallbackColor: baseColor
            )
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.insertNewline(_:)):
                let offset = textView.selectedRange.location
                parent.onCommit(offset)
                return true
            case #selector(NSResponder.insertTab(_:)):
                if parent.onTab(), let tf = control as? StrataTextField {
                    tf.markStructuralEditForUndo()
                }
                return true
            case #selector(NSResponder.insertBacktab(_:)):
                if parent.onBackTab(), let tf = control as? StrataTextField {
                    tf.markStructuralEditForUndo()
                }
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
                      let kind = TextFormattingKind(rawValue: rawValue) else { return }
                switch kind {
                case .highlight:
                    spans.append(TextFormattingSpan(kind: .highlight, location: range.location, length: range.length))
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
}

// MARK: - StrataTextField

class StrataTextField: NSTextField {
    static weak var currentEditingField: StrataTextField?

    private var lastKnownWidth: CGFloat = 0
    private var programmaticStyleDepth = 0
    private(set) var pendingStructuralUndoCount = 0
    private(set) var pendingStructuralRedoCount = 0
    var isApplyingProgrammaticStyle: Bool { programmaticStyleDepth > 0 }
    private var cachedMeasureWidth: CGFloat = 0
    private var cachedMeasureSignature = ""
    private var cachedMeasureHeight: CGFloat = 0

    // Style tracking to avoid redundant restyling in updateNSView
    var lastStyledText: String?
    var lastStyledFormatting: [TextFormattingSpan]?
    var lastStyledDone: Bool?
    var lastStyledSearch: String?

    // Context menu event monitor
    private var rightClickMonitor: Any?
    private var linkClickMonitor: Any?
    private var selectionObserver: NSObjectProtocol?
    private var pendingSelectionUpdate = false

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
        let attributed: NSMutableAttributedString

        if let editor = currentEditor() as? NSTextView, let storage = editor.textStorage {
            attributed = NSMutableAttributedString(attributedString: storage)
        } else if attributedStringValue.length > 0 {
            attributed = NSMutableAttributedString(attributedString: attributedStringValue)
        } else {
            attributed = NSMutableAttributedString(
                string: stringValue.isEmpty ? " " : stringValue,
                attributes: [
                    .font: font ?? OutlineTextField.font,
                    .paragraphStyle: OutlineTextField.paragraphStyle
                ]
            )
        }

        let signature = measurementSignature(for: attributed)
        if abs(cachedMeasureWidth - measurementWidth) < 0.5,
           cachedMeasureSignature == signature {
            return cachedMeasureHeight
        }

        if attributed.length > 0 {
            attributed.addAttribute(
                .paragraphStyle,
                value: OutlineTextField.paragraphStyle,
                range: NSRange(location: 0, length: attributed.length)
            )
        } else {
            attributed.append(NSAttributedString(
                string: " ",
                attributes: [
                    .font: font ?? OutlineTextField.font,
                    .paragraphStyle: OutlineTextField.paragraphStyle
                ]
            ))
        }

        let storage = NSTextStorage(attributedString: attributed)
        let layoutManager = NSLayoutManager()
        let textContainer = NSTextContainer(
            containerSize: NSSize(width: measurementWidth, height: CGFloat.greatestFiniteMagnitude)
        )
        textContainer.lineFragmentPadding = 0
        textContainer.widthTracksTextView = false
        textContainer.heightTracksTextView = false

        layoutManager.addTextContainer(textContainer)
        storage.addLayoutManager(layoutManager)
        layoutManager.ensureLayout(for: textContainer)

        let rect = layoutManager.usedRect(for: textContainer)
        let height = max(ceil(rect.height) + 8, 24)
        cachedMeasureWidth = measurementWidth
        cachedMeasureSignature = signature
        cachedMeasureHeight = height
        return height
    }

    func invalidateMeasurementCache() {
        cachedMeasureSignature = ""
        cachedMeasureHeight = 0
    }

    private func measurementSignature(for attributed: NSAttributedString) -> String {
        var signature = "\(attributed.string)|\(attributed.length)"
        let fullRange = NSRange(location: 0, length: attributed.length)
        guard fullRange.length > 0 else { return signature }

        attributed.enumerateAttributes(in: fullRange) { attributes, range, _ in
            if let font = attributes[.font] as? NSFont {
                signature += "|f:\(range.location):\(range.length):\(font.fontName):\(font.pointSize)"
            }
            if attributes[.backgroundColor] != nil {
                signature += "|b:\(range.location):\(range.length)"
            }
            if let link = attributes[.link] {
                signature += "|l:\(range.location):\(range.length):\(link)"
            }
        }
        return signature
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
        removeLinkClickMonitor()
        removeSelectionObserver()
    }

    var onCmdEnter: (() -> Void)?
    var onCmdShiftUp: (() -> Bool)?
    var onCmdShiftDown: (() -> Bool)?
    var onSelectAllNodes: (() -> Void)?
    var onZoomIn: (() -> Void)?
    var onTab: (() -> Bool)?
    var onBackTab: (() -> Bool)?
    var onShiftUp: (() -> Void)?
    var onShiftDown: (() -> Void)?
    var onPasteNodes: (() -> Bool)?
    var onUndo: (() -> Void)?
    var onRedo: (() -> Void)?
    var onStructuralEditForUndo: (() -> Void)?
    var shouldRouteStructuralUndoToStore: (() -> Bool)?
    var shouldRouteStructuralRedoToStore: (() -> Bool)?

    func beginProgrammaticStyle() {
        programmaticStyleDepth += 1
    }

    func endProgrammaticStyle() {
        programmaticStyleDepth = max(0, programmaticStyleDepth - 1)
    }

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

    func installLinkClickMonitor() {
        removeLinkClickMonitor()
        linkClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
            guard event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command),
                  let self,
                  let editor = self.currentEditor() as? NSTextView,
                  let eventWindow = event.window,
                  eventWindow == self.window else {
                return event
            }

            let locationInEditor = editor.convert(event.locationInWindow, from: nil)
            guard editor.bounds.contains(locationInEditor),
                  let url = self.linkURL(at: locationInEditor, in: editor) else {
                return event
            }

            NSWorkspace.shared.open(url)
            return nil
        }
    }

    func removeLinkClickMonitor() {
        if let monitor = linkClickMonitor {
            NSEvent.removeMonitor(monitor)
            linkClickMonitor = nil
        }
    }

    private func linkURL(at locationInEditor: NSPoint, in editor: NSTextView) -> URL? {
        guard let layoutManager = editor.layoutManager,
              let textContainer = editor.textContainer else { return nil }

        let textContainerOrigin = editor.textContainerOrigin
        let point = NSPoint(
            x: locationInEditor.x - textContainerOrigin.x,
            y: locationInEditor.y - textContainerOrigin.y
        )
        guard point.x >= 0, point.y >= 0 else { return nil }

        let characterIndex = layoutManager.characterIndex(
            for: point,
            in: textContainer,
            fractionOfDistanceBetweenInsertionPoints: nil
        )
        guard characterIndex < editor.textStorage?.length ?? 0,
              let value = editor.textStorage?.attribute(.link, at: characterIndex, effectiveRange: nil) else {
            return nil
        }

        if let url = value as? URL {
            return url
        }
        if let string = value as? String {
            return URL(string: string)
        }
        return nil
    }

    func installSelectionObserver(_ update: @escaping () -> Void) {
        removeSelectionObserver()
        guard let editor = currentEditor() as? NSTextView else { return }

        selectionObserver = NotificationCenter.default.addObserver(
            forName: NSTextView.didChangeSelectionNotification,
            object: editor,
            queue: .main
        ) { [weak self] _ in
            self?.scheduleSelectionUpdate(update)
        }
    }

    func removeSelectionObserver() {
        if let observer = selectionObserver {
            NotificationCenter.default.removeObserver(observer)
            selectionObserver = nil
        }
        pendingSelectionUpdate = false
    }

    private func scheduleSelectionUpdate(_ update: @escaping () -> Void) {
        guard !pendingSelectionUpdate else { return }
        pendingSelectionUpdate = true

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pendingSelectionUpdate = false
            update()
        }
    }

    func buildContextMenu() -> NSMenu {
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

        let linkItem = NSMenuItem(title: "Link...", action: #selector(editLink), keyEquivalent: "k")
        linkItem.keyEquivalentModifierMask = .command
        linkItem.target = self
        menu.addItem(linkItem)

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
    @objc func editLink() {
        guard let editor = currentEditor() as? NSTextView,
              let storage = editor.textStorage else { return }

        var range = editor.selectedRange

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

        editor.setSelectedRange(range)
        editor.orderFrontLinkPanel(nil)
    }

    func markStructuralEditForUndo() {
        if let onStructuralEditForUndo {
            onStructuralEditForUndo()
            return
        }
        pendingStructuralUndoCount += 1
        pendingStructuralRedoCount = 0
    }

    var shouldRouteUndoToStore: Bool {
        if let shouldRouteStructuralUndoToStore {
            return shouldRouteStructuralUndoToStore()
        }
        return pendingStructuralUndoCount > 0
    }

    var shouldRouteRedoToStore: Bool {
        if let shouldRouteStructuralRedoToStore {
            return shouldRouteStructuralRedoToStore()
        }
        return pendingStructuralRedoCount > 0
    }

    func consumeStructuralUndoRoute() {
        if shouldRouteStructuralUndoToStore != nil {
            return
        }
        pendingStructuralUndoCount = max(0, pendingStructuralUndoCount - 1)
        pendingStructuralRedoCount += 1
    }

    func consumeStructuralRedoRoute() {
        if shouldRouteStructuralRedoToStore != nil {
            return
        }
        pendingStructuralRedoCount = max(0, pendingStructuralRedoCount - 1)
        pendingStructuralUndoCount += 1
    }

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
        case .link:
            storage.endEditing()
            editLink()
            return
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

        // Cmd+W — close the current tab/window while editing text.
        if event.keyCode == 13 && flags == .command {
            window?.performClose(nil)
            return true
        }

        if event.keyCode == 6 && flags == .command {
            if shouldRouteUndoToStore {
                consumeStructuralUndoRoute()
                onUndo?()
                return true
            }
            currentEditor()?.undoManager?.undo()
            return true
        }
        if event.keyCode == 6 && flags == [.command, .shift] {
            if shouldRouteRedoToStore {
                consumeStructuralRedoRoute()
                onRedo?()
                return true
            }
            currentEditor()?.undoManager?.redo()
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
            markStructuralEditForUndo()
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
        // Cmd+L — Highlight
        if event.keyCode == 37 && flags == .command {
            wrapHighlight()
            return true
        }
        // Cmd+K — add or edit link
        if event.keyCode == 40 && flags == .command {
            editLink()
            return true
        }
        // Cmd+Up — move node up (Workflowy-style)
        if event.keyCode == 126 && flags == .command {
            if onCmdShiftUp?() == true {
                markStructuralEditForUndo()
            }
            return true
        }
        // Cmd+Down — move node down (Workflowy-style)
        if event.keyCode == 125 && flags == .command {
            if onCmdShiftDown?() == true {
                markStructuralEditForUndo()
            }
            return true
        }
        // Cmd+Shift+Up — move node up
        if event.keyCode == 126 && flags == [.command, .shift] {
            if onCmdShiftUp?() == true {
                markStructuralEditForUndo()
            }
            return true
        }
        // Cmd+Shift+Down — move node down
        if event.keyCode == 125 && flags == [.command, .shift] {
            if onCmdShiftDown?() == true {
                markStructuralEditForUndo()
            }
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
                if onPasteNodes?() == true {
                    markStructuralEditForUndo()
                }
                return true
            }
            if let text = NSPasteboard.general.string(forType: .string),
               text.contains("\n") || text.contains("\r") {
                if onPasteNodes?() == true {
                    markStructuralEditForUndo()
                }
                return true
            }
            return false
        }
        // Cmd+A — second press selects all nodes
        if event.keyCode == 0 && flags == .command {
            if let editor = currentEditor() {
                let fullRange = NSRange(location: 0, length: (editor.string as NSString).length)
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
