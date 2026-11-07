import RuntimeABI
import RuntimeCore
import WasmKit
import WasmKitWASI

/// Loads and runs an app's wasm32 slice: a WASI reactor module (§7.5).
///
/// The host owns the run loop. `start()` calls `_initialize` and then
/// `rt_main` once; afterwards the guest runs only when the runtime calls
/// `rt_dispatch`.
public final class WasmApp {

    public let module: Module

    public let runtime: HostRuntime

    public let guest: WasmGuest

    public let instance: Instance

    public let store: Store

    /// The WASI preview 1 implementation, closed when the app is released.
    public let wasi: WASIBridgeToHost

    /// - Parameters:
    ///   - bytes: The `App.wasm` module.
    ///   - runtime: The runtime core. Share `NativeRuntime.shared.runtime`
    ///     so host Swift objects and guest objects use one handle table.
    ///   - capabilities: Capabilities from the app's manifest; `nil` is
    ///     unrestricted.
    ///   - wasi: WASI preview 1 implementation; defaults to no arguments,
    ///     environment or preopens.
    public init(
        bytes: [UInt8],
        runtime: HostRuntime,
        capabilities: Set<Capability>? = nil,
        wasi: WASIBridgeToHost? = nil
    ) throws {
        let module = try parseWasm(bytes: bytes)
        let engine = Engine()
        let store = Store(engine: engine)
        let guest = WasmGuest(capabilities: capabilities)
        var imports = Imports()
        let wasi = try wasi ?? WASIBridgeToHost(args: [], environment: [:], preopens: [WASIBridgeToHost.Preopen]())
        wasi.link(to: &imports, store: store)
        WasmImports.define(in: &imports, store: store, runtime: runtime, guest: guest)
        let instance = try module.instantiate(store: store, imports: imports)
        guest.instance = instance
        self.module = module
        self.runtime = runtime
        self.guest = guest
        self.instance = instance
        self.store = store
        self.wasi = wasi
    }

    deinit {
        try? wasi.close()
    }

    /// Calls `_initialize` (if exported), then `rt_main`.
    @discardableResult
    public func start() throws -> RuntimeStatus {
        if let initialize = instance.exports[function: "_initialize"] {
            _ = try initialize()
        }
        guard let main = instance.exports[function: "rt_main"] else {
            throw WasmRuntimeError("guest has no rt_main export")
        }
        let status = try main().first?.i32 ?? RuntimeStatus.thrown.rawValue
        if let trap = guest.lastTrap {
            throw trap
        }
        return RuntimeStatus(code: status)
    }

    // MARK: Metadata

    /// The `rt.abi` custom section: the ABI version the module was built
    /// against.
    public static func abiVersion(of module: Module) -> UInt32? {
        guard let section = module.customSections.first(where: { $0.name == "rt.abi" }),
              section.bytes.count >= 4 else {
            return nil
        }
        let bytes = Array(section.bytes.prefix(4))
        return UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
    }

    /// The `rt.contracts` custom section, if the packager added one.
    public static func contracts(of module: Module) -> [ContractDescriptor]? {
        guard let section = module.customSections.first(where: { $0.name == "rt.contracts" }) else {
            return nil
        }
        return ContractMetadata.decode(section.bytes)
    }

    /// Load-time validation against `runtime` (§10). A module without an
    /// `rt.contracts` section is only checked for its ABI version.
    public static func validate(
        _ module: Module,
        runtime: HostRuntime,
        capabilities: Set<Capability>?
    ) -> [ValidationIssue] {
        guard let abiVersion = abiVersion(of: module) else {
            return [ValidationIssue(.error, "module has no rt.abi section")]
        }
        return runtime.validate(
            abiVersion: abiVersion,
            contracts: contracts(of: module) ?? [],
            capabilities: capabilities
        )
    }
}
