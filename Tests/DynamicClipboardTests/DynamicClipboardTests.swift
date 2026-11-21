import Testing
import DynamicClipboard
import DynamicFiles
import DynamicRuntime
import RuntimeCore
import RuntimeNative

/// A host's clipboard that only writes down what it's asked, and keeps the
/// callbacks for the test to answer.
final class ScriptedClipboardHost: Clipboard {

    /// The one clipboard, as a host has: the guest keeps what it's given.
    nonisolated(unsafe) static let instance = ScriptedClipboardHost()

    var calls: [String] = []

    var callbacks: [any ClipboardCallback] = []

    var kinds: Int32 = 0

    static func shared() -> ScriptedClipboardHost { instance }

    func reset() {
        calls = []
        callbacks = []
        kinds = 0
    }

    func available() -> Int32 { kinds }

    func clear(_ callback: any ClipboardCallback) {
        calls.append("clear")
        callbacks.append(callback)
    }

    func writeText(_ text: String, url: String, options: Int32, callback: any ClipboardCallback) {
        calls.append("writeText \(text)|\(url)|\(options)")
        callbacks.append(callback)
    }

    func writeImage(_ data: [UInt8], mimeType: String, options: Int32, callback: any ClipboardCallback) {
        calls.append("writeImage \(data.count) \(mimeType) \(options)")
        callbacks.append(callback)
    }

    func writeImageFile(_ directory: Int32, path: String, options: Int32, callback: any ClipboardCallback) {
        calls.append("writeImageFile \(directory) \(path) \(options)")
        callbacks.append(callback)
    }

    func readText(_ callback: any ClipboardCallback) {
        calls.append("readText")
        callbacks.append(callback)
    }

    func readURL(_ callback: any ClipboardCallback) {
        calls.append("readURL")
        callbacks.append(callback)
    }

    func readImage(_ callback: any ClipboardCallback) {
        calls.append("readImage")
        callbacks.append(callback)
    }

    func readImageToFile(_ directory: Int32, path: String, callback: any ClipboardCallback) {
        calls.append("readImageToFile \(directory) \(path)")
        callbacks.append(callback)
    }
}

/// Serialized: the tests share the native runtime and the scripted host's
/// one clipboard.
@Suite(.serialized) final class DynamicClipboardTests {

    let host = ScriptedClipboardHost.instance

    let pasteboard = Pasteboard.general

    init() {
        let native = NativeRuntime.shared
        native.capabilities = nil
        ClipboardProxy.register(ScriptedClipboardHost.self, in: native)
        ClipboardCallbackProxy.registerInterface(in: native)
        host.reset()
    }

    func method(_ descriptor: ContractDescriptor, _ key: String) -> MethodDescriptor? {
        descriptor.methods.first { $0.key == key }
    }

    func error<Value>(_ result: Result<Value, PasteboardError>?) -> PasteboardError? {
        if case .failure(let error)? = result { return error }
        return nil
    }

    // MARK: Contracts

    @Test func theClipboardNeedsNoCapability() {
        let clipboard = ClipboardProxy.descriptor
        #expect(clipboard.name == "org.pureswift.clipboard.Clipboard")
        #expect(clipboard.capability == nil)
        #expect(method(clipboard, "available")?.signature == Signature("()I"))
        #expect(method(clipboard, "clear:")?.signature == Signature("(O)V"))
        #expect(method(clipboard, "writeText:url:options:callback:")?.signature == Signature("(OOIO)V"))
        #expect(method(clipboard, "writeImage:mimeType:options:callback:")?.signature == Signature("(OOIO)V"))
        #expect(method(clipboard, "writeImageFile:path:options:callback:")?.signature == Signature("(IOIO)V"))
        #expect(method(clipboard, "readText:")?.signature == Signature("(O)V"))
        #expect(method(clipboard, "readImageToFile:path:callback:")?.signature == Signature("(IOO)V"))
        #expect(clipboard.methods.count == 10)

        let callback = ClipboardCallbackProxy.descriptor
        #expect(callback.name == "org.pureswift.clipboard.Callback" && callback.kind == .callback)
        #expect(method(callback, "didReadText:")?.signature == Signature("(O)V"))
        #expect(method(callback, "didReadImage:mimeType:")?.signature == Signature("(OO)V"))
        #expect(method(callback, "didFail:")?.signature == Signature("(I)V"))
        #expect(callback.methods.count == 5)

        let descriptors = [clipboard, callback]
        #expect(ContractMetadata.decode(descriptors.flatMap(ContractMetadata.encode)) == descriptors)
    }

    // MARK: Types

    @Test func anImagesBytesSayWhatItIs() {
        #expect(PasteboardImageType.detect([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0]) == .png)
        #expect(PasteboardImageType.detect([0xFF, 0xD8, 0xFF, 0xE0]) == .jpeg)
        #expect(PasteboardImageType.detect([0x89, 0x50, 0x4E]) == nil, "too short to be one")
        #expect(PasteboardImageType.detect(Array("GIF89a".utf8)) == nil)
        #expect(PasteboardImageType.detect([]) == nil)
        #expect(PasteboardImageType.png.mimeType == "image/png" && PasteboardImageType.jpeg.mimeType == "image/jpeg")
        #expect(PasteboardImageType.png.fileExtension == "png" && PasteboardImageType.jpeg.fileExtension == "jpg")
        #expect(ClipboardKinds.all.rawValue == 7 && PasteboardOptions.sensitive.rawValue == 1)
        #expect(PasteboardError.notAllowed.rawValue == 2 && PasteboardError.tooLarge.rawValue == 5)
    }

