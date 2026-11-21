import Dispatch
import DynamicFiles
import DynamicRuntime
import DynamicText
import RuntimeABI
import RuntimeCore
import RuntimeHost

/// One of the platform's texts: a text view's storage. Everything is
/// called on the main thread, with positions in UTF-16 units that are
/// inside the text and outside its surrogate pairs.
///
/// It reports what happens to the `HostTextStorage` it was made for, on
/// the main thread: `edited` for every change to the text, whoever made
/// it (the user, `replace`, `setText`, `undo`, `redo`); `selectionChanged`;
/// and `undoChanged`. A text holds `\n` only: what the user pastes is
/// converted before it goes in (`TextCoding.normalizingLineBreaks`).
public protocol TextEngine: AnyObject {

    /// In UTF-16 units.
    var length: Int { get }

    func text(in range: Range<Int>) -> String

    /// A new text: the undo history emptied, the caret at the start.
    /// Reported as one edit of everything.
    func setText(_ text: String)

    /// One undo step, on the same history as the user's typing.
    func replace(_ range: Range<Int>, with text: String)

    var selection: Range<Int> { get set }

    /// At least 1. Lines end at `\n`.
    var lineCount: Int { get }

    /// The line a position is on, counting from 0.
    func line(at location: Int) -> Int

    /// Where a line starts; `nil` past the last.
    func lineStart(_ line: Int) -> Int?

    func undo()

    func redo()

    /// Scrolls a range into view, where the text is shown.
    func reveal(_ range: Range<Int>)
}

/// The platform's side of text: its text views.
public protocol TextPlatform: AnyObject {

    /// An empty text, which reports to `storage`. Main thread.
    func makeEngine(for storage: HostTextStorage) -> any TextEngine

    /// The longest text the platform's view opens, in UTF-16 units.
    var maximumLength: Int { get }

    /// Whether the platform reads and writes an encoding that isn't one of
    /// the five every host has. `name` is an IANA name in lower case.
    func supportsEncoding(_ name: String) -> Bool

    /// Reads and writes those. Its closures run off the main thread.
    var extraEncodings: TextCoding.Extra? { get }
}

public extension TextPlatform {

    func supportsEncoding(_ name: String) -> Bool {
        false
    }

    var extraEncodings: TextCoding.Extra? {
        nil
    }
}

/// The `TextStorage` contract over a host's `TextPlatform`: what every
/// host written in Swift shares.
///
/// It reads and writes files off the main thread, through `HostFiles` so a
/// picked document works; decodes and encodes them; keeps `\n` as the only
/// line break; moves positions into the text and out of surrogate pairs;
/// keeps whether the text is modified; searches; and says where the
/// selection goes when the guest edits.
///
/// ```swift
/// HostTextStorage.platform = MyTextViews()
/// HostTextModule.register(in: runtime)
///
/// // For a `TextEditor` node's `buffer` prop:
/// let engine = HostTextStorage.storage(for: identifier)?.engine
/// ```
///
/// Without a platform, texts are held in memory (`MemoryTextEngine`) and
/// shown nowhere. Main thread only.
public final class HostTextStorage: TextStorage {

    // MARK: The host's settings

    /// The platform's text views.
    nonisolated(unsafe) public static var platform: (any TextPlatform)?

    /// Runs file work off the main thread. The default is a serial queue.
    nonisolated(unsafe) public static var work: @Sendable (@escaping @Sendable () -> Void) -> Void = defaultWork

    /// Runs an answer on the main thread. The default is the main dispatch
    /// queue; a host with a loop of its own posts to that.
    nonisolated(unsafe) public static var deliver: @Sendable (@escaping @Sendable () -> Void) -> Void = defaultDeliver

    /// The longest text held in memory, where no platform says.
    public static let defaultMaximumLength = 16 << 20

    private static let queue = DispatchQueue(label: "org.pureswift.runtime.text")

    private static let defaultWork: @Sendable (@escaping @Sendable () -> Void) -> Void = { queue.async(execute: $0) }

    private static let defaultDeliver: @Sendable (@escaping @Sendable () -> Void) -> Void = { DispatchQueue.main.async(execute: $0) }

    nonisolated(unsafe) private static var storages: [Int32: Weak] = [:]

    nonisolated(unsafe) private static var nextIdentifier: Int32 = 1

    private struct Weak {
        weak var storage: HostTextStorage?
    }

    // MARK: A text

    private let delegate: any TextStorageDelegate

    private let number: Int32

    private var made: (any TextEngine)?

    /// The platform's text, for whatever shows it.
    public var engine: any TextEngine {
        made!
    }

    public private(set) var isModified = false

    private var canUndo = false

