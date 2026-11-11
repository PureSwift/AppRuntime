import CRuntime
import RuntimeABI

/// Handles one incoming call to an exported object: `index` is the position
/// among the interface's instance methods.
public typealias DispatchFunction = (
    _ index: UInt32,
    _ target: ObjectHandle,
    _ arguments: inout Arguments,
    _ results: ResultWriter
) throws(RuntimeError) -> Void

/// Swift objects exported to the host with `rt_implement`.
///
/// Each export gets a context ID; the host passes it back through
/// `rt_dispatch` and `rt_finalize`. Exporting the same Swift object as the
/// same interface again reuses its context, so `rt_same` can recognize it.
/// The registry keeps the Swift object alive until every native object made
/// for it has been finalized.
public enum Exported {

    /// Exports `object` as a native object implementing `interface`.
    /// Returns a +1 handle, or `0` if the host refused.
    public static func implement(
        _ object: AnyObject,
        interface: ClassReference,
        descriptor: ContractDescriptor,
        dispatch: @escaping DispatchFunction
    ) -> ObjectHandle {
        let context: ContextID
        if let existing = existingContext(for: object, interface: descriptor.name) {
            context = existing
        } else {
            context = nextExportContext
            nextExportContext &+= 1
            exportEntries[context] = ExportEntry(object: object, interface: descriptor.name, dispatch: dispatch)
        }
        let handle = implement(
            interfaces: [interface.id],
            methods: descriptor.instanceMethods,
            context: context
        )
        if handle != 0 {
            exportEntries[context]?.nativeCount += 1
        } else if exportEntries[context]?.nativeCount == 0 {
            remove(context)
        }
        return handle
    }

    /// Number of contexts the host still holds.
    public static var liveCount: Int {
        exportEntries.count
    }

    /// The message of the last error an exported object threw, cleared on
    /// read. rt.h has no way for a guest to report a message, so only a host
    /// in the same process (native mode) can pick it up.
    public static func takeDispatchErrorMessage() -> String? {
        defer { lastDispatchError = nil }
        return lastDispatchError
    }

    /// The Swift object behind an exported context, if it is still alive.
    public static func object(for context: ContextID) -> AnyObject? {
        exportEntries[context]?.object
    }

    /// Identity scan with `===`: hashing an `AnyObject` needs generic code
    /// that Embedded Swift can't specialize. Live exports are few.
    private static func existingContext(for object: AnyObject, interface: String) -> ContextID? {
        for (context, entry) in exportEntries where entry.object === object && entry.interface == interface {
            return context
        }
        return nil
    }

    // MARK: rt_implement

    private static func implement(
        interfaces: [ClassID],
        methods: [MethodDescriptor],
        context: ContextID
    ) -> ObjectHandle {
        guard !interfaces.contains(0) else { return 0 }
        // One buffer holds every key and signature, so the declarations can
        // point into it for the duration of the call.
        var strings = [UInt8]()
        var ranges = [(key: Range<Int>, signature: Range<Int>)]()
        for method in methods {
            let keyStart = strings.count
            strings.append(contentsOf: method.key.utf8)
            let signatureStart = strings.count
            strings.append(contentsOf: method.signature.utf8)
            ranges.append((keyStart..<signatureStart, signatureStart..<strings.count))
        }
        return strings.withUnsafeBufferPointer { buffer in
            let base = buffer.cString
            var declarations = ranges.map { range in
                rt_method_decl(
                    name: base.map { $0 + range.key.lowerBound },
                    name_len: range.key.count,
                    sig: base.map { $0 + range.signature.lowerBound },
                    sig_len: range.signature.count
                )
            }
            return interfaces.withUnsafeBufferPointer { interfaces in
                declarations.withUnsafeMutableBufferPointer { declarations in
                    rt_implement(
                        interfaces.baseAddress,
                        UInt32(truncatingIfNeeded: interfaces.count),
                        declarations.baseAddress,
                        UInt32(truncatingIfNeeded: declarations.count),
                        context
                    )
                }
            }
        }
    }

    // MARK: rt_dispatch / rt_finalize

    static func dispatch(
        context: ContextID,
        index: UInt32,
        target: ObjectHandle,
        arguments: UnsafePointer<Slot>?,
        argumentCount: UInt32,
        results: UnsafeMutablePointer<Slot>?,
        resultCount: UInt32
    ) -> RuntimeStatus {
        guard let dispatch = exportEntries[context]?.dispatch else {
            return .notFound
        }
        var arguments = Arguments(arguments, count: Int(argumentCount))
        let results = ResultWriter(results, count: Int(resultCount))
        do throws(RuntimeError) {
            try dispatch(index, target, &arguments, results)
            return .ok
        } catch {
            lastDispatchError = error.message
            return error.status
        }
    }

    static func finalize(context: ContextID) {
        guard let entry = exportEntries[context] else { return }
        entry.nativeCount -= 1
        if entry.nativeCount <= 0 {
            remove(context)
        }
    }

    private static func remove(_ context: ContextID) {
        // Take the entry out first: releasing the Swift object may re-enter
        // the runtime.
        let entry = exportEntries.removeValue(forKey: context)
        withExtendedLifetime(entry) { }
    }
}

private final class ExportEntry {

    let object: AnyObject

    let interface: String

    let dispatch: DispatchFunction

    var nativeCount = 0

    init(object: AnyObject, interface: String, dispatch: @escaping DispatchFunction) {
        self.object = object
        self.interface = interface
        self.dispatch = dispatch
    }
}

// Single-threaded by contract (§6.4).
nonisolated(unsafe) private var exportEntries = [ContextID: ExportEntry]()
nonisolated(unsafe) private var nextExportContext: ContextID = 1
nonisolated(unsafe) private var lastDispatchError: String?

// MARK: - Guest exports

/// `rt_dispatch`: a native caller invoked a method of an exported object.
@_expose(wasm, "rt_dispatch")
@c(rt_dispatch)
public func _rt_dispatch(
    _ context: UInt32,
    _ index: UInt32,
    _ target: rt_obj,
    _ arguments: UnsafePointer<rt_slot>?,
    _ argumentCount: UInt32,
    _ results: UnsafeMutablePointer<rt_slot>?,
    _ resultCount: UInt32
) -> rt_status {
    // Async work the call started runs before control returns to the host.
    let status = GuestExecutor.enter {
        Exported.dispatch(
            context: context,
            index: index,
            target: target,
            arguments: arguments,
            argumentCount: argumentCount,
            results: results,
            resultCount: resultCount
        )
    }
    return rt_status(rawValue: status.rawValue)
}

/// `rt_finalize`: the native object for `context` was destroyed.
@_expose(wasm, "rt_finalize")
@c(rt_finalize)
public func _rt_finalize(_ context: UInt32) {
    GuestExecutor.enter {
        Exported.finalize(context: context)
    }
}
