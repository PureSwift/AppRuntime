import RuntimeABI
import RuntimeCore
import WasmKit

/// A wasm32 guest instance, called back through its `rt_dispatch` and
/// `rt_finalize` exports.
///
/// Arguments and results travel through a block of linear memory obtained
/// from the guest's `rt_alloc` export and returned with `rt_free`
/// (`rt_guest.h`).
public final class WasmGuest: Guest {

    public var capabilities: Set<Capability>?

    /// Set once the module is instantiated.
    public internal(set) var instance: Instance?

    /// The last trap raised while the runtime called into the guest.
    public internal(set) var lastTrap: Error?

    public init(capabilities: Set<Capability>? = nil) {
        self.capabilities = capabilities
    }

    public func dispatch(
        context: ContextID,
        index: UInt32,
        target: ObjectHandle,
        arguments: UnsafeBufferPointer<Slot>,
        results: UnsafeMutableBufferPointer<Slot>
    ) -> RuntimeStatus {
        do {
            return try dispatchThrowing(context: context, index: index, target: target, arguments: arguments, results: results)
        } catch {
            lastTrap = error
            return .thrown
        }
    }

    private func dispatchThrowing(
        context: ContextID,
        index: UInt32,
        target: ObjectHandle,
        arguments: UnsafeBufferPointer<Slot>,
        results: UnsafeMutableBufferPointer<Slot>
    ) throws -> RuntimeStatus {
        guard let instance,
              let dispatch = instance.exports[function: "rt_dispatch"],
              let allocate = instance.exports[function: "rt_alloc"],
              let free = instance.exports[function: "rt_free"],
              let memory = instance.exports[memory: "memory"] else {
            throw WasmRuntimeError("guest lacks rt_dispatch, rt_alloc, rt_free or memory exports")
        }
        let slotCount = arguments.count + results.count
        let block = try allocate([.i32(UInt32(max(slotCount, 1) * 8))]).first?.i32 ?? 0
        guard block != 0 else {
            throw WasmRuntimeError("rt_alloc failed")
        }
        defer { _ = try? free([.i32(block)]) }
        let argumentsOffset = block
        let resultsOffset = block + UInt32(arguments.count * 8)
        try GuestMemory(memory).writeSlots(Array(arguments), at: argumentsOffset)
        try GuestMemory(memory).writeSlots([Slot](repeating: 0, count: results.count), at: resultsOffset)
        let status = try dispatch([
            .i32(context),
            .i32(index),
            .i32(target),
            .i32(argumentsOffset),
            .i32(UInt32(arguments.count)),
            .i32(resultsOffset),
            .i32(UInt32(results.count)),
        ]).first?.i32 ?? RuntimeStatus.thrown.rawValue
        // The guest may have grown its memory; read back through the export.
        let returned = try GuestMemory(memory).readSlots(resultsOffset, count: UInt32(results.count))
        for (index, slot) in returned.enumerated() {
            results[index] = slot
        }
        return RuntimeStatus(code: status)
    }

    public func finalize(context: ContextID) {
        guard let finalize = instance?.exports[function: "rt_finalize"] else { return }
        do {
            _ = try finalize([.i32(context)])
        } catch {
            lastTrap = error
        }
    }
}
