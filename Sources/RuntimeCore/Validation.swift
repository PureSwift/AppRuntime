import RuntimeABI

/// A problem found while checking a slice against this host (§10).
public struct ValidationIssue: Equatable, Hashable, Sendable {

    public enum Severity: Equatable, Hashable, Sendable {
        /// The host refuses to load the slice.
        case error
        /// The slice loads; some functionality is absent.
        case warning
    }

    public let severity: Severity

    /// Contract name, or empty for module-level issues.
    public let contract: String

    public let message: String

    public init(_ severity: Severity, contract: String = "", _ message: String) {
        self.severity = severity
        self.contract = contract
        self.message = message
    }
}

public extension HostRuntime {

    /// Load-time validation of a slice's `rt.abi` and `rt.contracts`
    /// metadata against this host:
    ///
    /// 1. the host's ABI version is at least the module's;
    /// 2. every contract has a registered implementation; one with a lower
    ///    version than the module was built against is a warning, and its
    ///    missing methods resolve to `rt_method == 0`;
    /// 3. every contract's capability is in `capabilities` (`nil` skips the
    ///    check);
    /// 4. wire signatures and method kinds match the registered ones.
    func validate(
        abiVersion: UInt32,
        contracts: [ContractDescriptor],
        capabilities: Set<Capability>?
    ) -> [ValidationIssue] {
        var issues = [ValidationIssue]()
        if abiVersion > runtimeABIVersion {
            issues.append(ValidationIssue(.error, "module needs rt ABI \(abiVersion), host provides \(runtimeABIVersion)"))
        }
        for required in contracts {
            let name = required.name
            if let capability = required.capability, let capabilities, !capabilities.contains(capability) {
                issues.append(ValidationIssue(.error, contract: name, "requires capability '\(capability.rawValue)', which the manifest doesn't declare"))
            }
            guard let provided = descriptor(named: name) else {
                issues.append(ValidationIssue(.error, contract: name, "no implementation registered"))
                continue
            }
            if provided.kind != required.kind {
                issues.append(ValidationIssue(.error, contract: name, "registered as a different kind of interface"))
            }
            if provided.version < required.version {
                issues.append(ValidationIssue(.warning, contract: name, "host implements version \(provided.version), module was built against \(required.version)"))
            }
            for method in required.methods {
                guard let match = provided.methods.first(where: { $0.key == method.key }) else {
                    issues.append(ValidationIssue(.warning, contract: name, "\(method.key) is absent on this host"))
                    continue
                }
                if match.kind != method.kind {
                    issues.append(ValidationIssue(.error, contract: name, "\(method.key) has a different kind on this host"))
                } else if match.signature != method.signature {
                    issues.append(ValidationIssue(.error, contract: name, "\(method.key) is \(match.signature) on this host, module expects \(method.signature)"))
                }
            }
        }
        return issues
    }
}
