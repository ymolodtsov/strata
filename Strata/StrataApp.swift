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

    static func configure(_ window: NSWindow?) {
        guard let window else { return }
        configurePresentation(window)

        guard pendingTabCount > 0 else { return }

        // If the parent window was deallocated or became invisible, reset to avoid drift
        guard let parent = requestedParentWindow, parent.isVisible else {
            pendingTabCount = 0
            requestedParentWindow = nil
            return
        }
        guard parent != window else { return }

        let alreadyTabbedWithParent =
            parent.tabGroup?.windows.contains(window) == true ||
            window.tabGroup?.windows.contains(parent) == true
        guard !alreadyTabbedWithParent else {
            pendingTabCount -= 1
            if pendingTabCount == 0 { requestedParentWindow = nil }
            return
        }

        window.setFrame(parent.frame, display: false)
        window.alphaValue = 0
        window.orderOut(nil)
        let parentAnimationBehavior = parent.animationBehavior
        let windowAnimationBehavior = window.animationBehavior
        parent.animationBehavior = .none
        window.animationBehavior = .none
        parent.tabbingMode = .preferred
        window.tabbingMode = .preferred
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            context.allowsImplicitAnimation = false
            if parent.tabGroup?.isTabBarVisible == false {
                parent.toggleTabBar(nil)
            }
            if let tabGroup = parent.tabGroup {
                tabGroup.addWindow(window)
                tabGroup.selectedWindow = window
            } else {
                parent.addTabbedWindow(window, ordered: .above)
            }
            window.alphaValue = 1
        }
        parent.animationBehavior = parentAnimationBehavior
        window.animationBehavior = windowAnimationBehavior
        pendingTabCount -= 1
        if pendingTabCount == 0 {
            requestedParentWindow = nil
        }
        DispatchQueue.main.async {
            configureVisibleWindows()
        }
    }

    static func configureVisibleWindows() {
        for window in NSApp.windows where window.isVisible {
            configurePresentation(window)
        }
    }

    private static func configurePresentation(_ window: NSWindow) {
        configureTabbingMode(window)
        configureTabBarVisibility(window)
        configureChrome(window)
    }

    private static func configureTabbingMode(_ window: NSWindow) {
        window.tabbingIdentifier = NSWindow.TabbingIdentifier("family.ma.strata.document")
        window.tabbingMode = .preferred
    }

    private static func configureTabBarVisibility(_ window: NSWindow) {
        guard let tabGroup = window.tabGroup else { return }
        let shouldShowTabBar = tabGroup.windows.count > 1
        guard tabGroup.isTabBarVisible != shouldShowTabBar else { return }

        let animationBehavior = window.animationBehavior
        window.animationBehavior = .none
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            context.allowsImplicitAnimation = false
            window.toggleTabBar(nil)
        }
        window.animationBehavior = animationBehavior
    }

    private static var configuredWindows = NSHashTable<NSWindow>.weakObjects()

    private static func configureChrome(_ window: NSWindow) {
        guard !configuredWindows.contains(window) else { return }
        configuredWindows.add(window)
        window.isRestorable = false
        window.restorationClass = nil
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = false
        window.titlebarSeparatorStyle = .none
        window.isOpaque = true
        window.backgroundColor = .textBackgroundColor
        if window.styleMask.contains(.fullSizeContentView) {
            window.styleMask.remove(.fullSizeContentView)
        }
    }
}

enum SessionState {
    private static let key = "openDocumentPaths"
    private static let didShowWelcomeDocumentKey = "didShowWelcomeDocument.1.2.0"
    static let openURLsNotification = Notification.Name("StrataOpenURLsNotification")

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
    static var pendingWorkflowyImportURLs: [URL] = []
    static var pendingUntitledCopies: [PendingUntitledCopy] = []
    private static var pendingOpenURLs: [URL] = []

    static func queueOpenURLs(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        pendingOpenURLs.append(contentsOf: urls)
        NotificationCenter.default.post(name: openURLsNotification, object: nil)
    }

    static func consumePendingOpenURLs() -> [URL] {
        let urls = pendingOpenURLs
        pendingOpenURLs.removeAll()
        return urls
    }

