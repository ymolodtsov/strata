import AppKit

/// Custom NSDocumentController that creates StrataDocument instances and bridges
/// them to the SwiftUI WindowGroup via a pending-document queue.
///
/// Registered early in `AppDelegate.applicationWillFinishLaunching` so it becomes
/// the shared document controller before AppKit's default is installed.
class StrataDocumentController: NSDocumentController {

    /// Documents waiting to be picked up by newly created DocumentWindowView instances.
    /// The flow is:
    ///   1. A StrataDocument is created (via makeUntitledDocument / makeDocument)
    ///   2. It is pushed onto this queue
    ///   3. `openWindow(id: "main")` is called
    ///   4. DocumentWindowView.onAppear pops the document and uses its store
    static var pendingDocuments: [StrataDocument] = []

    // MARK: - Factory overrides

    override func makeUntitledDocument(ofType typeName: String) throws -> NSDocument {
        let doc = StrataDocument()
        return doc
    }

    override func makeDocument(withContentsOf url: URL, ofType typeName: String) throws -> NSDocument {
        let doc = StrataDocument()
        try doc.read(from: url, ofType: typeName)
        doc.fileURL = url
        doc.fileType = typeName
        return doc
    }

    // MARK: - Tab-aware document opening

    /// Opens a document from a URL and presents it as a tab in the current window.
    /// If the document is already open, brings its window to front instead.
    func openDocumentAsTab(at url: URL, using openWindow: @escaping (String) -> Void) {
        let fileURL = url.standardizedFileURL

        // Check if this document is already open
        if let existingDoc = documents.first(where: { $0.fileURL?.standardizedFileURL == fileURL }) as? StrataDocument {
            existingDoc.showWindows()
            return
        }

        do {
            let doc = try makeDocument(withContentsOf: fileURL, ofType: "org.opml.opml") as! StrataDocument
            addDocument(doc)
            noteNewRecentDocumentURL(fileURL)
            Self.pendingDocuments.append(doc)
            WindowTabCoordinator.requestNextWindowAsTab()
            openWindow("main")
        } catch {
            NSSound.beep()
        }
    }

    /// Creates an untitled document and opens it as a tab in the current window.
    func openUntitledDocumentAsTab(using openWindow: @escaping (String) -> Void) {
        do {
            let doc = try makeUntitledDocument(ofType: "org.opml.opml") as! StrataDocument
            addDocument(doc)
            Self.pendingDocuments.append(doc)
            WindowTabCoordinator.requestNextWindowAsTab()
            openWindow("main")
        } catch {
            NSSound.beep()
        }
    }
}
