import SwiftUI

// MARK: - Session State (persists open document tabs across launches)

enum WindowTabCoordinator {
    private static weak var requestedParentWindow: NSWindow?
    private static var pendingTabCount = 0

    static func requestNextWindowAsTab() {
        if requestedParentWindow == nil {
            requestedParentWindow = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible })
        }
        pendingTabCount += 1
    }

    static func openNextWindowAsTab(using openWindow: OpenWindowAction) {
        requestNextWindowAsTab()
        openWindow(id: "main")
    }

    static func configure(_ window: NSWindow?) {
        guard let window else { return }
        configurePresentation(window)

        guard let parent = requestedParentWindow,
              parent != window,
              pendingTabCount > 0,
              parent.isVisible else { return }

        let alreadyTabbedWithParent =
            parent.tabGroup?.windows.contains(window) == true ||
            window.tabGroup?.windows.contains(parent) == true
        guard !alreadyTabbedWithParent else {
            completePendingTabRequest()
            return
        }

        parent.tabbingMode = .preferred
        window.tabbingMode = .preferred
        parent.addTabbedWindow(window, ordered: .above)
        completePendingTabRequest()
        window.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async {
            configureVisibleWindows()
        }
    }

    private static func completePendingTabRequest() {
        pendingTabCount = max(0, pendingTabCount - 1)
        if pendingTabCount == 0 {
            requestedParentWindow = nil
        }
    }

    static func configureVisibleWindows() {
        for window in NSApp.windows where window.isVisible {
            configurePresentation(window)
        }
    }

    private static func configurePresentation(_ window: NSWindow) {
        configureTabbingMode(window)
        configureChrome(window)
    }

    private static func configureTabbingMode(_ window: NSWindow) {
        window.tabbingIdentifier = NSWindow.TabbingIdentifier("family.ma.strata.document")
        window.tabbingMode = .preferred
    }

    private static func configureChrome(_ window: NSWindow) {
        window.isRestorable = false
        window.restorationClass = nil
    }
}

enum SessionState {
    private static let key = "openDocumentPaths"
    struct PendingUntitledCopy {
        let root: OutlineNode
        let displayName: String
    }

    private final class WindowStoreRef {
        weak var window: NSWindow?
        weak var store: OutlineStore?

        init(window: NSWindow, store: OutlineStore) {
            self.window = window
            self.store = store
        }
    }

    private static var windowStores: [ObjectIdentifier: WindowStoreRef] = [:]

    /// URLs waiting to be loaded by newly created windows during restoration.
    static var pendingRestoreURLs: [URL] = []
    static var pendingUntitledCopies: [PendingUntitledCopy] = []

    static func associate(store: OutlineStore, with window: NSWindow) {
        cleanupWindowStores()
        windowStores[ObjectIdentifier(window)] = WindowStoreRef(window: window, store: store)
    }

    /// Collect file paths from all living OutlineStore instances and save to UserDefaults.
    static func saveOpenDocuments() {
        let urls = orderedOpenDocumentURLs()
        // Deduplicate while preserving order
        var seen = Set<String>()
        let unique = urls.filter { seen.insert($0.path).inserted }
        UserDefaults.standard.set(unique.map(\.path), forKey: key)
    }

    /// Read saved document paths from UserDefaults, filtering out files that no longer exist.
    static func loadSavedDocuments() -> [URL] {
        guard let paths = UserDefaults.standard.stringArray(forKey: key) else { return [] }
        return paths.compactMap { path in
            let url = URL(fileURLWithPath: path)
            return FileManager.default.fileExists(atPath: path) ? url : nil
        }
    }

    private static func orderedOpenDocumentURLs() -> [URL] {
        cleanupWindowStores()

        var urls: [URL] = []
        var seenWindows = Set<ObjectIdentifier>()

        for window in NSApp.windows {
            let tabWindows = window.tabGroup?.windows ?? [window]
            for tabWindow in tabWindows {
                let id = ObjectIdentifier(tabWindow)
                guard seenWindows.insert(id).inserted,
                      tabWindow.isVisible,
                      let store = windowStores[id]?.store,
                      let url = store.currentFilePath else { continue }
                urls.append(url)
            }
        }

        return urls
    }

