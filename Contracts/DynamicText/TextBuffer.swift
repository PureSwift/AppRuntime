import DynamicFiles
import DynamicRuntime
#if canImport(DynamicObservation)
@_exported import DynamicObservation
#else
@_exported import Observation
#endif
#if hasFeature(Embedded) && !EMBEDDED_NO_CONCURRENCY
// Embedded Swift doesn't import the concurrency module implicitly.
import _Concurrency
#endif

/// A text the host holds and the user edits: a file in a text editor, a
/// message being written. Show it with `TextEditor(buffer)`.
///
/// ```swift
/// let buffer = TextBuffer()
/// try await buffer.load(document.path)
///
/// // In a view's body:
/// TextEditor(buffer)
/// Text(buffer.isModified ? "Edited" : "Saved")
///
/// try await buffer.save(to: document.path)
/// ```
///
/// The text lives in the host (`TextStorage`), which is made the first
/// time the buffer is used or shown. Typing never crosses to the guest: the
/// buffer hears that a range changed, and asks for what it needs. It keeps
/// its text, selection and undo history while its view comes and goes, and
/// is destroyed when the `TextBuffer` is released.
///
/// Positions are UTF-16 code units from the start of the text, as
/// `"text".utf16.count` counts, and the text holds `\n` as its only line
/// break. It's observable.
public final class TextBuffer: Observable {

    // MARK: State

    /// In UTF-16 units.
    public var length: Int {
        registrar.access(self, propertyIndex: 0)
        return values.length
    }

    /// What's selected; empty is the caret. A range outside the text is
    /// cut to it.
    public var selection: Range<Int> {
        get {
            registrar.access(self, propertyIndex: 1)
            return values.selection
        }
        set {
            // The host reports where it landed.
            storage.setSelection(Int32(clamping: newValue.lowerBound), length: Int32(clamping: newValue.count))
        }
    }

    /// Whether the text changed since it was loaded, saved or made.
    public var isModified: Bool {
        registrar.access(self, propertyIndex: 2)
        return values.isModified
    }

    public var canUndo: Bool {
        registrar.access(self, propertyIndex: 3)
        return values.canUndo
    }

    public var canRedo: Bool {
        registrar.access(self, propertyIndex: 4)
        return values.canRedo
    }

    /// Whether a `load` is under way. The buffer keeps the text it had
    /// until the load finishes.
    public var isLoading: Bool {
        registrar.access(self, propertyIndex: 5)
        return values.loads > 0
    }

    /// What `load` found the file in, and what `save` writes.
    public var encoding: TextEncoding {
        get {
            registrar.access(self, propertyIndex: 6)
            return values.encoding
        }
        set {
            mutate(6) { values.encoding = newValue }
        }
    }

    /// The line break `load` found first in the file, and what `save`
    /// writes for each `\n`.
    public var lineEnding: LineEnding {
        get {
            registrar.access(self, propertyIndex: 6)
            return values.lineEnding
        }
        set {
            mutate(6) { values.lineEnding = newValue }
        }
    }

    /// Whether the file began with a byte-order mark, and `save` writes one.
    public var hasByteOrderMark: Bool {
        get {
            registrar.access(self, propertyIndex: 6)
            return values.hasByteOrderMark
        }
        set {
            mutate(6) { values.hasByteOrderMark = newValue }
        }
    }

    /// Called after every change to the text, whoever made it: the user,
    /// this code, an undo. It says which range was replaced and how long
    /// the replacement is, not the text; ask with `substring`.
    public var onEdit: ((TextEdit) -> Void)?

    /// Called when the selection changes, whoever moved it.
    public var onSelectionChange: ((Range<Int>) -> Void)?

    /// The longest text this host opens, in UTF-16 units.
    public static var maximumLength: Int {
        Int(TextStorageProxy.maximumLength())
    }

    public init(_ text: String = "") {
        // As the host will hold it, so its length is right before the
        // host has it.
        let text = Self.normalizingLineBreaks(text)
        initial = text
        values.length = text.utf16.count
    }