    static func associate(store: OutlineStore, with window: NSWindow) {
        cleanupWindowStores()
        windowStores[ObjectIdentifier(window)] = WindowStoreRef(window: window, store: store)
    }

    static func store(for window: NSWindow?) -> OutlineStore? {
        cleanupWindowStores()
        if let window,
           let store = windowStores[ObjectIdentifier(window)]?.store {
            return store
        }
        return nil
    }

    static func bestActiveStore() -> OutlineStore? {
        store(for: NSApp.keyWindow) ??
        store(for: NSApp.mainWindow) ??
        NSApp.windows.lazy.compactMap { windowStores[ObjectIdentifier($0)]?.store }.first
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

    static var shouldShowWelcomeDocument: Bool {
        !UserDefaults.standard.bool(forKey: didShowWelcomeDocumentKey)
    }

    static func markWelcomeDocumentShown() {
        UserDefaults.standard.set(true, forKey: didShowWelcomeDocumentKey)
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
                      let url = store.document?.fileURL else { continue }
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
                // If a StrataDocument was queued for this window, adopt its store.
                if let pendingDoc = StrataDocumentController.dequeuePendingDocument() {
                    adoptDocument(pendingDoc)
                } else if Self.isFirstWindow {
                    Self.isFirstWindow = false
                    restoreSession()
                } else if let copy = SessionState.pendingUntitledCopies.first {
                    SessionState.pendingUntitledCopies.removeFirst()
                    store.loadUntitledCopy(root: copy.root, displayName: copy.displayName)
                    wrapStoreInDocument()
                } else if let url = SessionState.pendingRestoreURLs.first {
                    // This window was created during session restoration -- load its file
                    SessionState.pendingRestoreURLs.removeFirst()
                    store.loadFile(from: url)
                    wrapStoreInDocument(url: url)
                } else if let url = SessionState.pendingWorkflowyImportURLs.first {
                    SessionState.pendingWorkflowyImportURLs.removeFirst()
                    store.loadWorkflowyOPMLImport(from: url)
                    wrapStoreInDocument()
                } else {
                    // Untitled new tab — wrap in a StrataDocument
                    wrapStoreInDocument()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: SessionState.openURLsNotification)) { _ in
                openQueuedURLs()
            }
    }

    /// Replace this view's store with the one owned by an existing StrataDocument.
    private func adoptDocument(_ doc: StrataDocument) {
        store = doc.store
    }

    /// Wrap the current store in a StrataDocument so NSDocument tracks it.
    /// If a URL is provided, it becomes the document's file URL.
    private func wrapStoreInDocument(url: URL? = nil) {
        if store.document == nil {
            let doc = StrataDocument(store: store)
            if let url {
                doc.fileURL = url
                doc.fileType = "org.opml.opml"
            }
            NSDocumentController.shared.addDocument(doc)
        } else if let url {
            store.document?.fileURL = url
            store.document?.fileType = "org.opml.opml"
        }
    }

    /// Restore previously open documents: load saved session state, open additional
    /// tabs for each document beyond the first.
    private func restoreSession() {
        let queuedURLs = SessionState.consumePendingOpenURLs()
        if !queuedURLs.isEmpty {
            openURLs(queuedURLs, preferCurrentWindow: true)
            return
        }

        let savedURLs = SessionState.loadSavedDocuments()

        if !savedURLs.isEmpty {
            // Load the first document into this window
            store.loadFile(from: savedURLs[0])
            wrapStoreInDocument(url: savedURLs[0])

            // Queue remaining URLs and open new windows/tabs for each
            let remaining = Array(savedURLs.dropFirst())
            if !remaining.isEmpty {
                SessionState.pendingRestoreURLs = remaining
                for _ in remaining {
                    WindowTabCoordinator.requestNextWindowAsTab()
                    openWindow(id: "main")
                }
            }
            return
        }

        if SessionState.shouldShowWelcomeDocument, store.loadBundledWelcomeDocument() {
            SessionState.markWelcomeDocumentShown()
            wrapStoreInDocument()
            let window = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible })
            window?.makeKeyAndOrderFront(nil)
            return
        }

        // No saved session — start with an empty untitled document.
        wrapStoreInDocument()
    }

    private func openQueuedURLs() {
        let urls = SessionState.consumePendingOpenURLs()
        guard !urls.isEmpty else { return }
        openURLs(urls, preferCurrentWindow: store.document?.fileURL == nil)
    }

    private func openURLs(_ urls: [URL], preferCurrentWindow: Bool) {
        guard let first = urls.first else { return }
        let remaining: ArraySlice<URL>

        if preferCurrentWindow && store.document?.fileURL == nil {
            store.loadFile(from: first)
            wrapStoreInDocument(url: first)
            remaining = urls.dropFirst()
        } else {
            remaining = urls[...]
        }

        guard !remaining.isEmpty else { return }
        SessionState.pendingRestoreURLs.append(contentsOf: remaining)
        for _ in remaining {
            WindowTabCoordinator.requestNextWindowAsTab()
            openWindow(id: "main")
        }
    }
}

