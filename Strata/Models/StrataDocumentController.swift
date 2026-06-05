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
}
