import Dispatch
import DynamicClipboard
import DynamicFiles
import DynamicRuntime
import RuntimeABI
import RuntimeCore
import RuntimeHost

/// What a clipboard holds, as a platform is given it and gives it.
public enum HostClipboardContent: Equatable, Sendable {

    /// Text. With `url`, a URL whose text this is.
    case text(String, url: String?)

    /// An image file's bytes: PNG or JPEG.
    case image([UInt8], type: PasteboardImageType)
}

/// What a read asks a platform for.
public enum ClipboardKind: Sendable {
    case text
    case url
    case image
}

/// The platform's clipboard: `UIPasteboard`, `NSPasteboard`, the
/// compositor's selection. Everything is called on the main thread, and
/// each completion is called there, once, at once or after the platform
/// has asked the user.
public protocol ClipboardPlatform: AnyObject {

    /// What a read might give, from what the platform says is there. It
    /// must not ask or tell the user, or read the contents. A platform
    /// that can't tell says `.all`.
    func available() -> ClipboardKinds

    func clear()

    /// Replaces everything. A URL is written as the platform's URL kind
    /// where it has one, and as text always. `isSensitive` is honoured
    /// where the platform can, and never fails the write.
    func write(_ content: HostClipboardContent, isSensitive: Bool, completion: @escaping (PasteboardError?) -> Void)

    /// What's there of a kind, or `nil`:
    /// - `text`: `.text`, with the text; a URL's text when a URL is all
    ///   there is.
    /// - `url`: `.text` with its `url`, when the platform says it has one.
    /// - `image`: `.image`, converted to PNG unless it's PNG or JPEG.
    func read(_ kind: ClipboardKind, completion: @escaping (Result<HostClipboardContent?, PasteboardError>) -> Void)
}

/// A clipboard of the app's own, in memory. It's what `HostClipboard`
/// uses on a host with no `ClipboardPlatform`: copy and paste then work
/// inside the app, and reach no other.
///
/// Main thread only.
public final class MemoryClipboard: ClipboardPlatform {

    public var content: HostClipboardContent?

    /// Whether what's there was copied as sensitive.
    public private(set) var isSensitive = false

    public init() { }

    public func available() -> ClipboardKinds {
        switch content {
        case nil: return []
        case .text(_, let url): return url == nil ? .text : [.text, .url]
        case .image: return .image
        }
    }

    public func clear() {
        content = nil
        isSensitive = false
    }

    public func write(_ content: HostClipboardContent, isSensitive: Bool, completion: @escaping (PasteboardError?) -> Void) {
        self.content = content
        self.isSensitive = isSensitive
        completion(nil)
    }

    public func read(_ kind: ClipboardKind, completion: @escaping (Result<HostClipboardContent?, PasteboardError>) -> Void) {
        switch (kind, content) {
        case (.text, .text), (.image, .image):
            completion(.success(content))
        case (.url, .text(_, let url)) where url != nil:
            completion(.success(content))
        default:
            completion(.success(nil))
        }
    }
}

/// The `Clipboard` contract over a host's `ClipboardPlatform`: what every
/// host written in Swift shares.
///
/// It tells a PNG from a JPEG and refuses anything else, finds image files
/// through `HostFiles` and reads and writes them off the main thread,
/// refuses what's too large, and answers each callback once, on the main
/// thread.
///
/// ```swift
/// HostClipboard.platform = MyPasteboard()
/// HostClipboardModule.register(in: runtime)
/// ```
///
/// Without a platform, the clipboard is the app's own, in memory
/// (`MemoryClipboard`). Main thread only.
public final class HostClipboard: Clipboard {

    // MARK: The host's settings

    /// The platform's clipboard.
    nonisolated(unsafe) public static var platform: (any ClipboardPlatform)?

    /// The clipboard used when there's no platform.
    nonisolated(unsafe) public private(set) static var memory = MemoryClipboard()

    /// The most bytes one copy or paste passes: text, or an image.
    nonisolated(unsafe) public static var maximumSize = defaultMaximumSize

    /// `Files`' own default.
    public static let defaultMaximumSize = 256 << 20

    /// Runs file work off the main thread. The default is a serial queue.
    nonisolated(unsafe) public static var work: @Sendable (@escaping @Sendable () -> Void) -> Void = defaultWork

    /// Runs an answer on the main thread. The default is the main dispatch
    /// queue; a host with a loop of its own posts to that.
    nonisolated(unsafe) public static var deliver: @Sendable (@escaping @Sendable () -> Void) -> Void = defaultDeliver