    private var canRedo = false

    /// The selection the guest last heard of.
    private var reportedSelection = 0 ..< 0

    /// While the guest's own edit is applied: the selection is said once,
    /// when it has settled.
    private var holdsSelection = false

    /// While a new text replaces everything, which doesn't modify it.
    private var isStartingOver = false

    /// Counts loads, so one that another replaced knows.
    private var loadToken = 0

    /// Counts edits, so a save knows whether the text changed under it.
    private var edits = 0

    init(delegate: any TextStorageDelegate) {
        self.delegate = delegate
        self.number = Self.nextIdentifier
        Self.nextIdentifier += 1
        Self.storages[number] = Weak(storage: self)
        self.made = Self.platform?.makeEngine(for: self) ?? MemoryTextEngine(storage: self)
    }

    deinit {
        Self.storages[number] = nil
    }

    public static func make(_ delegate: any TextStorageDelegate) -> HostTextStorage {
        HostTextStorage(delegate: delegate)
    }

    public static func maximumLength() -> Int32 {
        Int32(clamping: platform?.maximumLength ?? defaultMaximumLength)
    }

    public static func supportsEncoding(_ name: String) -> Bool {
        let name = TextCoding.normalized(name)
        return TextCoding.required.contains(name) || platform?.supportsEncoding(name) == true
    }

    public func identifier() -> Int32 {
        number
    }

    // MARK: Host side

    /// The text a `TextEditor` node names, while the guest holds it.
    public static func storage(for identifier: Int32) -> HostTextStorage? {
        storages[identifier]?.storage
    }

    /// Forgets the platform and the settings, for tests and for a host
    /// that starts the guest again.
    public static func reset() {
        platform = nil
        work = defaultWork
        deliver = defaultDeliver
    }

    // MARK: From the engine

    /// `removed` units at `location` became `inserted` units: every
    /// change to the text, whoever made it.
    public func edited(at location: Int, removed: Int, inserted: Int) {
        edits &+= 1
        delegate.didEdit(
            Int32(clamping: location), removed: Int32(clamping: removed), inserted: Int32(clamping: inserted),
            length: Int32(clamping: engine.length)
        )
        if !isStartingOver {
            set(modified: true)
        }
        reportSelection()
    }

    /// The selection moved.
    public func selectionChanged() {
        reportSelection()
    }

    public func undoChanged(canUndo: Bool, canRedo: Bool) {
        guard canUndo != self.canUndo || canRedo != self.canRedo else { return }
        self.canUndo = canUndo
        self.canRedo = canRedo
        delegate.didChangeUndo(canUndo, canRedo: canRedo)
    }

    private func reportSelection() {
        guard !holdsSelection, let engine = made else { return }
        let selection = engine.selection
        guard selection != reportedSelection else { return }
        reportedSelection = selection
        delegate.didChangeSelection(Int32(clamping: selection.lowerBound), length: Int32(clamping: selection.count))
    }

    private func set(modified: Bool) {
        guard modified != isModified else { return }
        isModified = modified
        delegate.didChangeModified(modified)
    }

    // MARK: Positions

    /// A position inside the text, and not inside a surrogate pair.
    private func position(_ value: Int) -> Int {
        let length = engine.length
        let position = min(max(value, 0), length)
        if position > 0, position < length, Self.isPair(engine.text(in: position - 1 ..< position + 1)) {
            return position - 1
        }
        return position
    }

    private func range(_ location: Int32, _ length: Int32) -> Range<Int> {
        let lower = position(Int(location))
        let upper = position(Int(location) + Int(max(length, 0)))
        return lower ..< max(lower, upper)
    }

    /// Whether two units are the halves of one character.
    private static func isPair(_ text: String) -> Bool {
        var units = text.utf16.makeIterator()
        guard let first = units.next(), let second = units.next(), units.next() == nil else { return false }
        return UTF16.isLeadSurrogate(first) && UTF16.isTrailSurrogate(second)
    }

    private var everything: String {
        engine.text(in: 0 ..< engine.length)
    }

    // MARK: Reading

    public func length() -> Int32 {
        Int32(clamping: engine.length)
    }

    public func text() -> String {
        everything
    }

    public func substring(_ location: Int32, length: Int32) -> String {
        engine.text(in: range(location, length))
    }

    public func lineCount() -> Int32 {
        Int32(clamping: max(engine.lineCount, 1))
    }

    public func line(_ location: Int32) -> Int32 {
        Int32(clamping: engine.line(at: position(Int(location))))
    }

    public func lineStart(_ line: Int32) -> Int32 {
        guard line >= 0, let start = engine.lineStart(Int(line)) else { return -1 }
        return Int32(clamping: start)
    }

