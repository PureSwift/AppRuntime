import RuntimeABI

/// The runtime core (§2): handle table, contract registry, marshaling
/// checks and the Swift-registry backend.
///
/// One instance serves every guest in a process. Native slices reach it
/// through the `rt_*` C symbols (`RuntimeNative`); wasm guests reach it
/// through an import shim (`RuntimeWasm`). Calls are single-threaded (§6.4).
///
/// Re-entrancy: implementations and guests may call back into the runtime
/// from inside a call. The runtime never holds a mutation of its own state
/// across a call out, and objects are only destroyed after the table update
/// that released them has finished.
public final class HostRuntime {

    // MARK: State

    private var classes: [ClassEntry] = []

    private var classIDs: [String: ClassID] = [:]

    private var methods: [MethodEntry] = []

    private var methodIDs: [MethodKey: MethodID] = [:]

    private var objects: [ObjectHandle: HandleEntry] = [:]

    private var nextHandle: ObjectHandle = 1

    private var lastError: [UInt8]?

    private var listClass: ClassID = 0

    private var stringClass: ClassID = 0

    private var bytesClass: ClassID = 0

    public init() {
        listClass = register(BuiltinContracts.list)
        stringClass = register(BuiltinContracts.string)
        bytesClass = register(BuiltinContracts.bytes)
    }

    // MARK: Registry

    /// Registers a contract or callback interface. `statics` implements its
    /// static and constructor methods (Swift-registry backend). Registering
    /// a name again replaces its descriptor and implementation and keeps its
    /// class ID.
    @discardableResult
    public func register(_ descriptor: ContractDescriptor, statics: StaticImplementation? = nil) -> ClassID {
        let entry = ClassEntry(descriptor: descriptor, statics: statics)
        if let id = classIDs[descriptor.name] {
            classes[Int(id) - 1] = entry
            return id
        }
        classes.append(entry)
        let id = ClassID(classes.count)
        classIDs[descriptor.name] = id
        return id
    }

    /// The registered descriptor for a contract name.
    public func descriptor(named name: String) -> ContractDescriptor? {
        classIDs[name].map { classes[Int($0) - 1].descriptor }
    }

    /// Every registered descriptor.
    public var registeredContracts: [ContractDescriptor] {
        classes.map { $0.descriptor }
    }

    // MARK: rt_class / rt_method

    /// `rt_class`. Returns `0` if the name is unknown or `guest` lacks the
    /// contract's capability.
    public func lookupClass<C: Collection>(_ name: C, guest: Guest?) -> ClassID where C.Element == UInt8 {
        let name = String(decoding: name, as: UTF8.self)
        guard let id = classIDs[name] else { return 0 }
        if let capability = classes[Int(id) - 1].descriptor.capability,
           let granted = guest?.capabilities,
           !granted.contains(capability) {
            return 0
        }
        return id
    }

    /// `rt_method`. Returns `0` if the class lacks the method, or the wire
    /// signature or kind doesn't match.
    public func lookupMethod<K: Collection, S: Collection>(
        _ cls: ClassID,
        key: K,
        signature: S,
        flags: UInt32
    ) -> MethodID where K.Element == UInt8, S.Element == UInt8 {
        guard let entry = classEntry(cls),
              let kind = MethodKind(rawValue: flags),
              let signature = Signature(utf8: signature) else {
            return 0
        }
        let key = String(decoding: key, as: UTF8.self)
        guard let method = entry.descriptor.method(key: key, kind: kind),
              method.signature == signature else {
            return 0
        }
        let methodKey = MethodKey(cls: cls, kind: kind, key: key)
        if let id = methodIDs[methodKey] {
            return id
        }
        methods.append(MethodEntry(cls: cls, key: key, kind: kind, signature: signature))
        let id = MethodID(methods.count)
        methodIDs[methodKey] = id
        return id
    }

    // MARK: rt_call

    /// `rt_call`. Object arguments are borrowed; object results are +1.
    public func call(
        target: ObjectHandle,
        method: MethodID,
        arguments: UnsafeBufferPointer<Slot>,
        results: UnsafeMutableBufferPointer<Slot>
    ) -> RuntimeStatus {
        guard let method = methodEntry(method) else {
            return fail(.notFound, "invalid method")
        }
        guard arguments.count == method.signature.arguments.count,
              results.count >= method.signature.resultSlotCount else {
            return fail(.signature, "\(method.key): expected \(method.signature.arguments.count) argument slot(s)")
        }
        let results = UnsafeMutableBufferPointer(rebasing: results[0..<method.signature.resultSlotCount])
        switch method.kind {
        case .static, .constructor:
            return callStatic(method, arguments: arguments, results: results)
        case .instance:
            guard target != 0 else {
                return fail(.null, "\(method.key) sent to null")
            }
            guard let object = objects[target]?.object else {
                return fail(.null, "\(method.key) sent to an invalid handle")
            }
            return callInstance(method, on: object, target: target, arguments: arguments, results: results)
        }
    }

