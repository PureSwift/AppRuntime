import DynamicRuntime

/// The outcome of one `Documents` operation. The host calls exactly one of
/// these, once, on the main thread.
@DynamicCallback("org.pureswift.documents.Callback")
public protocol DocumentCallback: AnyObject {

    /// What the user picked; nothing if the user cancelled.
    func didPick(_ documents: [DocumentGrant])

    /// An export that saved, and left the app no document.
    func didComplete()

    func didBookmark(_ bookmark: String)

    /// `error` is a `DocumentError` raw value.
    func didFail(_ error: Int32)
}

/// Documents the app was opened with, from the file manager or another app.
/// Called on the main thread.
@DynamicCallback("org.pureswift.documents.Delegate")
public protocol DocumentsDelegate: AnyObject {

    func didOpen(_ documents: [DocumentGrant])
}