    // MARK: Changing

    public func setText(_ text: String) {
        startOver(with: TextCoding.normalizingLineBreaks(text).text)
    }

    /// A new text in the engine: reported as one edit of everything, with
    /// no undo history, the caret at the start, unmodified.
    private func startOver(with text: String) {
        isStartingOver = true
        holdsSelection = true
        engine.setText(text)
        if engine.selection != 0 ..< 0 {
            engine.selection = 0 ..< 0
        }
        holdsSelection = false
        isStartingOver = false
        set(modified: false)
        reportSelection()
    }

    public func replace(_ location: Int32, length: Int32, text: String) {
        change(range(location, length), to: TextCoding.normalizingLineBreaks(text).text)
    }

    /// The guest's edit: one undo step. The selection goes where
    /// `TextPositions` says, whatever the platform's view would do.
    private func change(_ range: Range<Int>, to text: String) {
        guard !range.isEmpty || !text.isEmpty else { return }
        let engine = self.engine
        let before = engine.selection
        let inserted = text.utf16.count
        holdsSelection = true
        engine.replace(range, with: text)
        let lower = TextPositions.adjusting(before.lowerBound, forEditAt: range.lowerBound, removed: range.count, inserted: inserted)
        let upper = TextPositions.adjusting(before.upperBound, forEditAt: range.lowerBound, removed: range.count, inserted: inserted)
        let after = lower ..< max(lower, upper)
        if engine.selection != after {
            engine.selection = after
        }
        holdsSelection = false
        reportSelection()
    }

    public func setSelection(_ location: Int32, length: Int32) {
        let selection = range(location, length)
        if engine.selection != selection {
            engine.selection = selection
        }
        reportSelection()
    }

    public func undo() {
        engine.undo()
    }

    public func redo() {
        engine.redo()
    }

    public func setModified(_ modified: Bool) {
        set(modified: modified)
    }

    public func reveal(_ location: Int32, length: Int32) {
        engine.reveal(range(location, length))
    }

    // MARK: Files

    /// Calls `answer` with the callback, on the main thread and later.
    private static func later(_ callback: any TextCallback, _ answer: @escaping (any TextCallback) -> Void) {
        let held = MainThreadHeld((callback, answer))
        deliver {
            guard let (callback, answer) = held.take() else { return }
            answer(callback)
        }
    }

    private static func fail(_ callback: any TextCallback, _ error: TextError) {
        later(callback) { $0.didFail(error.code.rawValue, file: error.fileCode) }
    }

    /// What reads and writes `encoding`, when it isn't one of the five;
    /// `unsupportedEncoding` when nothing does.
    private static func extra(for encoding: String) throws(TextError) -> TextCoding.Extra? {
        let name = TextCoding.normalized(encoding)
        guard !name.isEmpty, !TextCoding.required.contains(name) else { return nil }
        guard let platform, platform.supportsEncoding(name), let extra = platform.extraEncodings else {
            throw .unsupportedEncoding
        }
        return extra
    }

    public func load(_ directory: Int32, path: String, encoding: String, callback: any TextCallback) {
        // Another load replaces the one that hasn't finished.
        loadToken &+= 1
        let token = loadToken
        let extra: TextCoding.Extra?
        do throws(TextError) {
            extra = try Self.extra(for: encoding)
        } catch {
            Self.fail(callback, error)
            return
        }
        let files = HostFiles.snapshot()
        let maximum = Int(Self.maximumLength())
        // The callback is only touched again on the main thread, in
        // `deliver`, and released there.
        let held = MainThreadHeld((Weak(storage: self), callback))
        let deliver = Self.deliver
        Self.work {
            let result = Self.read(files, directory, path, encoding: encoding, maximum: maximum, extra: extra)
            deliver {
                guard let (owner, callback) = held.take() else { return }
                guard let storage = owner.storage, storage.loadToken == token else {
                    // The guest released the text, or loaded another file.
                    callback.didFail(TextError.cancelled.code.rawValue, file: 0)
                    return
                }
                switch result {
                case .success(let decoded):
                    storage.startOver(with: decoded.text)
                    callback.didLoad(decoded.encoding, lineEnding: decoded.lineEnding.rawValue, byteOrderMark: decoded.hasByteOrderMark)
                case .failure(let error):
                    callback.didFail(error.code.rawValue, file: error.fileCode)
                }
            }
        }
    }