    private func callStatic(
        _ method: MethodEntry,
        arguments: UnsafeBufferPointer<Slot>,
        results: UnsafeMutableBufferPointer<Slot>
    ) -> RuntimeStatus {
        if method.cls == listClass {
            // make: a new, empty list.
            results[0] = Slot(handle: insert(HostObject(.list(ListStorage()))))
            return .ok
        }
        guard let entry = classEntry(method.cls),
              let statics = entry.statics,
              let index = entry.descriptor.staticMethods.firstIndex(where: { $0.key == method.key && $0.kind == method.kind }) else {
            return fail(.notFound, "\(method.key) has no implementation")
        }
        do throws(RuntimeError) {
            try statics(UInt32(index), arguments, results)
            return .ok
        } catch {
            return fail(error.status, error.message)
        }
    }

    private func callInstance(
        _ method: MethodEntry,
        on object: HostObject,
        target: ObjectHandle,
        arguments: UnsafeBufferPointer<Slot>,
        results: UnsafeMutableBufferPointer<Slot>
    ) -> RuntimeStatus {
        switch object.storage {
        case .list(let list) where method.cls == listClass:
            return callList(list, key: method.key, arguments: arguments, results: results)
        case .implemented(let implementation):
            guard implementation.interfaces.contains(method.cls),
                  let index = implementation.index(key: method.key, signature: method.signature) else {
                return fail(.notFound, "\(method.key) isn't implemented by this object")
            }
            lastError = nil
            let status = implementation.guest.dispatch(
                context: implementation.context,
                index: index,
                target: target,
                arguments: arguments,
                results: results
            )
            if status == .thrown, lastError == nil {
                lastError = Array("\(method.key) threw".utf8)
            }
            return status
        default:
            return fail(.notFound, "\(method.key) isn't a method of this object")
        }
    }

    private func callList(
        _ list: ListStorage,
        key: String,
        arguments: UnsafeBufferPointer<Slot>,
        results: UnsafeMutableBufferPointer<Slot>
    ) -> RuntimeStatus {
        switch key {
        case "count":
            results[0] = Int32(truncatingIfNeeded: list.elements.count).slot
        case "objectAt:":
            let index = Int(Int32(slot: arguments[0]))
            guard list.elements.indices.contains(index) else {
                return fail(.thrown, "List index \(index) out of range")
            }
            results[0] = Slot(handle: list.elements[index].map(insert) ?? 0)
        case "append:":
            let handle = arguments[0].handle
            list.elements.append(handle == 0 ? nil : objects[handle]?.object)
        default:
            return fail(.notFound, "List has no method \(key)")
        }
        return .ok
    }

    // MARK: Handles

    /// `rt_retain`.
    public func retain(_ handle: ObjectHandle) {
        objects[handle]?.count += 1
    }

    /// `rt_release`. The object is destroyed (and an `rt_implement` object
    /// finalized) when nothing references it anymore.
    public func release(_ handle: ObjectHandle) {
        guard var entry = objects[handle] else { return }
        entry.count -= 1
        if entry.count > 0 {
            objects[handle] = entry
            return
        }
        // Finish the table update before the object can die: its deinit may
        // call into the guest, which may call back into the runtime.
        let removed = objects.removeValue(forKey: handle)
        withExtendedLifetime(removed) { }
    }

    /// `rt_same`.
    public func same(_ a: ObjectHandle, _ b: ObjectHandle) -> Bool {
        if a == b { return true }
        guard let first = objects[a]?.object, let second = objects[b]?.object else {
            return false
        }
        if first === second { return true }
        if let x = first.implementation, let y = second.implementation {
            return x.guest === y.guest && x.context == y.context
        }
        return false
    }

    /// `rt_is_instance`.
    public func isInstance(_ handle: ObjectHandle, of cls: ClassID) -> Bool {
        guard let object = objects[handle]?.object else { return false }
        switch object.storage {
        case .string: return cls == stringClass
        case .bytes: return cls == bytesClass
        case .list: return cls == listClass
        case .implemented(let implementation): return implementation.interfaces.contains(cls)
        }
    }

