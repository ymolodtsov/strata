import AppKit
import SwiftUI

enum AppWindowBootstrap {
    private static var controllers: [NSWindowController] = []

    static func openWindow() {
        if Thread.isMainThread {
            openWindowOnMain()
        } else {
            DispatchQueue.main.async {
                openWindowOnMain()
            }
        }
    }

    static func openWindowIfNeeded() {
        if Thread.isMainThread {
            guard shouldOpenBootstrapWindow else { return }
            openWindowOnMain()
        } else {
            DispatchQueue.main.async {
                guard shouldOpenBootstrapWindow else { return }
                openWindowOnMain()
            }
        }
    }

    static func closeUntitledBootstrapWindows() {
        DispatchQueue.main.async {
            controllers = controllers.filter { controller in
                guard let window = controller.window else { return false }
                if window.isVisible && window.title.hasPrefix("Untitled") {
                    window.close()
                    return false
                }
                return window.isVisible
            }
        }
    }

    private static var shouldOpenBootstrapWindow: Bool {
        NSApp.windows.contains(where: { $0.isVisible }) == false
            && NSDocumentController.shared.documents.isEmpty
            && StrataDocumentController.pendingDocuments.isEmpty
    }

    private static func openWindowOnMain() {
        let controller = makeWindowController()
        controllers.append(controller)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        pruneClosedControllers()
    }

    private static func makeWindowController() -> NSWindowController {
        let content = DocumentWindowView()
        let hostingController = NSHostingController(rootView: content)
        let window = NSWindow(contentViewController: hostingController)
        window.setContentSize(NSSize(width: 720, height: 640))
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.title = "Strata"
        window.isReleasedWhenClosed = false
        window.center()
        return NSWindowController(window: window)
    }