    private static let queue = DispatchQueue(label: "org.pureswift.runtime.clipboard")

    private static let defaultWork: @Sendable (@escaping @Sendable () -> Void) -> Void = { queue.async(execute: $0) }

    private static let defaultDeliver: @Sendable (@escaping @Sendable () -> Void) -> Void = { DispatchQueue.main.async(execute: $0) }

    /// The one clipboard. Never replaced: a guest keeps the object it
    /// first asked for.
    nonisolated(unsafe) private static let instance = HostClipboard()

    public static func shared() -> HostClipboard {
        instance
    }

    /// Forgets the platform and the settings, and empties the app's own
    /// clipboard: for tests, and for a host that starts the guest again.
    public static func reset() {
        platform = nil
        memory = MemoryClipboard()
        maximumSize = defaultMaximumSize
        work = defaultWork
        deliver = defaultDeliver
    }

    private static var current: any ClipboardPlatform {
        platform ?? memory
    }

    // MARK: Answers

    /// Calls `answer` with the callback, on the main thread and later.
    private static func later(_ callback: any ClipboardCallback, _ answer: @escaping (any ClipboardCallback) -> Void) {
        let held = MainThreadHeld((callback, answer))
        deliver {
            guard let (callback, answer) = held.take() else { return }
            answer(callback)
        }
    }

    private static func fail(_ callback: any ClipboardCallback, _ error: PasteboardError) {
        later(callback) { $0.didFail(error.rawValue) }
    }

    /// A completion that answers the callback, the first time it's
    /// called: a platform that calls twice is heard once.
    private static func once<Value>(_ callback: any ClipboardCallback, _ answer: @escaping (any ClipboardCallback, Value) -> Void) -> (Value) -> Void {
        var waiting: (any ClipboardCallback)? = callback
        return { value in
            guard let callback = waiting else { return }
            waiting = nil
            later(callback) { answer($0, value) }
        }
    }

    // MARK: Looking

    public func available() -> Int32 {
        Self.current.available().intersection(.all).rawValue
    }

    // MARK: Writing

    private func write(_ content: HostClipboardContent, options: Int32, callback: any ClipboardCallback) {
        let isSensitive = PasteboardOptions(rawValue: options).contains(.sensitive)
        Self.current.write(content, isSensitive: isSensitive, completion: Self.once(callback) { (callback, error: PasteboardError?) in
            if let error {
                callback.didFail(error.rawValue)
            } else {
                callback.didComplete()
            }
        })
    }

    public func clear(_ callback: any ClipboardCallback) {
        Self.current.clear()
        Self.later(callback) { $0.didComplete() }
    }

    public func writeText(_ text: String, url: String, options: Int32, callback: any ClipboardCallback) {
        guard text.utf8.count <= Self.maximumSize, url.utf8.count <= Self.maximumSize else {
            Self.fail(callback, .tooLarge)
            return
        }
        // A URL with no text of its own is its own text.
        let content = HostClipboardContent.text(text.isEmpty ? url : text, url: url.isEmpty ? nil : url)
        write(content, options: options, callback: callback)
    }

    public func writeImage(_ data: [UInt8], mimeType: String, options: Int32, callback: any ClipboardCallback) {
        // The bytes say what it is, whatever the guest called it.
        guard let type = PasteboardImageType.detect(data) else {
            Self.fail(callback, .invalidData)
            return
        }
        guard data.count <= Self.maximumSize else {
            Self.fail(callback, .tooLarge)
            return
        }
        write(.image(data, type: type), options: options, callback: callback)
    }

    public func writeImageFile(_ directory: Int32, path: String, options: Int32, callback: any ClipboardCallback) {
        let files = HostFiles.snapshot()
        let maximum = Self.maximumSize
        // The callback is only touched again on the main thread, in
        // `deliver`, and released there.
        let held = MainThreadHeld(callback)
        let deliver = Self.deliver
        Self.work {
            let result = Self.image(in: files, directory, path, maximum: maximum)
            deliver {
                guard let callback = held.take() else { return }
                switch result {
                case .success(let content):
                    HostClipboard.shared().write(content, options: options, callback: callback)
                case .failure(let error):
                    callback.didFail(error.rawValue)
                }
            }
        }
    }

