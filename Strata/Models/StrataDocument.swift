import AppKit
import UniformTypeIdentifiers

class StrataDocument: NSDocument {

    let store: OutlineStore
    private var isCreatingWindowBridge = false

    override init() {
        self.store = OutlineStore()
        super.init()
        store.document = self
    }

    init(store: OutlineStore) {
        self.store = store
        super.init()
        store.document = self
    }

    // MARK: - NSDocument configuration

    override class var autosavesInPlace: Bool { true }

    override var autosavingFileType: String? { "org.opml.opml" }

    // Prevent NSDocument from installing its own UndoManager — OutlineStore uses snapshot-based undo.
    override var undoManager: UndoManager? {
        get { nil }
        set {}
    }

    override func makeWindowControllers() {
        guard windowControllers.isEmpty, !isCreatingWindowBridge else { return }
        isCreatingWindowBridge = true
        AppWindowBootstrap.closeUntitledBootstrapWindows()
        SessionState.closeEmptyUntitledWindows()
        StrataDocumentController.enqueuePendingDocument(self)
        AppWindowBootstrap.openWindow()
    }

    func markWindowBridgeInstalled() {
        isCreatingWindowBridge = false
    }

    override func writableTypes(for saveOperation: NSDocument.SaveOperationType) -> [String] {
        ["org.opml.opml"]
    }

    // MARK: - Reading

    override func read(from url: URL, ofType typeName: String) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw CocoaError(.fileReadNoSuchFile, userInfo: [NSURLErrorKey: url])
        }

        let data = try Data(contentsOf: url)
        let ext = url.pathExtension.lowercased()

        if ext == "opml" {
            store.root = try OPMLService.parse(data: data)
        } else {
            guard let text = String(data: data, encoding: .utf8)
                    ?? String(data: data, encoding: .utf16) else {
                throw CocoaError(.fileReadCorruptFile, userInfo: [NSURLErrorKey: url])
            }
            let isMarkdown = ext == "md" || ext == "markdown"
            let title = url.deletingPathExtension().lastPathComponent
            store.root = OutlineStore.parseOutlineText(text, title: title, markdown: isMarkdown)
        }

        store.ensureEditableRoot()
        store.resetViewState()
    }

    // MARK: - Writing

    // Snapshot captured on the main thread before data(ofType:) runs on a background queue during auto-save.
    private var pendingSnapshot: OutlineNode?

    override func save(
        to url: URL,
        ofType typeName: String,
        for saveOperation: NSDocument.SaveOperationType,
        completionHandler: @escaping (Error?) -> Void
    ) {
        assert(Thread.isMainThread)
        pendingSnapshot = store.root.snapshot()
        super.save(to: url, ofType: typeName, for: saveOperation) { [weak self] error in
            self?.pendingSnapshot = nil
            completionHandler(error)
        }
    }

    override func data(ofType typeName: String) throws -> Data {
        OPMLService.serialize(root: pendingSnapshot ?? store.root)
    }

    // MARK: - External File Change Detection

    override func presentedItemDidChange() {
        DispatchQueue.main.async { [weak self] in
            guard let self, let url = self.fileURL else { return }
            // Only auto-reload if the user has no unsaved edits
            if !self.isDocumentEdited {
                try? self.revert(toContentsOf: url, ofType: self.fileType ?? "org.opml.opml")
            }
        }
    }
}

// MARK: - Thin Window Controller Bridge

/// Minimal NSWindowController that does NOT create its own window.
/// It gets assigned the window that WindowGroup already created, giving
/// NSDocument the window reference it needs for title-bar proxy icon and
/// native rename/move/tags popover.
class StrataWindowController: NSWindowController {

    /// Prevent NSWindowController from loading a nib or creating a window on its own.
    override var windowNibName: NSNib.Name? { nil }
}