    /// `text` with `\r\n` and `\r` as `\n`, the only line break a buffer
    /// holds.
    private static func normalizingLineBreaks(_ text: String) -> String {
        guard text.utf8.contains(0x0D) else { return text }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(text.utf8.count)
        var afterReturn = false
        for byte in text.utf8 {
            if byte == 0x0D {
                bytes.append(0x0A)
                afterReturn = true
                continue
            }
            if byte == 0x0A, afterReturn {
                afterReturn = false
                continue
            }
            afterReturn = false
            bytes.append(byte)
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    deinit {
        // The host may still hold the receiver until it destroys the text.
        receiver.buffer = nil
        #if !EMBEDDED_NO_CONCURRENCY
        subscribers.finishAll()
        #endif
    }

    // MARK: Reading

    /// The whole text, copied out of the host. Setting it starts a new
    /// text: no undo history, the caret at the start, unmodified.
    public var string: String {
        get {
            registrar.access(self, propertyIndex: 7)
            return storage.text()
        }
        set {
            storage.setText(newValue)
        }
    }

    public func substring(_ range: Range<Int>) -> String {
        registrar.access(self, propertyIndex: 7)
        return storage.substring(Int32(clamping: range.lowerBound), length: Int32(clamping: range.count))
    }

    /// At least 1.
    public var lineCount: Int {
        registrar.access(self, propertyIndex: 7)
        return Int(storage.lineCount())
    }

    /// The line a position is on, counting from 0.
    public func line(at position: Int) -> Int {
        Int(storage.line(Int32(clamping: position)))
    }

    /// A line's range, with its line break; `nil` past the last line.
    public func range(ofLine line: Int) -> Range<Int>? {
        let storage = self.storage
        let start = storage.lineStart(Int32(clamping: line))
        guard start >= 0 else { return nil }
        let next = storage.lineStart(Int32(clamping: line + 1))
        return Int(start) ..< Int(next >= 0 ? next : storage.length())
    }

    // MARK: Changing

    /// One undo step, on the same history as the user's typing.
    public func replace(_ range: Range<Int>, with text: String) {
        storage.replace(Int32(clamping: range.lowerBound), length: Int32(clamping: range.count), text: text)
    }

    /// Puts `text` at the caret, in place of what's selected, and leaves
    /// the caret after it.
    public func insert(_ text: String) {
        replace(values.selection, with: text)
    }

    public func undo() {
        storage.undo()
    }

    public func redo() {
        storage.redo()
    }

    /// Scrolls a range into view.
    public func reveal(_ range: Range<Int>) {
        storage.reveal(Int32(clamping: range.lowerBound), length: Int32(clamping: range.count))
    }

    /// Clears `isModified`, for an app that stores the text some other
    /// way than `save`.
    public func markSaved() {
        storage.setModified(false)
    }

    // MARK: Files

    /// Replaces the text with a file's, once the host has read and decoded
    /// it. With no `encoding`, the file's byte-order mark says, and UTF-8
    /// otherwise; a file that is neither fails with `undecodable`.
    ///
    /// Sets `encoding`, `lineEnding` and `hasByteOrderMark` to what it
    /// found. A second load replaces the first, which fails with
    /// `cancelled`.
    public func load(_ path: FilePath, encoding: TextEncoding? = nil, completion: @escaping (Result<Void, TextError>) -> Void) {
        let storage = self.storage
        let receiver = self.receiver
        values.loads += 1
        if values.loads == 1 {
            mutate(5) { }
        }
        storage.load(path.directory.rawValue, path: path.path, encoding: encoding?.rawValue ?? "", callback: OperationReceiver { outcome in
            receiver.current?.finishedLoad(outcome)
            if case .loaded = outcome {
                completion(.success(()))
            } else {
                completion(.failure(outcome.error))
            }
        })
    }

    /// Writes the text as it is now, in the buffer's `encoding` and
    /// `lineEnding`, replacing the file. If nothing changes meanwhile,
    /// `isModified` is false when it completes.
    public func save(to path: FilePath, completion: @escaping (Result<Void, TextError>) -> Void) {
        storage.save(
            path.directory.rawValue, path: path.path, encoding: values.encoding.rawValue,
            lineEnding: values.lineEnding.rawValue, byteOrderMark: values.hasByteOrderMark,
            callback: OperationReceiver { outcome in
                if case .complete = outcome {
                    completion(.success(()))
                } else {
                    completion(.failure(outcome.error))
                }
            }
        )
    }

    // MARK: Searching

    /// The next match's range, or `nil`. It starts from `position`; with
    /// none, from the selection's end, or its start going backwards. The
    /// host searches: the guest doesn't hold the text.
    public func find(_ text: String, options: TextSearchOptions = [], from position: Int? = nil, completion: @escaping (Range<Int>?) -> Void) {
        let start = position ?? (options.contains(.backwards) ? values.selection.lowerBound : values.selection.upperBound)
        storage.find(text, options: options.rawValue, from: Int32(clamping: start), callback: OperationReceiver { outcome in
            if case .found(let range) = outcome {
                completion(range)
            } else {
                completion(nil)
            }
        })
    }

    /// Replaces every match, as one undo step, and says how many.
    public func replaceAll(_ text: String, with replacement: String, options: TextSearchOptions = [], completion: @escaping (Int) -> Void) {
        storage.replaceAll(text, with: replacement, options: options.rawValue, callback: OperationReceiver { outcome in
            if case .replaced(let count) = outcome {
                completion(count)
            } else {
                completion(0)
            }
        })
    }

    // MARK: Async

    // Each runs where it's called from, as the guest's one thread wants
    // (§6.4).

    #if !EMBEDDED_NO_CONCURRENCY
    /// - Throws: `TextError`. A cancelled task stops waiting with
    ///   `cancelled`; the load itself goes on.
    public nonisolated(nonsending) func load(_ path: FilePath, encoding: TextEncoding? = nil) async throws(TextError) {
        try await withCallback { (callback: Callback<Void, TextError>) in
            self.load(path, encoding: encoding) { callback.resume(with: $0) }
        } onCancel: { callback in
            callback.resume(throwing: .cancelled)
        }
    }

    public nonisolated(nonsending) func save(to path: FilePath) async throws(TextError) {
        try await withCallback { (callback: Callback<Void, TextError>) in
            self.save(to: path) { callback.resume(with: $0) }
        } onCancel: { callback in
            callback.resume(throwing: .cancelled)
        }
    }

    public nonisolated(nonsending) func find(_ text: String, options: TextSearchOptions = [], from position: Int? = nil) async -> Range<Int>? {
        await withCallback { (callback: Callback<Range<Int>?, Never>) in
            self.find(text, options: options, from: position) { callback.resume(returning: $0) }
        } onCancel: { callback in
            callback.resume(returning: nil)
        }
    }

    /// A cancelled task stops waiting with 0; the replacing still happens.
    @discardableResult
    public nonisolated(nonsending) func replaceAll(_ text: String, with replacement: String, options: TextSearchOptions = []) async -> Int {
        await withCallback { (callback: Callback<Int, Never>) in
            self.replaceAll(text, with: replacement, options: options) { callback.resume(returning: $0) }
        } onCancel: { callback in
            callback.resume(returning: 0)
        }
    }

    /// Every change to the text, from when the stream is first awaited.
    /// Any number can run at once. It ends when the buffer is released.
    public var edits: EventStream<TextEdit, Never> {
        let (stream, continuation) = EventStream<TextEdit, Never>.makeStream()
        let subscribers = self.subscribers
        let id = subscribers.add(continuation)
        continuation.onTermination = {
            subscribers.remove(id)
        }
        return stream
    }
    #endif

    // MARK: The host's text

    /// What a `TextEditor` node carries: the host text's identifier.
    /// Asking makes the text in the host.
    public var identifier: Int32 {
        if let cached = cachedIdentifier {
            return cached
        }
        let identifier = storage.identifier()
        cachedIdentifier = identifier
        return identifier
    }

    private struct Values {
        var length = 0
        var selection = 0 ..< 0
        var isModified = false
        var canUndo = false
        var canRedo = false
        var loads = 0
        var encoding = TextEncoding.utf8
        var lineEnding = LineEnding.lf
        var hasByteOrderMark = false
    }

    private let registrar = ObservationRegistrar()

    private var values = Values()

    private let receiver = StorageReceiver()

    /// The text the buffer was made with, until the host has it.
    private var initial: String?

    /// Whether the host's reports are of the buffer's own first text,
    /// which nothing has seen differently.
    private var isStarting = false

    private var made: (any TextStorage)?

    private var cachedIdentifier: Int32?

    #if !EMBEDDED_NO_CONCURRENCY
    private let subscribers = EventSubscribers<TextEdit, Never>()
    #endif

    private var storage: any TextStorage {
        if let made {
            return made
        }
        receiver.buffer = Unmanaged.passUnretained(self)
        let storage = TextStorageProxy.make(receiver)
        made = storage
        if let initial, !initial.isEmpty {
            // This may be a view's first use of the buffer, in the middle
            // of an update: what the host says back changes nothing a view
            // has read, so it's taken in without telling them.
            isStarting = true
            storage.setText(initial)
            isStarting = false
        }
        initial = nil
        return storage
    }

    private func mutate(_ index: Int, _ change: () -> Void) {
        registrar.withMutation(of: self, propertyIndex: index, change)
    }

    // MARK: From the host

    fileprivate func edited(location: Int32, removed: Int32, inserted: Int32, length: Int32) {
        let length = Int(max(length, 0))
        guard !isStarting else {
            values.length = length
            return
        }
        if length != values.length {
            mutate(0) { values.length = length }
        }
        // The text itself.
        mutate(7) { }
        let start = Int(max(location, 0))
        let edit = TextEdit(range: start ..< start + Int(max(removed, 0)), insertedLength: Int(max(inserted, 0)))
        onEdit?(edit)
        #if !EMBEDDED_NO_CONCURRENCY
        subscribers.yield(edit)
        #endif
    }

    fileprivate func changed(selection location: Int32, length: Int32) {
        let start = Int(max(location, 0))
        let selection = start ..< start + Int(max(length, 0))
        guard selection != values.selection else { return }
        guard !isStarting else {
            values.selection = selection
            return
        }
        mutate(1) { values.selection = selection }
        onSelectionChange?(selection)
    }

    fileprivate func changed(modified: Bool) {
        guard modified != values.isModified else { return }
        if isStarting {
            values.isModified = modified
        } else {
            mutate(2) { values.isModified = modified }
        }
    }

    fileprivate func changed(canUndo: Bool, canRedo: Bool) {
        if isStarting {
            values.canUndo = canUndo
            values.canRedo = canRedo
            return
        }
        if canUndo != values.canUndo {
            mutate(3) { values.canUndo = canUndo }
        }
        if canRedo != values.canRedo {
            mutate(4) { values.canRedo = canRedo }
        }
    }

    fileprivate func finishedLoad(_ outcome: Outcome) {
        if case .loaded(let encoding, let lineEnding, let byteOrderMark) = outcome {
            mutate(6) {
                values.encoding = encoding
                values.lineEnding = lineEnding
                values.hasByteOrderMark = byteOrderMark
            }
        }
        values.loads = max(values.loads - 1, 0)
        if values.loads == 0 {
            mutate(5) { }
        }
    }
}

/// The delegate the host holds. It doesn't keep the buffer alive: the
/// buffer owns the host's `TextStorage`, which owns this, and the buffer
/// clears the reference when it's released. Embedded Swift has no weak
/// references.
private final class StorageReceiver: TextStorageDelegate {

    var buffer: Unmanaged<TextBuffer>?

    var current: TextBuffer? {
        buffer?.takeUnretainedValue()
    }

    func didEdit(_ location: Int32, removed: Int32, inserted: Int32, length: Int32) {
        current?.edited(location: location, removed: removed, inserted: inserted, length: length)
    }

    func didChangeSelection(_ location: Int32, length: Int32) {
        current?.changed(selection: location, length: length)
    }

    func didChangeModified(_ modified: Bool) {
        current?.changed(modified: modified)
    }

    func didChangeUndo(_ canUndo: Bool, canRedo: Bool) {
        current?.changed(canUndo: canUndo, canRedo: canRedo)
    }
}

/// What a `TextCallback` was told.
private enum Outcome {

    case complete
    case loaded(TextEncoding, LineEnding, Bool)
    case found(Range<Int>?)
    case replaced(Int)
    case failure(TextError)

    /// The failure, or `unknown` for an answer of the wrong kind.
    var error: TextError {
        if case .failure(let error) = self {
            return error
        }
        return .unknown
    }
}

/// One operation's callback. The host holds it until it answers.
private final class OperationReceiver: TextCallback {

    private var finish: ((Outcome) -> Void)?

    init(_ finish: @escaping (Outcome) -> Void) {
        self.finish = finish
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

    func didLoad(_ encoding: String, lineEnding: Int32, byteOrderMark: Bool) {
        // A line ending from a newer host is written as `\n`.
        answer(.loaded(TextEncoding(rawValue: encoding), LineEnding(rawValue: lineEnding) ?? .lf, byteOrderMark))
    }

    func didFind(_ location: Int32, length: Int32) {
        guard location >= 0, length >= 0 else {
            answer(.found(nil))
            return
        }
        answer(.found(Int(location) ..< Int(location) + Int(length)))
    }

    func didReplace(_ count: Int32) {
        answer(.replaced(Int(max(count, 0))))
    }

    func didFail(_ code: Int32, file: Int32) {
        answer(.failure(TextError(code: code, file: file)))
    }
}