    private static func cleanupWindowStores() {
        windowStores = windowStores.filter { _, ref in
            guard let window = ref.window, ref.store != nil else { return false }
            return window.isVisible
        }
    }

    static func forget(window: NSWindow) {
        windowStores.removeValue(forKey: ObjectIdentifier(window))
    }

    static func forgetAndSave(window: NSWindow) {
        forget(window: window)
        DispatchQueue.main.async {
            saveOpenDocuments()
        }
    }
}

// MARK: - Focused Value for Active Store

struct ActiveStoreKey: FocusedValueKey {
    typealias Value = OutlineStore
}

struct OpenWindowActionKey: FocusedValueKey {
    typealias Value = OpenWindowAction
}

extension FocusedValues {
    var activeStore: OutlineStore? {
        get { self[ActiveStoreKey.self] }
        set { self[ActiveStoreKey.self] = newValue }
    }
    var openWindowAction: OpenWindowAction? {
        get { self[OpenWindowActionKey.self] }
        set { self[OpenWindowActionKey.self] = newValue }
    }
}

// MARK: - Recent Files

@Observable
class RecentFiles {
    static let shared = RecentFiles()
    private static let defaultsKey = "recentDocumentPaths"
    private static let maxItems = 12

    private(set) var urls: [URL] = []

    init() {
        refresh()
    }

    func refresh() {
        urls = Self.loadPersistedURLs()
        mergeNativeRecentDocuments()
    }

    func add(_ url: URL) {
        let standardizedURL = url.standardizedFileURL
        NSDocumentController.shared.noteNewRecentDocumentURL(standardizedURL)
        urls.removeAll { $0.standardizedFileURL.path == standardizedURL.path }
        urls.insert(standardizedURL, at: 0)
        pruneAndPersist()
    }

    func clear() {
        NSDocumentController.shared.clearRecentDocuments(nil)
        urls = []
        UserDefaults.standard.removeObject(forKey: Self.defaultsKey)
    }

    private static func loadPersistedURLs() -> [URL] {
        let paths = UserDefaults.standard.stringArray(forKey: defaultsKey) ?? []
        return paths
            .map { URL(fileURLWithPath: $0).standardizedFileURL }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    private func mergeNativeRecentDocuments() {
        var merged = urls
        for url in NSDocumentController.shared.recentDocumentURLs.map(\.standardizedFileURL) {
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            if !merged.contains(where: { $0.path == url.path }) {
                merged.append(url)
            }
        }
        urls = merged
        pruneAndPersist()
    }

    private func pruneAndPersist() {
        var seen = Set<String>()
        urls = urls
            .filter { FileManager.default.fileExists(atPath: $0.path) }
            .filter { seen.insert($0.standardizedFileURL.path).inserted }
        if urls.count > Self.maxItems {
            urls = Array(urls.prefix(Self.maxItems))
        }
        UserDefaults.standard.set(urls.map(\.path), forKey: Self.defaultsKey)
    }
}

// MARK: - Launch Open Panel

/// Shows a native NSOpenPanel with a "New Document" button in the button bar,
/// matching the standard DocumentGroup first-launch experience.
class LaunchPanelHelper: NSObject {
    private let panel: NSOpenPanel
    private var newDocButton: NSButton?
    private(set) var didClickNew = false

    init(panel: NSOpenPanel) {
        self.panel = panel
        super.init()
    }

