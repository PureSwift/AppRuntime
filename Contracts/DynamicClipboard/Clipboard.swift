import DynamicRuntime

/// The system's clipboard, for an app's own Copy and Paste
/// (`Documentation/Contracts/Clipboard.md`). App code uses `Pasteboard`,
/// which wraps this contract.
///
/// Every operation completes through its `callback`, which the host holds
/// until it has called exactly one of its methods, on the main thread. A
/// read may wait for the user: iOS asks before one, and a browser may.
/// A refusal, the platform's or the user's, is `notAllowed`.
///
/// It needs no capability: no platform has a permission to declare for
/// the clipboard, and each guards a read when it happens.
///
/// | Host | Implementation |
/// |---|---|
/// | iOS | `UIPasteboard.general` |
/// | macOS | `NSPasteboard.general` |
/// | Android | `ClipboardManager` |
/// | Linux | the compositor's selection |
/// | Browser | `navigator.clipboard` |
@DynamicRuntime("org.pureswift.clipboard.Clipboard")
public protocol Clipboard: AnyObject {

    static func shared() -> Self

    /// What a read might give: bits of `ClipboardKinds`. It never asks or
    /// tells the user, and never reads the contents. A host that can't
    /// tell without asking says all of them.
    func available() -> Int32

    // MARK: Writing

    // Each write replaces everything that was there. `options` are bits
    // of `PasteboardOptions`. Answered by `didComplete` or `didFail`.

    func clear(_ callback: ClipboardCallback)

    /// Text. With `url`, a URL whose text this is: written as the
    /// platform's URL kind where it has one, and as text always. An empty
    /// `url` is none.
    func writeText(_ text: String, url: String, options: Int32, callback: ClipboardCallback)

    /// An image file's bytes: PNG or JPEG, told by the bytes themselves.
    func writeImage(_ data: [UInt8], mimeType: String, options: Int32, callback: ClipboardCallback)

    /// An image file, as `Files` names it: a `FileDirectory` raw value and
    /// a path.
    func writeImageFile(_ directory: Int32, path: String, options: Int32, callback: ClipboardCallback)

    // MARK: Reading

    /// Answered by `didReadText`: the text, or a URL's when a URL is all
    /// there is.
    func readText(_ callback: ClipboardCallback)

    /// Answered by `didReadText`: a URL, when the clipboard says it has
    /// one. Text that happens to be a URL isn't.
    func readURL(_ callback: ClipboardCallback)

    /// Answered by `didReadImage`: PNG or JPEG, whatever it was.
    func readImage(_ callback: ClipboardCallback)

    /// Writes the image to a file, replacing it. Answered by
    /// `didWriteImageFile`.
    func readImageToFile(_ directory: Int32, path: String, callback: ClipboardCallback)
}

/// One operation's answer, from the host. Called once, on the main thread.
@DynamicCallback("org.pureswift.clipboard.Callback")
public protocol ClipboardCallback: AnyObject {

    func didComplete()

    /// Text, or a URL. `nil` when there's none.
    func didReadText(_ text: String?)

    /// `image/png` or `image/jpeg`. An empty type: there's no image.
    func didReadImage(_ data: [UInt8], mimeType: String)

    /// The type of the file written. Empty: there's no image, and no file
    /// was written.
    func didWriteImageFile(_ mimeType: String)

    /// A `PasteboardError` raw value.
    func didFail(_ error: Int32)
}
