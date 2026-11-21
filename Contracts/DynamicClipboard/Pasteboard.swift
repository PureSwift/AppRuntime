import DynamicFiles
import DynamicRuntime
#if hasFeature(Embedded) && !EMBEDDED_NO_CONCURRENCY
// Embedded Swift doesn't import the concurrency module implicitly.
import _Concurrency
#endif

/// The system's clipboard: `UIPasteboard`'s place, for a guest's own Copy
/// and Paste buttons.
///
/// ```swift
/// let pasteboard = Pasteboard.general
/// pasteboard.setString("42")
/// if pasteboard.hasStrings, let text = try await pasteboard.string() { … }
/// ```
///
/// Copying returns at once, and drops a failure unless it's given a
/// completion handler or awaited. Pasting is asynchronous and may be
/// refused: the platform may ask the user first, or tell them, and a
/// browser allows either only while a tap or a key is being handled. So
/// call both from a user's action. `hasStrings`, `hasURLs` and `hasImages`
/// look without reading, and never ask.
///
/// Text views copy and paste by themselves; this isn't needed for them.
/// It's guest-side only, over the `Clipboard` contract. The guest is
/// single-threaded (§6.4).
public final class Pasteboard: @unchecked Sendable {

    /// The system's clipboard.
    public static let general = Pasteboard()

    /// The host's clipboard, made when first used.
    private var made: (any Clipboard)?

    init() { }

    private var clipboard: any Clipboard {
        if let made {
            return made
        }
        let clipboard = ClipboardProxy.shared()
        made = clipboard
        return clipboard
    }

    // MARK: Looking

    /// What a paste might give. It never asks or tells the user, and never
    /// sees the contents. A host that can't tell without asking, as a
    /// browser can't, says all of them.
    public var available: ClipboardKinds {
        ClipboardKinds(rawValue: clipboard.available()).intersection(.all)
    }

    /// Whether `string()` might give text. Not observable: read it when
    /// the view updates.
    public var hasStrings: Bool {
        !available.isDisjoint(with: [.text, .url])
    }

    public var hasURLs: Bool {
        available.contains(.url)
    }

    public var hasImages: Bool {
        available.contains(.image)
    }

    // MARK: Copying

    // Each replaces everything that was there. With no completion handler
    // a failure is dropped.

    public func setString(_ string: String, options: PasteboardOptions = [], completion: ((Result<Void, PasteboardError>) -> Void)? = nil) {
        clipboard.writeText(string, url: "", options: options.rawValue, callback: Receiver.completing(completion))
    }

    /// A URL: as a URL where the platform has the kind, and as text
    /// everywhere. `title` is the text, when it isn't the URL itself.
    public func setURL(_ url: String, title: String? = nil, options: PasteboardOptions = [], completion: ((Result<Void, PasteboardError>) -> Void)? = nil) {
        clipboard.writeText(title ?? url, url: url, options: options.rawValue, callback: Receiver.completing(completion))
    }

    /// An image file's bytes: PNG or JPEG.
    public func setImage(_ data: [UInt8], type: PasteboardImageType, options: PasteboardOptions = [], completion: ((Result<Void, PasteboardError>) -> Void)? = nil) {
        clipboard.writeImage(data, mimeType: type.mimeType, options: options.rawValue, callback: Receiver.completing(completion))
    }

    /// An image file: in the bundle, the app's files, or a document. The
    /// host reads it; its bytes don't pass through the app.
    public func setImage(contentsOf path: FilePath, options: PasteboardOptions = [], completion: ((Result<Void, PasteboardError>) -> Void)? = nil) {
        clipboard.writeImageFile(path.directory.rawValue, path: path.path, options: options.rawValue, callback: Receiver.completing(completion))
    }

    /// Empties the clipboard.
    public func clear(completion: ((Result<Void, PasteboardError>) -> Void)? = nil) {
        clipboard.clear(Receiver.completing(completion))
    }

    // MARK: Pasting

    // `nil` means there isn't one, which isn't an error.

    /// The text, or a URL's when a URL is all there is.
    public func string(completion: @escaping (Result<String?, PasteboardError>) -> Void) {
        clipboard.readText(Receiver.reading(completion))
    }

    /// A URL, when the clipboard says it has one. Text that happens to be
    /// a URL is text: read `string`. A browser has no such kind.
    public func url(completion: @escaping (Result<String?, PasteboardError>) -> Void) {
        clipboard.readURL(Receiver.reading(completion))
    }

    /// An image, as PNG or JPEG whatever it was. For a small one; a photo
    /// is better pasted into a file.
    public func image(completion: @escaping (Result<PasteboardImage?, PasteboardError>) -> Void) {
        clipboard.readImage(Receiver { outcome in
            if case .image(let image) = outcome {
                completion(.success(image))
            } else {
                completion(.failure(outcome.error))
            }
        })
    }