    @objc func injectButton() {
        guard let contentView = panel.contentView else { return }

        let button = NSButton(title: "New Document", target: self, action: #selector(newDocClicked))
        button.bezelStyle = .rounded
        button.translatesAutoresizingMaskIntoConstraints = false
        self.newDocButton = button

        // Find the Cancel button's superview (the native button bar)
        if let cancelButton = Self.findButton(titled: "Cancel", in: contentView),
           let buttonBar = cancelButton.superview {
            buttonBar.addSubview(button)
            NSLayoutConstraint.activate([
                button.leadingAnchor.constraint(equalTo: buttonBar.leadingAnchor, constant: 20),
                button.centerYAnchor.constraint(equalTo: cancelButton.centerYAnchor)
            ])
        }
    }

    @objc private func newDocClicked() {
        didClickNew = true
        panel.cancel(nil)
    }

    private static func findButton(titled title: String, in view: NSView) -> NSButton? {
        if let button = view as? NSButton, button.title == title {
            return button
        }
        for subview in view.subviews {
            if let found = findButton(titled: title, in: subview) {
                return found
            }
        }
        return nil
    }
}

/// Returns the URL the user chose, or nil if they want a new document (or cancelled).
func showLaunchOpenPanel() -> URL? {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.init(filenameExtension: "opml")!]
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false

    let helper = LaunchPanelHelper(panel: panel)
    // Schedule button injection for after the panel's view hierarchy is built
    helper.perform(#selector(LaunchPanelHelper.injectButton), with: nil, afterDelay: 0)

    let result = panel.runModal()

    if helper.didClickNew {
        return nil
    }
    if result == .OK, let url = panel.url {
        return url
    }
    return nil
}

// MARK: - Document Window

struct DocumentWindowView: View {
    @State private var store = OutlineStore()
    @Environment(\.openWindow) private var openWindow

    private static var isFirstWindow = true

    var body: some View {
        ContentView(store: store)
            .focusedSceneValue(\.activeStore, store)
            .focusedSceneValue(\.openWindowAction, openWindow)
            .onAppear {
                if Self.isFirstWindow {
                    Self.isFirstWindow = false
                    // Defer to next run-loop tick so NSDocumentController has loaded its recent list
                    DispatchQueue.main.async {
                        restoreSession()
                    }
                } else if let copy = SessionState.pendingUntitledCopies.first {
                    SessionState.pendingUntitledCopies.removeFirst()
                    store.loadUntitledCopy(root: copy.root, displayName: copy.displayName)
                } else if let url = SessionState.pendingRestoreURLs.first {
                    // This window was created during session restoration — load its file
                    SessionState.pendingRestoreURLs.removeFirst()
                    store.loadFile(from: url)
                }
            }
    }

    /// Restore previously open documents: load saved session state, open additional
    /// tabs for each document beyond the first.
    private func restoreSession() {
        let savedURLs = SessionState.loadSavedDocuments()

        if !savedURLs.isEmpty {
            // Load the first document into this window
            store.loadFile(from: savedURLs[0])

            // Queue remaining URLs and open new windows/tabs for each
            let remaining = Array(savedURLs.dropFirst())
            if !remaining.isEmpty {
                SessionState.pendingRestoreURLs = remaining
                for _ in remaining {
                    WindowTabCoordinator.openNextWindowAsTab(using: openWindow)
                }
            }
            return
        }

        // No saved session — hide the placeholder window and show the native open panel.
        let window = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible })
        window?.orderOut(nil)

        if let url = showLaunchOpenPanel() {
            store.loadFile(from: url)
            window?.makeKeyAndOrderFront(nil)
        } else if let window {
            SessionState.forgetAndSave(window: window)
            window.close()
        }
    }
}

// MARK: - App Delegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var resignObserver: Any?
    private var closeObserver: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Keep tab creation under Strata's Cmd-T/menu flow until the app moves to
        // DocumentGroup/NSDocument.
        NSWindow.allowsAutomaticWindowTabbing = false

        // Save session state when the app loses focus (covers force-quit scenarios)
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil, queue: .main
        ) { _ in
            SessionState.saveOpenDocuments()
        }

        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: nil, queue: .main
        ) { notification in
            guard let window = notification.object as? NSWindow else { return }
            SessionState.forgetAndSave(window: window)
            DispatchQueue.main.async {
                WindowTabCoordinator.configureVisibleWindows()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        SessionState.saveOpenDocuments()
    }

    func application(_ application: NSApplication, shouldSaveSecureApplicationState coder: NSCoder) -> Bool {
        false
    }

    func application(_ application: NSApplication, shouldRestoreSecureApplicationState coder: NSCoder) -> Bool {
        false
    }

    deinit {
        if let resignObserver {
            NotificationCenter.default.removeObserver(resignObserver)
        }
        if let closeObserver {
            NotificationCenter.default.removeObserver(closeObserver)
        }
    }
}