// MARK: - App Delegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    // Created at init time — before SwiftUI accesses NSDocumentController.shared —
    // so our subclass is registered as the shared controller.
    private let documentController = StrataDocumentController()
    private var resignObserver: Any?
    private var closeObserver: Any?
    private var isTerminating = false

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        // Let DocumentWindowView handle first-launch logic (session restore, welcome doc).
        // Returning false prevents NSDocumentController from creating its own untitled doc.
        false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Tab creation is managed by Strata's own Cmd-T/menu flow via StrataDocumentController.
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
        ) { [weak self] notification in
            guard let window = notification.object as? NSWindow else { return }
            guard self?.isTerminating != true else { return }
            SessionState.forgetAndSave(window: window)
            DispatchQueue.main.async {
                WindowTabCoordinator.configureVisibleWindows()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        isTerminating = true
        SessionState.saveOpenDocuments()
    }

    func application(_ application: NSApplication, shouldSaveSecureApplicationState coder: NSCoder) -> Bool {
        false
    }

    func application(_ application: NSApplication, shouldRestoreSecureApplicationState coder: NSCoder) -> Bool {
        false
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        SessionState.queueOpenURLs(urls)
    }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        SessionState.queueOpenURLs([URL(fileURLWithPath: filename)])
        return true
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
    @State private var recentFilesVersion = 0

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

                Button("Copy as Markdown") {
                    copyAsMarkdown()
                }
                .keyboardShortcut("c", modifiers: [.command, .shift])

                Button("Paste") {
                    performPaste()
                }
                .keyboardShortcut("v", modifiers: .command)

                Divider()

                Button("Insert Date") {
                    insertCurrentDate()
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])

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

                Divider()

                Button("Open...") {
                    openFileAsTab()
                }
                .keyboardShortcut("o")

                Button("Import from Workflowy OPML...") {
                    importWorkflowyOPMLAsTab()
                }

                Menu("Open Recent") {
                    let _ = recentFilesVersion // trigger SwiftUI re-evaluation
                    let urls = NSDocumentController.shared.recentDocumentURLs
                    ForEach(urls, id: \.self) { url in
                        Button(OutlineStore.displayName(for: url)) {
                            openURLAsTab(url)
                        }
                        .help(url.path)
                    }
                    if !urls.isEmpty {
                        Divider()
                    }
                    Button("Clear Menu") {
                        NSDocumentController.shared.clearRecentDocuments(nil)
                        recentFilesVersion += 1
                    }
                    .disabled(urls.isEmpty)
                }
            }

            // MARK: File — Save / Duplicate / Export

            CommandGroup(replacing: .saveItem) {
                Button("Save") {
                    activeStore?.document?.save(nil)
                }
                .keyboardShortcut("s")

                Button("Save As...") {
                    activeStore?.document?.saveAs(nil)
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])

                Button("Duplicate") {
                    duplicateActiveDocument()
                }

                Divider()

                Button("Check for Updates...") {
                    openUpdatesPage()
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

                Button("Underline") {
                    StrataTextField.currentEditingField?.wrapUnderline()
                }
                .keyboardShortcut("u", modifiers: .command)

                Button("Highlight") {
                    StrataTextField.currentEditingField?.wrapHighlight()
                }
                .keyboardShortcut("l", modifiers: .command)

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
        panel.allowedContentTypes = OutlineStore.readableContentTypes
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        guard panel.runModal() == .OK, let url = panel.url else { return }
        openURLAsTab(url)
    }

    private func importWorkflowyOPMLAsTab() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [OutlineStore.opmlContentType]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        guard panel.runModal() == .OK, let url = panel.url else { return }
        openWorkflowyImportURLAsTab(url)
    }

    private func openUntitledTab() {
        if let store = activeStore, store.document?.fileURL == nil, store.root.children.count == 1, store.root.children[0].text.isEmpty {
            return
        }

        guard let openWindow = openWindowAction else { return }
        let doc = StrataDocument()
        NSDocumentController.shared.addDocument(doc)
        StrataDocumentController.enqueuePendingDocument(doc)
        WindowTabCoordinator.requestNextWindowAsTab()
        openWindow(id: "main")
    }

    private func duplicateActiveDocument() {
        guard let store = activeStore,
              let openWindow = openWindowAction else { return }

        let duplicate = store.duplicateTemplate()
        SessionState.pendingUntitledCopies.append(
            SessionState.PendingUntitledCopy(root: duplicate.root, displayName: duplicate.displayName)
        )
        WindowTabCoordinator.requestNextWindowAsTab()
        openWindow(id: "main")
    }

    private func openUpdatesPage() {
        guard let url = URL(string: "https://github.com/ymolodtsov/strata/releases") else { return }
        NSWorkspace.shared.open(url)
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

    private func copyAsMarkdown() {
        guard let store = activeStore else { return }
        let md = ExportService.markdown(root: store.currentRoot)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(md, forType: .string)
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
            } else if let text = pasteboard.string(forType: .string) {
                // Insert as plain text to strip foreign rich-text formatting
                textView.insertText(text, replacementRange: textView.selectedRange)
            }
        } else {
            activeStore?.pasteAfterSelection()
        }
    }

    private func insertCurrentDate() {
        guard let field = StrataTextField.currentEditingField else { return }
        field.insertDateString(StrataTextField.localizedCurrentDateString())
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
        window.performClose(nil)

        DispatchQueue.main.async {
            SessionState.saveOpenDocuments()
            WindowTabCoordinator.configureVisibleWindows()
        }
    }

    /// Load a URL — reuse the current window if untitled, otherwise open a new tab.
    private func openURLAsTab(_ url: URL) {
        let fileURL = url.standardizedFileURL
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            NSSound.beep()
            return
        }

        let targetStore = activeStore ?? SessionState.bestActiveStore()
        if let store = targetStore, store.document?.fileURL == nil {
            // Current window is untitled -- load into it
            store.loadFile(from: fileURL)
            store.document?.fileURL = fileURL
            store.document?.fileType = "org.opml.opml"
            NSDocumentController.shared.noteNewRecentDocumentURL(fileURL)
            recentFilesVersion += 1
        } else if let openWindow = openWindowAction {
            // Current window has a file — open in a new tab
            // Check if already open
            if let existingDoc = NSDocumentController.shared.documents.first(where: { $0.fileURL?.standardizedFileURL == fileURL }) as? StrataDocument {
                existingDoc.showWindows()
            } else {
                let doc = StrataDocument()
                doc.store.loadFile(from: fileURL)
                doc.fileURL = fileURL
                doc.fileType = "org.opml.opml"
                NSDocumentController.shared.addDocument(doc)
                NSDocumentController.shared.noteNewRecentDocumentURL(fileURL)
                StrataDocumentController.enqueuePendingDocument(doc)
                WindowTabCoordinator.requestNextWindowAsTab()
                openWindow(id: "main")
            }
            recentFilesVersion += 1
        } else {
            // Fallback for menu/native recent paths where SwiftUI focused values are unavailable.
            SessionState.queueOpenURLs([fileURL])
        }
    }

    private func openWorkflowyImportURLAsTab(_ url: URL) {
        let fileURL = url.standardizedFileURL
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            NSSound.beep()
            return
        }

        let targetStore = activeStore ?? SessionState.bestActiveStore()
        if let store = targetStore, store.document?.fileURL == nil {
            store.loadWorkflowyOPMLImport(from: fileURL)
        } else if let openWindow = openWindowAction {
            WindowTabCoordinator.requestNextWindowAsTab()
            SessionState.pendingWorkflowyImportURLs.append(fileURL)
            openWindow(id: "main")
        } else {
            NSSound.beep()
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