    /// Reads and decodes a file. Off the main thread.
    private static func read(
        _ files: HostFiles.Snapshot, _ directory: Int32, _ path: String, encoding: String, maximum: Int, extra: TextCoding.Extra?
    ) -> Result<TextCoding.Decoded, TextError> {
        let bytes: [UInt8]
        do throws(FileError) {
            // No encoding spends more than four bytes on a UTF-16 unit, so
            // a file longer than this can't fit, and isn't read.
            guard try files.size(directory, path: path) <= Int64(maximum) * 4 + 4 else {
                return .failure(.tooLarge)
            }
            bytes = try files.contents(directory, path: path)
        } catch {
            return .failure(.file(error))
        }
        do throws(TextError) {
            let decoded = try TextCoding.decode(bytes, encoding: encoding, extra: extra)
            guard decoded.text.utf16.count <= maximum else {
                return .failure(.tooLarge)
            }
            return .success(decoded)
        } catch {
            return .failure(error)
        }
    }

    public func save(_ directory: Int32, path: String, encoding: String, lineEnding: Int32, byteOrderMark: Bool, callback: any TextCallback) {
        let extra: TextCoding.Extra?
        do throws(TextError) {
            extra = try Self.extra(for: encoding)
        } catch {
            Self.fail(callback, error)
            return
        }
        // The text as it is now. What's typed while it's written isn't in
        // the file, and leaves the text modified.
        let text = everything
        let stamp = edits
        // A line ending from a newer guest is written as `\n`.
        let lineEnding = LineEnding(rawValue: lineEnding) ?? .lf
        let files = HostFiles.snapshot()
        let held = MainThreadHeld((Weak(storage: self), callback))
        let deliver = Self.deliver
        Self.work {
            let result = Self.write(text, files, directory, path, encoding: encoding, lineEnding: lineEnding, byteOrderMark: byteOrderMark, extra: extra)
            deliver {
                guard let (owner, callback) = held.take() else { return }
                switch result {
                case .success:
                    if let storage = owner.storage, storage.edits == stamp {
                        storage.set(modified: false)
                    }
                    callback.didComplete()
                case .failure(let error):
                    callback.didFail(error.code.rawValue, file: error.fileCode)
                }
            }
        }
    }

    /// Encodes and writes a file. Off the main thread.
    private static func write(
        _ text: String, _ files: HostFiles.Snapshot, _ directory: Int32, _ path: String,
        encoding: String, lineEnding: LineEnding, byteOrderMark: Bool, extra: TextCoding.Extra?
    ) -> Result<Void, TextError> {
        let bytes: [UInt8]
        do throws(TextError) {
            bytes = try TextCoding.encode(text, encoding: encoding, lineEnding: lineEnding, byteOrderMark: byteOrderMark, extra: extra)
        } catch {
            return .failure(error)
        }
        do throws(FileError) {
            try files.write(bytes, to: directory, path: path)
            return .success(())
        } catch {
            return .failure(.file(error))
        }
    }

    // MARK: Searching

    public func find(_ text: String, options: Int32, from location: Int32, callback: any TextCallback) {
        let match = TextSearch.find(
            text, in: Array(everything.utf16), options: TextSearchOptions(rawValue: options), from: position(Int(location))
        )
        Self.later(callback) { callback in
            if let match {
                callback.didFind(Int32(clamping: match.lowerBound), length: Int32(clamping: match.count))
            } else {
                callback.didFind(-1, length: 0)
            }
        }
    }

    public func replaceAll(_ text: String, with replacement: String, options: Int32, callback: any TextCallback) {
        let units = Array(everything.utf16)
        let matches = TextSearch.matches(of: text, in: units, options: TextSearchOptions(rawValue: options))
        if let first = matches.first, let last = matches.last {
            // One edit, and so one undo step, from the first match to the
            // last.
            let replacement = Array(TextCoding.normalizingLineBreaks(replacement).text.utf16)
            var changed: [UInt16] = []
            var position = first.lowerBound
            for match in matches {
                changed.append(contentsOf: units[position ..< match.lowerBound])
                changed.append(contentsOf: replacement)
                position = match.upperBound
            }
            change(first.lowerBound ..< last.upperBound, to: String(decoding: changed, as: UTF16.self))
        }
        let count = Int32(clamping: matches.count)
        Self.later(callback) { $0.didReplace(count) }
    }
}

/// The text module: the contract, its delegate and its callback.
public enum HostTextModule: HostModule {

    public static var contracts: [ContractDescriptor] {
        [TextStorageProxy.descriptor, TextStorageDelegateProxy.descriptor, TextCallbackProxy.descriptor]
    }

    public static func register(in registrar: some ContractRegistrar) {
        TextStorageProxy.register(HostTextStorage.self, in: registrar)
        TextStorageDelegateProxy.registerInterface(in: registrar)
        TextCallbackProxy.registerInterface(in: registrar)
    }
}
