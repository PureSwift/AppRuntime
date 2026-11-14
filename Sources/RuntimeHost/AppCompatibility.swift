import DynamicRuntime
import RuntimeABI

/// The startup checks every host makes (§7.6): the app's rt ABI and the
/// contracts it uses against what this host has.
///
/// A packager makes the same checks, so a failure at startup means a corrupt
/// or tampered app.
public enum AppCompatibility {

    /// Every contract and callback interface a host with `modules` can
    /// register: the built-ins and the modules' contracts.
    public static func providedContracts(_ modules: [any HostModule.Type]) -> [String: ContractDescriptor] {
        var provided = [String: ContractDescriptor]()
        for descriptor in BuiltinContracts.all + modules.flatMap({ $0.contracts }) {
            provided[descriptor.name] = descriptor
        }
        return provided
    }

    /// Checks `info` against `provided`. Throws if the app needs more than
    /// the host has; returns warnings for what it can live without, such as
    /// a contract the host implements at a lower version.
    public static func check(
        _ info: AppInfo,
        provided: [String: ContractDescriptor],
        abiVersion: UInt32 = runtimeABIVersion
    ) throws(AppHostError) -> [String] {
        if info.abiVersion > abiVersion {
            throw .incompatible("the app needs rt ABI \(info.abiVersion); this host provides \(abiVersion)")
        }
        var problems = [String]()
        var warnings = [String]()
        for contract in info.contracts {
            guard let descriptor = provided[contract.name] else {
                problems.append("\(contract.name) isn't implemented by this host")
                continue
            }
            if descriptor.kind != contract.kind {
                problems.append("\(contract.name) is a different kind of interface on this host")
            } else if descriptor.version < contract.version {
                // Methods added later resolve as absent; the guest checks.
                warnings.append("\(contract.name) is version \(descriptor.version) on this host; the app was built against \(contract.version)")
            }
        }
        if !problems.isEmpty {
            throw .incompatible(problems.joined(separator: "; "))
        }
        return warnings
    }
}

/// Why the host can't run an app.
public enum AppHostError: Error, Equatable, CustomStringConvertible {

    case incompatible(String)

    public var description: String {
        switch self {
        case .incompatible(let reason): "This app can't run on this host: \(reason)"
        }
    }
}