    /// Reads an image file and says which kind it is. Off the main thread.
    private static func image(in files: HostFiles.Snapshot, _ directory: Int32, _ path: String, maximum: Int) -> Result<HostClipboardContent, PasteboardError> {
        do throws(FileError) {
            guard try files.size(directory, path: path) <= Int64(maximum) else {
                return .failure(.tooLarge)
            }
            let data = try files.contents(directory, path: path)
            guard let type = PasteboardImageType.detect(data) else {
                return .failure(.invalidData)
            }
            return .success(.image(data, type: type))
        } catch {
            return .failure(Self.error(reading: error))
        }
    }

    private static func error(reading error: FileError) -> PasteboardError {
        switch error {
        case .tooLarge: return .tooLarge
        case .notPermitted: return .notAllowed
        default: return .invalidData
        }
    }

    private static func error(writing error: FileError) -> PasteboardError {
        switch error {
        case .tooLarge: return .tooLarge
        case .notPermitted, .readOnly: return .notAllowed
        case .invalidPath, .isDirectory, .notDirectory: return .invalidData
        default: return .unknown
        }
    }

    // MARK: Reading

    public func readText(_ callback: any ClipboardCallback) {
        Self.current.read(.text, completion: Self.once(callback) { (callback, result: Result<HostClipboardContent?, PasteboardError>) in
            switch result {
            case .success(.text(let text, let url)):
                // A URL's text when a URL is all there is.
                callback.didReadText(text.isEmpty ? url : text)
            case .success:
                callback.didReadText(nil)
            case .failure(let error):
                callback.didFail(error.rawValue)
            }
        })
    }

    public func readURL(_ callback: any ClipboardCallback) {
        Self.current.read(.url, completion: Self.once(callback) { (callback, result: Result<HostClipboardContent?, PasteboardError>) in
            switch result {
            case .success(.text(_, let url)):
                callback.didReadText(url)
            case .success:
                callback.didReadText(nil)
            case .failure(let error):
                callback.didFail(error.rawValue)
            }
        })
    }

    /// The image a platform gave, checked: PNG or JPEG by its bytes, and
    /// not too large.
    private static func checked(_ result: Result<HostClipboardContent?, PasteboardError>) -> Result<PasteboardImage?, PasteboardError> {
        switch result {
        case .success(.image(let data, _)):
            guard let type = PasteboardImageType.detect(data) else {
                return .failure(.invalidData)
            }
            guard data.count <= maximumSize else {
                return .failure(.tooLarge)
            }
            return .success(PasteboardImage(data: data, type: type))
        case .success:
            return .success(nil)
        case .failure(let error):
            return .failure(error)
        }
    }

    public func readImage(_ callback: any ClipboardCallback) {
        Self.current.read(.image, completion: Self.once(callback) { (callback, result: Result<HostClipboardContent?, PasteboardError>) in
            switch Self.checked(result) {
            case .success(let image?):
                callback.didReadImage(image.data, mimeType: image.type.mimeType)
            case .success(nil):
                callback.didReadImage([], mimeType: "")
            case .failure(let error):
                callback.didFail(error.rawValue)
            }
        })
    }

    public func readImageToFile(_ directory: Int32, path: String, callback: any ClipboardCallback) {
        let held = MainThreadHeld(callback)
        var answered = false
        Self.current.read(.image) { result in
            // A platform that calls twice is heard once.
            guard !answered else { return }
            answered = true
            let files = HostFiles.snapshot()
            let deliver = Self.deliver
            let checked = Self.checked(result)
            Self.work {
                let answer: Result<String, PasteboardError>
                switch checked {
                case .success(let image?):
                    do throws(FileError) {
                        try files.write(image.data, to: directory, path: path)
                        answer = .success(image.type.mimeType)
                    } catch {
                        answer = .failure(Self.error(writing: error))
                    }
                case .success(nil):
                    // No image, and no file.
                    answer = .success("")
                case .failure(let error):
                    answer = .failure(error)
                }
                deliver {
                    guard let callback = held.take() else { return }
                    switch answer {
                    case .success(let type):
                        callback.didWriteImageFile(type)
                    case .failure(let error):
                        callback.didFail(error.rawValue)
                    }
                }
            }
        }
    }
}

/// The clipboard module: the contract and its callback.
public enum HostClipboardModule: HostModule {

    public static var contracts: [ContractDescriptor] {
        [ClipboardProxy.descriptor, ClipboardCallbackProxy.descriptor]
    }

    public static func register(in registrar: some ContractRegistrar) {
        ClipboardProxy.register(HostClipboard.self, in: registrar)
        ClipboardCallbackProxy.registerInterface(in: registrar)
    }
}