    /// The object behind a handle.
    public func object(for handle: ObjectHandle) -> HostObject? {
        objects[handle]?.object
    }

    /// Number of live handles. Useful for leak checks.
    public var handleCount: Int {
        objects.count
    }

    /// Puts an object in the table and returns a new +1 handle.
    @discardableResult
    public func insert(_ object: HostObject) -> ObjectHandle {
        while nextHandle == 0 || objects[nextHandle] != nil {
            nextHandle &+= 1
        }
        let handle = nextHandle
        nextHandle &+= 1
        objects[handle] = HandleEntry(object: object, count: 1)
        return handle
    }

    // MARK: Strings and bytes

    /// `rt_string_new`. Returns a +1 handle.
    public func makeString<C: Collection>(utf8: C) -> ObjectHandle where C.Element == UInt8 {
        insert(HostObject(.string(Array(utf8))))
    }

    /// `rt_string_new` from a Swift string.
    public func makeString(_ string: String) -> ObjectHandle {
        makeString(utf8: string.utf8)
    }

    /// Contents of a string object, for `rt_string_utf8`.
    public func stringUTF8(_ handle: ObjectHandle) -> [UInt8]? {
        guard case .string(let bytes)? = objects[handle]?.object.storage else { return nil }
        return bytes
    }

    /// `rt_bytes_new`. Returns a +1 handle.
    public func makeBytes<C: Collection>(_ bytes: C) -> ObjectHandle where C.Element == UInt8 {
        insert(HostObject(.bytes(Array(bytes))))
    }

    /// Contents of a byte buffer, for `rt_bytes_read`.
    public func bytes(_ handle: ObjectHandle) -> [UInt8]? {
        guard case .bytes(let bytes)? = objects[handle]?.object.storage else { return nil }
        return bytes
    }

    /// Creates a `List` holding the objects behind `handles` (borrowed).
    public func makeList(_ handles: [ObjectHandle]) -> ObjectHandle {
        let list = ListStorage()
        list.elements = handles.map { $0 == 0 ? nil : objects[$0]?.object }
        return insert(HostObject(.list(list)))
    }

    // MARK: rt_implement

    /// `rt_implement`. Returns a +1 handle, or `0` if an interface is
    /// unknown or a declaration's signature is malformed.
    public func implement(
        interfaces: [ClassID],
        methods: [(key: [UInt8], signature: [UInt8])],
        context: ContextID,
        guest: Guest
    ) -> ObjectHandle {
        guard !interfaces.isEmpty, interfaces.allSatisfy({ classEntry($0) != nil }) else {
            _ = fail(.notFound, "rt_implement: unknown interface")
            return 0
        }
        var declarations = [(key: String, signature: Signature)]()
        for method in methods {
            guard let signature = Signature(utf8: method.signature) else {
                _ = fail(.signature, "rt_implement: malformed signature")
                return 0
            }
            declarations.append((String(decoding: method.key, as: UTF8.self), signature))
        }
        let implementation = Implementation(
            guest: guest,
            context: context,
            interfaces: interfaces,
            methods: declarations
        )
        return insert(HostObject(.implemented(implementation)))
    }

    // MARK: Errors

    /// `rt_error_message`. A query with `capacity == 0` leaves the message in
    /// place so the caller can size its buffer; any other read clears it.
    public func errorMessage(capacity: Int) -> [UInt8] {
        let message = lastError ?? []
        if capacity > 0 {
            lastError = nil
        }
        return message
    }

    /// Records the message for the next `rt_error_message`.
    public func setError(_ message: String) {
        lastError = Array(message.utf8)
    }

    private func fail(_ status: RuntimeStatus, _ message: String) -> RuntimeStatus {
        lastError = Array(message.utf8)
        return status
    }

    // MARK: Lookup helpers

    private func classEntry(_ id: ClassID) -> ClassEntry? {
        guard id > 0, Int(id) <= classes.count else { return nil }
        return classes[Int(id) - 1]
    }

    private func methodEntry(_ id: MethodID) -> MethodEntry? {
        guard id > 0, Int(id) <= methods.count else { return nil }
        return methods[Int(id) - 1]
    }
}

// MARK: - Entries

private struct ClassEntry {
    let descriptor: ContractDescriptor
    let statics: StaticImplementation?
}

private struct MethodEntry {
    let cls: ClassID
    let key: String
    let kind: MethodKind
    let signature: Signature
}

private struct MethodKey: Hashable {
    let cls: ClassID
    let kind: MethodKind
    let key: String
}

private struct HandleEntry {
    let object: HostObject
    var count: Int
}