    private static func pruneClosedControllers() {
        controllers = controllers.filter { $0.window?.isVisible == true }
    }
}

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
    private static let draftsKey = "untitledDraftPaths"
    private static let windowGroupsKey = "windowTabGroups"
    private static let didShowWelcomeDocumentKey = "didShowWelcomeDocument.1.2.0"
    static let openURLsNotification = Notification.Name("StrataOpenURLsNotification")

    private static var draftsDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("Strata/UntitledDrafts", isDirectory: true)
    }

    struct PendingUntitledCopy {
        let root: OutlineNode
        let displayName: String
    }

    /// Cached OpenWindowAction so we can open windows even when no window is focused.
    static var cachedOpenWindow: OpenWindowAction?

    private final class WindowStoreRef {
        weak var window: NSWindow?
        weak var store: OutlineStore?

        init(window: NSWindow, store: OutlineStore) {
            self.window = window
            self.store = store
        }
    }

    private static var windowStores: [ObjectIdentifier: WindowStoreRef] = [:]

    private final class StoreRef {
        weak var store: OutlineStore?

        init(store: OutlineStore) {
            self.store = store
        }
    }

    private static var liveStores: [ObjectIdentifier: StoreRef] = [:]

    /// Items waiting to be loaded by newly created windows during restoration.
    struct PendingRestoreItem {
        let url: URL
        let isDraft: Bool
        let isNewWindow: Bool  // true = open as new window, false = add as tab
    }

    static var pendingRestoreURLs: [URL] = []
    static var pendingRestoreDrafts: [URL] = []
    static var pendingRestoreItems: [PendingRestoreItem] = []
    static var pendingWorkflowyImportURLs: [URL] = []
    static var pendingUntitledCopies: [PendingUntitledCopy] = []
    private static var pendingOpenURLs: [URL] = []

    static func queueOpenURLs(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        pendingOpenURLs.append(contentsOf: urls)
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: openURLsNotification, object: nil)
        }
    }

    static func consumePendingOpenURLs() -> [URL] {
        let urls = pendingOpenURLs
        pendingOpenURLs.removeAll()
        return urls
    }

    static func associate(store: OutlineStore, with window: NSWindow) {
        cleanupWindowStores()
        register(store: store)
        windowStores[ObjectIdentifier(window)] = WindowStoreRef(window: window, store: store)
    }

    static func register(store: OutlineStore) {
        cleanupLiveStores()
        liveStores[ObjectIdentifier(store)] = StoreRef(store: store)
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

    static func closeEmptyUntitledWindows() {
        cleanupWindowStores()
        for (_, ref) in windowStores {
            guard let window = ref.window,
                  window.isVisible,
                  let store = ref.store,
                  store.document?.fileURL == nil,
                  isEmptyUntitled(store) else { continue }
            window.close()
        }
    }

    private static func isEmptyUntitled(_ store: OutlineStore) -> Bool {
        store.root.children.count == 1
            && store.root.children[0].text.isEmpty
            && store.root.children[0].note.isEmpty
            && store.root.children[0].children.isEmpty
    }

    /// Collect file paths from all living OutlineStore instances and save to UserDefaults.
    /// Also saves untitled document content to draft files and preserves window/tab grouping.
    static func saveOpenDocuments() {
        cleanupWindowStores()
        let fm = FileManager.default

        // Ensure drafts directory exists
        try? fm.createDirectory(at: draftsDirectory, withIntermediateDirectories: true)

        // Remove old draft files before saving new ones
        let oldDraftPaths = UserDefaults.standard.stringArray(forKey: draftsKey) ?? []
        for path in oldDraftPaths {
            try? fm.removeItem(atPath: path)
        }

        // Build window groups: [[entry]] where each entry is either a file path or a draft UUID
        var windowGroups: [[[String: String]]] = []
        var savedDraftPaths: [String] = []
        var seenWindows = Set<ObjectIdentifier>()

        // Collect flat list for backward-compatible key
        var flatSavedPaths: [String] = []
        var seenPaths = Set<String>()

        for window in NSApp.windows {
            let tabWindows = window.tabGroup?.windows ?? [window]
            var group: [[String: String]] = []

            for tabWindow in tabWindows {
                let id = ObjectIdentifier(tabWindow)
                guard seenWindows.insert(id).inserted,
                      tabWindow.isVisible,
                      let store = windowStores[id]?.store else { continue }

                if let url = store.document?.fileURL {
                    // Saved document
                    let path = url.path
                    group.append(["path": path, "isDraft": "false"])
                    if seenPaths.insert(path).inserted {
                        flatSavedPaths.append(path)
                    }
                } else if store.root.children.count > 1 ||
                          (store.root.children.count == 1 && !store.root.children[0].text.isEmpty) {
                    // Untitled document with content -- save as draft
                    let draftId = UUID().uuidString
                    let draftURL = draftsDirectory.appendingPathComponent("\(draftId).opml")
                    let data = OPMLService.serialize(root: store.root)
                    do {
                        try data.write(to: draftURL, options: .atomic)
                        savedDraftPaths.append(draftURL.path)
                        group.append(["draft": draftId, "isDraft": "true"])
                    } catch {
                        // Draft save failed -- skip this entry
                    }
                }
            }

            if !group.isEmpty {
                windowGroups.append(group)
            }
        }

        if windowGroups.isEmpty && NSApp.windows.contains(where: { $0.isVisible }) {
            var group: [[String: String]] = []
            var fallbackStores: [OutlineStore] = []
            var seenStoreIds = Set<ObjectIdentifier>()

            for doc in NSDocumentController.shared.documents.compactMap({ $0 as? StrataDocument }) {
                if seenStoreIds.insert(ObjectIdentifier(doc.store)).inserted {
                    fallbackStores.append(doc.store)
                }
            }
            cleanupLiveStores()
            for (_, ref) in liveStores {
                if let store = ref.store,
                   seenStoreIds.insert(ObjectIdentifier(store)).inserted {
                    fallbackStores.append(store)
                }
            }

            for store in fallbackStores {
                if let url = store.document?.fileURL {
                    let path = url.path
                    group.append(["path": path, "isDraft": "false"])
                    if seenPaths.insert(path).inserted {
                        flatSavedPaths.append(path)
                    }
                } else if store.root.children.count > 1 ||
                            (store.root.children.count == 1 && !store.root.children[0].text.isEmpty) {
                    let draftId = UUID().uuidString
                    let draftURL = draftsDirectory.appendingPathComponent("\(draftId).opml")
                    let data = OPMLService.serialize(root: store.root)
                    do {
                        try data.write(to: draftURL, options: .atomic)
                        savedDraftPaths.append(draftURL.path)
                        group.append(["draft": draftId, "isDraft": "true"])
                    } catch {
                        // Draft save failed -- skip this entry
                    }
                }
            }
            if !group.isEmpty {
                windowGroups.append(group)
            }
        }

        // Save backward-compatible flat list (saved files only)
        UserDefaults.standard.set(flatSavedPaths, forKey: key)
        // Save draft paths for cleanup
        UserDefaults.standard.set(savedDraftPaths, forKey: draftsKey)
        // Save window groups as JSON
        if let data = try? JSONSerialization.data(withJSONObject: windowGroups),
           let json = String(data: data, encoding: .utf8) {
            UserDefaults.standard.set(json, forKey: windowGroupsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: windowGroupsKey)
        }
        UserDefaults.standard.synchronize()
    }

    /// Load saved session state including window groups and drafts.
    /// Returns an array of window groups, where each group is an array of (url, isDraft) pairs.
    static func loadSavedWindowGroups() -> [[(url: URL, isDraft: Bool)]] {
        let fm = FileManager.default

        // Try the new window groups format first
        if let json = UserDefaults.standard.string(forKey: windowGroupsKey),
           let data = json.data(using: .utf8),
           let rawGroups = try? JSONSerialization.jsonObject(with: data) as? [[[String: String]]] {

            var result: [[(url: URL, isDraft: Bool)]] = []

            for group in rawGroups {
                var entries: [(url: URL, isDraft: Bool)] = []
                for entry in group {
                    if entry["isDraft"] == "true", let draftId = entry["draft"] {
                        let draftURL = draftsDirectory.appendingPathComponent("\(draftId).opml")
                        if fm.fileExists(atPath: draftURL.path) {
                            entries.append((draftURL, true))
                        }
                    } else if let path = entry["path"] {
                        let url = URL(fileURLWithPath: path)
                        if fm.fileExists(atPath: path) {
                            entries.append((url, false))
                        }
                    }
                }
                if !entries.isEmpty {
                    result.append(entries)
                }
            }

            if !result.isEmpty {
                return result
            }
        }

        // Fallback: load from flat list (backward compatibility)
        let savedURLs = loadSavedDocuments()
        if !savedURLs.isEmpty {
            return [savedURLs.map { ($0, false) }]
        }
        return []
    }

    /// Read saved document paths from UserDefaults, filtering out files that no longer exist.
    static func loadSavedDocuments() -> [URL] {
        guard let paths = UserDefaults.standard.stringArray(forKey: key) else { return [] }
        return paths.compactMap { path in
            let url = URL(fileURLWithPath: path)
            return FileManager.default.fileExists(atPath: path) ? url : nil
        }
    }

    /// Remove a draft file when the user saves or closes the document.
    static func cleanupDraft(at url: URL) {
        guard url.path.contains("UntitledDrafts") else { return }
        try? FileManager.default.removeItem(at: url)
        // Update the saved drafts list
        var paths = UserDefaults.standard.stringArray(forKey: draftsKey) ?? []
        paths.removeAll { $0 == url.path }
        UserDefaults.standard.set(paths, forKey: draftsKey)
    }

    /// Remove all draft files (called when all drafts have been restored).
    static func cleanupAllDrafts() {
        let paths = UserDefaults.standard.stringArray(forKey: draftsKey) ?? []
        for path in paths {
            try? FileManager.default.removeItem(atPath: path)
        }
        UserDefaults.standard.removeObject(forKey: draftsKey)
    }

    static var shouldShowWelcomeDocument: Bool {
        !UserDefaults.standard.bool(forKey: didShowWelcomeDocumentKey)
    }

    static func markWelcomeDocumentShown() {
        UserDefaults.standard.set(true, forKey: didShowWelcomeDocumentKey)
    }

    private static func cleanupWindowStores() {
        windowStores = windowStores.filter { _, ref in
            guard let window = ref.window, ref.store != nil else { return false }
            return window.isVisible
        }
    }

    private static func cleanupLiveStores() {
        liveStores = liveStores.filter { _, ref in
            ref.store != nil
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
                SessionState.cachedOpenWindow = openWindow
                // If a StrataDocument was queued for this window, adopt its store.
                if let pendingDoc = StrataDocumentController.dequeuePendingDocument() {
                    if Self.isFirstWindow {
                        Self.isFirstWindow = false
                    }
                    adoptDocument(pendingDoc)
                } else if Self.isFirstWindow {
                    Self.isFirstWindow = false
                    restoreSession()
                } else if let copy = SessionState.pendingUntitledCopies.first {
                    SessionState.pendingUntitledCopies.removeFirst()
                    store.loadUntitledCopy(root: copy.root, displayName: copy.displayName)
                    wrapStoreInDocument()
                    store.document?.displayName = (copy.displayName as NSString).deletingPathExtension
                } else if let item = SessionState.pendingRestoreItems.first {
                    // This window was created during session restoration
                    SessionState.pendingRestoreItems.removeFirst()
                    if item.isDraft {
                        loadDraft(from: item.url)
                    } else {
                        store.loadFile(from: item.url)
                        wrapStoreInDocument(url: item.url)
                    }
                } else if let url = SessionState.pendingRestoreURLs.first {
                    // Legacy restore path
                    SessionState.pendingRestoreURLs.removeFirst()
                    store.loadFile(from: url)
                    wrapStoreInDocument(url: url)
                } else if let url = SessionState.pendingRestoreDrafts.first {
                    SessionState.pendingRestoreDrafts.removeFirst()
                    loadDraft(from: url)
                } else if let url = SessionState.pendingWorkflowyImportURLs.first {
                    SessionState.pendingWorkflowyImportURLs.removeFirst()
                    store.loadWorkflowyOPMLImport(from: url)
                    wrapStoreInDocument()
                } else {
                    // Untitled new tab — wrap in a StrataDocument
                    wrapStoreInDocument()
                }
                SessionState.register(store: store)
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

    /// Load a draft file as an untitled document, then clean up the draft.
    private func loadDraft(from draftURL: URL) {
        guard let data = try? Data(contentsOf: draftURL),
              let root = try? OPMLService.parse(data: data) else {
            wrapStoreInDocument()
            return
        }
        store.root = root
        store.ensureEditableRoot()
        store.resetViewState()
        wrapStoreInDocument()
        // Mark as dirty so the user is prompted to save
        store.document?.updateChangeCount(.changeDone)
        // Remove the draft file now that content is loaded
        SessionState.cleanupDraft(at: draftURL)
    }

    /// Restore previously open documents: load saved session state, open additional
    /// tabs for each document beyond the first. Preserves window/tab grouping.
    private func restoreSession() {
        let queuedURLs = SessionState.consumePendingOpenURLs()
        if !queuedURLs.isEmpty {
            openURLs(queuedURLs, preferCurrentWindow: true)
            return
        }

        let windowGroups = SessionState.loadSavedWindowGroups()

        if !windowGroups.isEmpty {
            let firstGroup = windowGroups[0]
            let firstEntry = firstGroup[0]

            // Load the first entry of the first group into this window
            if firstEntry.isDraft {
                loadDraft(from: firstEntry.url)
            } else {
                store.loadFile(from: firstEntry.url)
                wrapStoreInDocument(url: firstEntry.url)
            }

            // Queue remaining tabs in the first group
            let remainingTabs = Array(firstGroup.dropFirst())
            for entry in remainingTabs {
                SessionState.pendingRestoreItems.append(
                    SessionState.PendingRestoreItem(url: entry.url, isDraft: entry.isDraft, isNewWindow: false)
                )
                WindowTabCoordinator.requestNextWindowAsTab()
                openWindow(id: "main")
            }

            // Queue subsequent groups as separate windows.
            // Due to the async nature of window creation, we cannot reliably
            // re-create tab groups beyond the first one during a single restore pass.
            // Each entry opens as its own window; the user can re-tab them if desired.
            for groupIndex in 1..<windowGroups.count {
                let group = windowGroups[groupIndex]
                for entry in group {
                    SessionState.pendingRestoreItems.append(
                        SessionState.PendingRestoreItem(url: entry.url, isDraft: entry.isDraft, isNewWindow: true)
                    )
                    openWindow(id: "main")
                }
            }

            // Clean up any remaining draft files not referenced
            SessionState.cleanupAllDrafts()
            return
        }

        if SessionState.shouldShowWelcomeDocument, store.loadBundledWelcomeDocument() {
            SessionState.markWelcomeDocumentShown()
            wrapStoreInDocument()
            store.document?.updateChangeCount(.changeCleared)
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
        // Window creation is explicit: AppWindowBootstrap opens the first
        // DocumentWindowView, which then consumes queued file/session state.
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            let doc = StrataDocument()
            NSDocumentController.shared.addDocument(doc)
            StrataDocumentController.enqueuePendingDocument(doc)
            if let cached = SessionState.cachedOpenWindow {
                cached(id: "main")
            } else {
                AppWindowBootstrap.openWindow()
            }
        }
        return true
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

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            AppWindowBootstrap.openWindowIfNeeded()
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Save while document windows are still visible. Waiting for
        // applicationWillTerminate can be too late after AppKit starts teardown.
        SessionState.saveOpenDocuments()
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        isTerminating = true
    }

    func application(_ application: NSApplication, shouldSaveSecureApplicationState coder: NSCoder) -> Bool {
        false
    }

    func application(_ application: NSApplication, shouldRestoreSecureApplicationState coder: NSCoder) -> Bool {
        false
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        SessionState.queueOpenURLs(urls)
        AppWindowBootstrap.openWindowIfNeeded()
    }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        SessionState.queueOpenURLs([URL(fileURLWithPath: filename)])
        AppWindowBootstrap.openWindowIfNeeded()
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
                    if let textView = activeFieldEditor() {
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
                    if let textView = activeFieldEditor() {
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
                Button("New") {
                    openNewWindow()
                }
                .keyboardShortcut("n")

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

                Button("Revert to Saved") {
                    if let doc = activeStore?.document, let url = doc.fileURL {
                        try? doc.revert(toContentsOf: url, ofType: doc.fileType ?? "org.opml.opml")
                    }
                }
                .disabled(activeStore?.document?.fileURL == nil)

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
                    if let editor = activeFieldEditor() as? AppKitOutlineEditorTextView {
                        editor.wrapBold()
                    } else {
                        StrataTextField.currentEditingField?.wrapBold()
                    }
                }
                .keyboardShortcut("b", modifiers: .command)

                Button("Italic") {
                    if let editor = activeFieldEditor() as? AppKitOutlineEditorTextView {
                        editor.wrapItalic()
                    } else {
                        StrataTextField.currentEditingField?.wrapItalic()
                    }
                }
                .keyboardShortcut("i", modifiers: .command)

                Button("Underline") {
                    if let editor = activeFieldEditor() as? AppKitOutlineEditorTextView {
                        editor.wrapUnderline()
                    } else {
                        StrataTextField.currentEditingField?.wrapUnderline()
                    }
                }
                .keyboardShortcut("u", modifiers: .command)

                Button("Highlight") {
                    if let editor = activeFieldEditor() as? AppKitOutlineEditorTextView {
                        editor.wrapHighlight()
                    } else {
                        StrataTextField.currentEditingField?.wrapHighlight()
                    }
                }
                .keyboardShortcut("l", modifiers: .command)

                Divider()

                Button("Link...") {
                    if let editor = activeFieldEditor() as? AppKitOutlineEditorTextView {
                        editor.editLink()
                    } else {
                        StrataTextField.currentEditingField?.editLink()
                    }
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

                Button("Show Next Tab") {
                    cycleTab(forward: true)
                }
                .keyboardShortcut(KeyEquivalent("\t"), modifiers: .control)

                Button("Show Previous Tab") {
                    cycleTab(forward: false)
                }
                .keyboardShortcut(KeyEquivalent("\t"), modifiers: [.control, .shift])

                Divider()

                ForEach(1...9, id: \.self) { num in
                    Button("Select Tab \(num)") {
                        if num == 9 {
                            if let windows = NSApp.keyWindow?.tabGroup?.windows, !windows.isEmpty {
                                windows.last?.makeKeyAndOrderFront(nil)
                            }
                        } else {
                            selectTab(at: num - 1)
                        }
                    }
                    .keyboardShortcut(KeyEquivalent(Character(String(num))), modifiers: .command)
                }
            }

            // MARK: Outline

            CommandMenu("Outline") {
                Button("Move Node Up") {
                    if let editor = activeFieldEditor() as? AppKitOutlineEditorTextView {
                        editor.moveCurrentNodeUp()
                    } else if let field = StrataTextField.currentEditingField {
                        if field.onCmdShiftUp?() == true {
                            field.markStructuralEditForUndo()
                        }
                    } else {
                        activeStore?.moveSelectedUp()
                    }
                }
                .keyboardShortcut(.upArrow, modifiers: .command)

                Button("Move Node Down") {
                    if let editor = activeFieldEditor() as? AppKitOutlineEditorTextView {
                        editor.moveCurrentNodeDown()
                    } else if let field = StrataTextField.currentEditingField {
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
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false

        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        for url in panel.urls {
            openURLAsTab(url)
        }
    }

    private func importWorkflowyOPMLAsTab() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [OutlineStore.opmlContentType]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        guard panel.runModal() == .OK, let url = panel.url else { return }
        openWorkflowyImportURLAsTab(url)
    }

    private func openNewWindow() {
        let doc = StrataDocument()
        NSDocumentController.shared.addDocument(doc)
        StrataDocumentController.enqueuePendingDocument(doc)
        if let openWindow = openWindowAction {
            openWindow(id: "main")
        } else if let cached = SessionState.cachedOpenWindow {
            cached(id: "main")
        } else {
            AppWindowBootstrap.openWindow()
        }
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
              let textView = window.firstResponder as? NSTextView else { return nil }
        guard textView.isFieldEditor
                || textView is AppKitOutlineEditorTextView
                || textView is AppKitOutlineNoteTextView else { return nil }
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
            if let editor = textView as? AppKitOutlineEditorTextView {
                if editor.pasteOutlineNodesFromPasteboard() {
                    return
                } else if let text = pasteboard.string(forType: .string) {
                    textView.insertText(text, replacementRange: textView.selectedRange)
                }
            } else if textView is AppKitOutlineNoteTextView {
                if let text = pasteboard.string(forType: .string) {
                    textView.insertText(text, replacementRange: textView.selectedRange)
                }
            } else if pasteboard.data(forType: OutlineStore.nodePasteboardType) != nil {
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
        let dateString = StrataTextField.localizedCurrentDateString()
        if let editor = activeFieldEditor() as? AppKitOutlineEditorTextView {
            editor.insertDateString(dateString)
        } else if let textView = activeFieldEditor() as? AppKitOutlineNoteTextView {
            textView.insertText(dateString, replacementRange: textView.selectedRange)
        } else {
            StrataTextField.currentEditingField?.insertDateString(dateString)
        }
    }

    private func performSelectAll() {
        if let textView = activeFieldEditor() {
            let fullRange = NSRange(location: 0, length: (textView.string as NSString).length)
            if textView.selectedRange == fullRange {
                if let editor = textView as? AppKitOutlineEditorTextView {
                    editor.selectAllVisibleNodes()
                } else {
                    StrataTextField.currentEditingField?.onSelectAllNodes?()
                }
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
    }

    /// Load a URL — reuse the current window if untitled, otherwise open a new tab.
    private func openURLAsTab(_ url: URL) {
        let fileURL = url.standardizedFileURL
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            let alert = NSAlert()
            alert.messageText = "The document \"\(fileURL.lastPathComponent)\" could not be opened."
            alert.informativeText = "The file cannot be found."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
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
            AppWindowBootstrap.openWindowIfNeeded()
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
            SessionState.pendingWorkflowyImportURLs.append(fileURL)
            AppWindowBootstrap.openWindowIfNeeded()
        }
    }

    private func selectTab(at index: Int) {
        guard let windows = NSApp.keyWindow?.tabGroup?.windows,
              windows.indices.contains(index) else { return }
        windows[index].makeKeyAndOrderFront(nil)
    }

    private func cycleTab(forward: Bool) {
        guard let windows = NSApp.keyWindow?.tabGroup?.windows,
              let current = NSApp.keyWindow,
              let index = windows.firstIndex(of: current) else { return }
        let next = forward
            ? windows[(index + 1) % windows.count]
            : windows[(index - 1 + windows.count) % windows.count]
        next.makeKeyAndOrderFront(nil)
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