    /// Writes the image to a file, replacing it, and says which kind it
    /// wrote. Its bytes don't pass through the app.
    public func image(to path: FilePath, completion: @escaping (Result<PasteboardImageType?, PasteboardError>) -> Void) {
        clipboard.readImageToFile(path.directory.rawValue, path: path.path, callback: Receiver { outcome in
            if case .file(let type) = outcome {
                completion(.success(type))
            } else {
                completion(.failure(outcome.error))
            }
        })
    }

    // MARK: Async

    // Each runs where it's called from, as the guest's one thread wants
    // (§6.4).

    #if !EMBEDDED_NO_CONCURRENCY
    public nonisolated(nonsending) func setString(_ string: String, options: PasteboardOptions = []) async throws(PasteboardError) {
        try await wait { self.setString(string, options: options, completion: $0) }
    }

    public nonisolated(nonsending) func setURL(_ url: String, title: String? = nil, options: PasteboardOptions = []) async throws(PasteboardError) {
        try await wait { self.setURL(url, title: title, options: options, completion: $0) }
    }

    public nonisolated(nonsending) func setImage(_ data: [UInt8], type: PasteboardImageType, options: PasteboardOptions = []) async throws(PasteboardError) {
        try await wait { self.setImage(data, type: type, options: options, completion: $0) }
    }

    public nonisolated(nonsending) func setImage(contentsOf path: FilePath, options: PasteboardOptions = []) async throws(PasteboardError) {
        try await wait { self.setImage(contentsOf: path, options: options, completion: $0) }
    }

    public nonisolated(nonsending) func clear() async throws(PasteboardError) {
        try await wait { self.clear(completion: $0) }
    }

    public nonisolated(nonsending) func string() async throws(PasteboardError) -> String? {
        try await wait { self.string(completion: $0) }
    }

    public nonisolated(nonsending) func url() async throws(PasteboardError) -> String? {
        try await wait { self.url(completion: $0) }
    }

    public nonisolated(nonsending) func image() async throws(PasteboardError) -> PasteboardImage? {
        try await wait { self.image(completion: $0) }
    }

    public nonisolated(nonsending) func image(to path: FilePath) async throws(PasteboardError) -> PasteboardImageType? {
        try await wait { self.image(to: path, completion: $0) }
    }

    /// Waits for a completion handler. A cancelled task stops waiting with
    /// `cancelled`; the operation itself isn't undone.
    private nonisolated(nonsending) func wait<Value>(_ start: (@escaping (Result<Value, PasteboardError>) -> Void) -> Void) async throws(PasteboardError) -> Value {
        try await withCallback { (callback: Callback<Value, PasteboardError>) in
            start { callback.resume(with: $0) }
        } onCancel: { callback in
            callback.resume(throwing: .cancelled)
        }
    }
    #endif
}

/// What a `ClipboardCallback` was told.
private enum Outcome {

    case complete
    case text(String?)
    case image(PasteboardImage?)
    case file(PasteboardImageType?)
    case failure(PasteboardError)

    /// The failure, or `unknown` for an answer of the wrong kind.
    var error: PasteboardError {
        if case .failure(let error) = self {
            return error
        }
        return .unknown
    }
}

/// One operation's callback. The host holds it until it answers.
private final class Receiver: ClipboardCallback {

    private var finish: ((Outcome) -> Void)?

    init(_ finish: @escaping (Outcome) -> Void) {
        self.finish = finish
    }

    /// For the operations that answer `didComplete`. With no completion
    /// handler the answer is dropped.
    static func completing(_ completion: ((Result<Void, PasteboardError>) -> Void)?) -> Receiver {
        Receiver { outcome in
            guard let completion else { return }
            if case .complete = outcome {
                completion(.success(()))
            } else {
                completion(.failure(outcome.error))
            }
        }
    }

    /// For the reads that answer `didReadText`.
    static func reading(_ completion: @escaping (Result<String?, PasteboardError>) -> Void) -> Receiver {
        Receiver { outcome in
            if case .text(let text) = outcome {
                completion(.success(text))
            } else {
                completion(.failure(outcome.error))
            }
        }
    }

    /// Only a host's first answer counts.
    private func answer(_ outcome: Outcome) {
        guard let finish else { return }
        self.finish = nil
        finish(outcome)
    }

    func didComplete() {
        answer(.complete)
    }

    func didReadText(_ text: String?) {
        answer(.text(text))
    }

    func didReadImage(_ data: [UInt8], mimeType: String) {
        guard !mimeType.isEmpty else {
            answer(.image(nil))
            return
        }
        // A type from a newer host isn't one the app was promised.
        guard let type = PasteboardImageType(rawValue: mimeType) else {
            answer(.failure(.unsupported))
            return
        }
        answer(.image(PasteboardImage(data: data, type: type)))
    }

    func didWriteImageFile(_ mimeType: String) {
        guard !mimeType.isEmpty else {
            answer(.file(nil))
            return
        }
        guard let type = PasteboardImageType(rawValue: mimeType) else {
            answer(.failure(.unsupported))
            return
        }
        answer(.file(type))
    }

    func didFail(_ error: Int32) {
        answer(.failure(PasteboardError(rawValue: error) ?? .unknown))
    }
}