    // MARK: Looking

    @Test func lookingAsksOnlyWhatMightBeThere() {
        #expect(!pasteboard.hasStrings && !pasteboard.hasURLs && !pasteboard.hasImages)
        host.kinds = ClipboardKinds.text.rawValue
        #expect(pasteboard.hasStrings && !pasteboard.hasURLs && !pasteboard.hasImages)
        host.kinds = ClipboardKinds.url.rawValue
        #expect(pasteboard.hasStrings && pasteboard.hasURLs, "a URL can be pasted as text")
        host.kinds = ClipboardKinds.image.rawValue
        #expect(!pasteboard.hasStrings && pasteboard.hasImages)
        host.kinds = 7 | 64
        #expect(pasteboard.available == .all, "a kind from a newer host isn't one the app knows")
        #expect(host.calls.isEmpty, "nothing was read")
    }

    // MARK: Copying

    @Test func copyingSaysWhatToPutThere() {
        pasteboard.setString("42")
        pasteboard.setString("hunter2", options: .sensitive)
        pasteboard.setURL("https://swift.org")
        pasteboard.setURL("https://swift.org", title: "Swift")
        pasteboard.setImage([1, 2, 3], type: .jpeg)
        pasteboard.setImage(contentsOf: .bundle / "logo.png", options: .sensitive)
        pasteboard.setImage(contentsOf: FilePath(FileDirectory(rawValue: 300)))
        pasteboard.clear()
        #expect(host.calls == [
            "writeText 42||0", "writeText hunter2||1",
            "writeText https://swift.org|https://swift.org|0", "writeText Swift|https://swift.org|0",
            "writeImage 3 image/jpeg 0", "writeImageFile 4 logo.png 1", "writeImageFile 300  0", "clear",
        ], "a URL with no title is its own text")
        // With no completion handler, an answer goes nowhere.
        host.callbacks[0].didComplete()
        host.callbacks[1].didFail(PasteboardError.notAllowed.rawValue)
    }

    @Test func aCopyCanSayHowItWent() {
        var results: [Result<Void, PasteboardError>] = []
        pasteboard.setString("a") { results.append($0) }
        pasteboard.setImage(contentsOf: .documents / "a.png") { results.append($0) }
        pasteboard.clear { results.append($0) }
        pasteboard.setURL("u") { results.append($0) }
        host.callbacks[0].didComplete()
        host.callbacks[0].didFail(0)
        #expect(results.count == 1 && error(results[0]) == nil, "only a host's first answer counts")
        host.callbacks[1].didFail(PasteboardError.invalidData.rawValue)
        host.callbacks[2].didFail(99)
        host.callbacks[3].didReadText("odd")
        #expect(error(results[1]) == .invalidData)
        #expect(error(results[2]) == .unknown, "an error from a newer host")
        #expect(error(results[3]) == .unknown, "an answer of the wrong kind")
    }

    // MARK: Pasting

    @Test func pastingGivesWhatIsThereOrNothing() {
        var texts: [Result<String?, PasteboardError>] = []
        pasteboard.string { texts.append($0) }
        pasteboard.url { texts.append($0) }
        pasteboard.string { texts.append($0) }
        pasteboard.url { texts.append($0) }
        #expect(host.calls == ["readText", "readURL", "readText", "readURL"])
        host.callbacks[0].didReadText("pasted")
        host.callbacks[1].didReadText(nil)
        host.callbacks[2].didFail(PasteboardError.notAllowed.rawValue)
        host.callbacks[3].didComplete()
        #expect((try? texts[0].get()) == "pasted")
        if case .success(let none) = texts[1] { #expect(none == nil, "nothing there isn't an error") } else { Issue.record("no URL was a failure") }
        #expect(error(texts[2]) == .notAllowed && error(texts[3]) == .unknown)
    }

    @Test func aPastedImageIsAFileOrItsBytes() {
        var images: [Result<PasteboardImage?, PasteboardError>] = []
        var files: [Result<PasteboardImageType?, PasteboardError>] = []
        pasteboard.image { images.append($0) }
        pasteboard.image { images.append($0) }
        pasteboard.image { images.append($0) }
        pasteboard.image(to: .caches / "pasted") { files.append($0) }
        pasteboard.image(to: .caches / "pasted") { files.append($0) }
        pasteboard.image(to: .caches / "pasted") { files.append($0) }
        #expect(host.calls.suffix(3) == ["readImageToFile 2 pasted", "readImageToFile 2 pasted", "readImageToFile 2 pasted"])

        host.callbacks[0].didReadImage([9, 8, 7], mimeType: "image/jpeg")
        host.callbacks[1].didReadImage([], mimeType: "")
        host.callbacks[2].didReadImage([1], mimeType: "image/avif")
        #expect((try? images[0].get()) == PasteboardImage(data: [9, 8, 7], type: .jpeg))
        if case .success(let none) = images[1] { #expect(none == nil) } else { Issue.record("no image was a failure") }
        #expect(error(images[2]) == .unsupported, "a type from a newer host isn't one the app was promised")

        host.callbacks[3].didWriteImageFile("image/png")
        host.callbacks[4].didWriteImageFile("")
        host.callbacks[5].didFail(PasteboardError.tooLarge.rawValue)
        #expect((try? files[0].get()) == .png)
        if case .success(let none) = files[1] { #expect(none == nil) } else { Issue.record("no image was a failure") }
        #expect(error(files[2]) == .tooLarge)
    }
}