// MARK: - App

@main
struct StrataApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @FocusedValue(\.activeStore) var activeStore
    @FocusedValue(\.openWindowAction) var openWindowAction
    @State private var recentFiles = RecentFiles.shared

    var body: some Scene {
        WindowGroup(id: "main") {
            DocumentWindowView()
        }
        .defaultSize(width: 720, height: 640)
        .commands {
            // MARK: Undo / Redo

            CommandGroup(replacing: .undoRedo) {
                Button("Undo") {
                    // Route to field editor's undo when editing text,
                    // otherwise use the store's snapshot undo for structural changes
                    if let window = NSApp.keyWindow,
                       let textView = window.firstResponder as? NSTextView,
                       textView.isFieldEditor {
                        if activeStore?.shouldRouteStructuralUndoToStore == true {
                            activeStore?.undo()
                            return
                        }
                        textView.undoManager?.undo()
                    } else {
                        activeStore?.undo()
                    }
                }
                .keyboardShortcut("z", modifiers: .command)

                Button("Redo") {
                    if let window = NSApp.keyWindow,
                       let textView = window.firstResponder as? NSTextView,
                       textView.isFieldEditor {
                        if activeStore?.shouldRouteStructuralRedoToStore == true {
                            activeStore?.redo()
                            return
                        }
                        textView.undoManager?.redo()
                    } else {
                        activeStore?.redo()
                    }
                }
                .keyboardShortcut("z", modifiers: [.command, .shift])
            }

            CommandGroup(replacing: .pasteboard) {
                Button("Cut") {
                    performCut()
                }
                .keyboardShortcut("x", modifiers: .command)

                Button("Copy") {
                    performCopy()
                }
                .keyboardShortcut("c", modifiers: .command)

                Button("Paste") {
                    performPaste()
                }
                .keyboardShortcut("v", modifiers: .command)

                Divider()

                Button("Select All") {
                    performSelectAll()
                }
                .keyboardShortcut("a", modifiers: .command)
            }

            // MARK: File — Open / Recent

            CommandGroup(replacing: .newItem) {
                Button("New Tab") {
                    openUntitledTab()
                }
                .keyboardShortcut("t")
            }

            CommandGroup(after: .newItem) {
                Divider()

                Button("Open...") {
                    openFileAsTab()
                }
                .keyboardShortcut("o")

                Menu("Open Recent") {
                    let urls = recentFiles.urls
                    ForEach(urls, id: \.self) { url in
                        Button(url.deletingPathExtension().lastPathComponent) {
                            openURLAsTab(url)
                        }
                        .help(url.path)
                    }
                    if !urls.isEmpty {
                        Divider()
                    }
                    Button("Clear Menu") {
                        recentFiles.clear()
                    }
                    .disabled(urls.isEmpty)
                }
            }

            // MARK: File — Save / Duplicate / Export

            CommandGroup(replacing: .saveItem) {
                Button("Save") {
                    activeStore?.saveExplicitly()
                }
                .keyboardShortcut("s")

                Button("Save As...") {
                    activeStore?.saveFileAs()
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])

                Button("Duplicate") {
                    duplicateActiveDocument()
                }

                Divider()

                Menu("Export As") {
                    Button("Plain Text (.txt)") {
                        activeStore?.exportAs(format: "txt")
                    }
                    Button("Markdown (.md)") {
                        activeStore?.exportAs(format: "md")
                    }
                    Button("HTML (.html)") {
                        activeStore?.exportAs(format: "html")
                    }
                }
            }

            // MARK: Find

            CommandGroup(after: .textEditing) {
                Button("Find") {
                    if let store = activeStore {
                        store.isSearchActive.toggle()
                        if !store.isSearchActive { store.searchQuery = "" }
                    }
                }
                .keyboardShortcut("f", modifiers: .command)
            }

            // MARK: View

            CommandGroup(after: .toolbar) {
                Toggle("Hide Completed Items", isOn: Binding(
                    get: { activeStore?.hideCompleted ?? false },
                    set: { activeStore?.hideCompleted = $0 }
                ))
                .disabled(activeStore == nil)
            }

            // MARK: Format

            CommandMenu("Format") {
                Button("Bold") {
                    StrataTextField.currentEditingField?.wrapBold()
                }
                .keyboardShortcut("b", modifiers: .command)

                Button("Italic") {
                    StrataTextField.currentEditingField?.wrapItalic()
                }
                .keyboardShortcut("i", modifiers: .command)

                Button("Highlight") {
                    StrataTextField.currentEditingField?.wrapHighlight()
                }
                .keyboardShortcut("h", modifiers: [.command, .shift])

                Divider()

                Button("Link...") {
                    StrataTextField.currentEditingField?.editLink()
                }
                .keyboardShortcut("k", modifiers: .command)
            }

            // MARK: Window — Tab Switching

            CommandGroup(after: .windowArrangement) {
                Button("Close Tab") {
                    closeCurrentTab()
                }
                .keyboardShortcut("w")

                Divider()

                Button("Select Tab 1") {
                    selectTab(at: 0)
                }
                .keyboardShortcut("1", modifiers: .command)

                Button("Select Tab 2") {
                    selectTab(at: 1)
                }
                .keyboardShortcut("2", modifiers: .command)

                Button("Select Tab 3") {
                    selectTab(at: 2)
                }
                .keyboardShortcut("3", modifiers: .command)
            }

            // MARK: Outline

            CommandMenu("Outline") {
                Button("Move Node Up") {
                    if let field = StrataTextField.currentEditingField {
                        if field.onCmdShiftUp?() == true {
                            field.markStructuralEditForUndo()
                        }
                    } else {
                        activeStore?.moveSelectedUp()
                    }
                }
                .keyboardShortcut(.upArrow, modifiers: .command)

                Button("Move Node Down") {
                    if let field = StrataTextField.currentEditingField {
                        if field.onCmdShiftDown?() == true {
                            field.markStructuralEditForUndo()
                        }
                    } else {
                        activeStore?.moveSelectedDown()
                    }
                }
                .keyboardShortcut(.downArrow, modifiers: .command)

                Button("Merge Selected Nodes") {
                    activeStore?.mergeSelected()
                }
                .keyboardShortcut("j", modifiers: .command)

                Divider()

                Button("Zoom In") {
                    if let store = activeStore,
                       let focusedId = store.pendingFocusId ?? store.currentRoot.children.first?.id {
                        store.zoomIn(nodeId: focusedId)
                    }
                }
                .keyboardShortcut("]", modifiers: .command)

                Button("Zoom Out") {
                    activeStore?.zoomOut()
                }
                .keyboardShortcut("[", modifiers: .command)

                Button("Zoom to Home") {
                    activeStore?.zoomToRoot()
                }
                .keyboardShortcut("\\", modifiers: .command)

                Divider()

                Button("Collapse All") {
                    if let store = activeStore {
                        collapseAll(store.currentRoot)
                        store.scheduleSave()
                    }
                }

                Button("Expand All") {
                    if let store = activeStore {
                        expandAll(store.currentRoot)
                        store.scheduleSave()
                    }
                }
            }
        }
    }

    /// Opens a file picker and loads the chosen file — in the current window if it's
    /// untitled, or in a new tab if the window already has a document.
    private func openFileAsTab() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.init(filenameExtension: "opml")!]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        guard panel.runModal() == .OK, let url = panel.url else { return }
        openURLAsTab(url)
    }

    private func openUntitledTab() {
        if let store = activeStore, store.currentFilePath == nil, store.root.children.count == 1, store.root.children[0].text.isEmpty {
            return
        }

        if let openWindow = openWindowAction {
            WindowTabCoordinator.openNextWindowAsTab(using: openWindow)
        }
    }

    private func duplicateActiveDocument() {
        guard let store = activeStore,
              let openWindow = openWindowAction else { return }

        let duplicate = store.duplicateTemplate()
        SessionState.pendingUntitledCopies.append(
            SessionState.PendingUntitledCopy(root: duplicate.root, displayName: duplicate.displayName)
        )
        WindowTabCoordinator.openNextWindowAsTab(using: openWindow)
    }

    private func activeFieldEditor() -> NSTextView? {
        guard let window = NSApp.keyWindow,
              let textView = window.firstResponder as? NSTextView,
              textView.isFieldEditor else { return nil }
        return textView
    }

    private func performCut() {
        if let textView = activeFieldEditor() {
            textView.cut(nil)
        } else {
            activeStore?.cutSelected()
        }
    }

    private func performCopy() {
        if let textView = activeFieldEditor() {
            textView.copy(nil)
        } else {
            activeStore?.copySelectedAsText()
        }
    }

    private func performPaste() {
        if let textView = activeFieldEditor() {
            let pasteboard = NSPasteboard.general
            if pasteboard.data(forType: OutlineStore.nodePasteboardType) != nil {
                if StrataTextField.currentEditingField?.onPasteNodes?() == true {
                    StrataTextField.currentEditingField?.markStructuralEditForUndo()
                }
            } else if let text = pasteboard.string(forType: .string),
                      text.contains("\n") || text.contains("\r") {
                if StrataTextField.currentEditingField?.onPasteNodes?() == true {
                    StrataTextField.currentEditingField?.markStructuralEditForUndo()
                }
            } else {
                textView.paste(nil)
            }
        } else {
            activeStore?.pasteAfterSelection()
        }
    }

    private func performSelectAll() {
        if let textView = activeFieldEditor() {
            let fullRange = NSRange(location: 0, length: (textView.string as NSString).length)
            if textView.selectedRange == fullRange {
                StrataTextField.currentEditingField?.onSelectAllNodes?()
            } else {
                textView.selectAll(nil)
            }
        } else {
            activeStore?.selectAllVisible()
        }
    }

    private func closeCurrentTab() {
        guard let window = NSApp.keyWindow else { return }
        activeStore?.save()
        SessionState.forget(window: window)
        window.performClose(nil)

        DispatchQueue.main.async {
            SessionState.saveOpenDocuments()
            WindowTabCoordinator.configureVisibleWindows()
        }
    }

    /// Load a URL — reuse the current window if untitled, otherwise open a new tab.
    private func openURLAsTab(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            recentFiles.refresh()
            NSSound.beep()
            return
        }

        recentFiles.add(url)
        if let store = activeStore, store.currentFilePath == nil {
            // Current window is untitled — load into it
            store.loadFile(from: url)
        } else if let openWindow = openWindowAction {
            // Current window has a file — open in a new tab
            SessionState.pendingRestoreURLs.append(url)
            WindowTabCoordinator.openNextWindowAsTab(using: openWindow)
        } else {
            // Fallback: load into current window
            activeStore?.loadFile(from: url)
        }
    }

    private func selectTab(at index: Int) {
        guard let windows = NSApp.keyWindow?.tabGroup?.windows,
              windows.indices.contains(index) else { return }
        windows[index].makeKeyAndOrderFront(nil)
    }

    private func collapseAll(_ node: OutlineNode) {
        for child in node.children {
            child.isExpanded = false
            collapseAll(child)
        }
    }

    private func expandAll(_ node: OutlineNode) {
        for child in node.children {
            child.isExpanded = true
            expandAll(child)
        }
    }
}
