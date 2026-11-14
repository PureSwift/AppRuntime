import DynamicRuntime
import RuntimeABI
import RuntimeHost
import Testing

/// The startup checks: the rt ABI and the contracts the app uses.
@Suite struct AppCompatibilityTests {

    enum Things: HostModule {

        static let thing = ContractDescriptor(name: "org.example.Thing", kind: .contract, version: 2, methods: [])

        static let thingDelegate = ContractDescriptor(name: "org.example.ThingDelegate", kind: .callback, methods: [])

        static var contracts: [ContractDescriptor] {
            [thing, thingDelegate]
        }

        static func register(in registrar: some ContractRegistrar) {
            registrar.register(thing, statics: nil)
            registrar.register(thingDelegate, statics: nil)
        }
    }

    let provided = AppCompatibility.providedContracts([Things.self])

    func app(_ contracts: [AppInfo.Contract], abiVersion: UInt32 = runtimeABIVersion) -> AppInfo {
        AppInfo(identifier: "org.example.App", abiVersion: abiVersion, contracts: contracts)
    }

    @Test func providesTheBuiltinsAndTheModules() {
        #expect(provided["org.example.Thing"] == Things.thing)
        #expect(provided["org.example.ThingDelegate"] == Things.thingDelegate)
        for builtin in BuiltinContracts.all {
            #expect(provided[builtin.name] == builtin)
        }
        #expect(Things.isUsed(by: ["org.example.Thing"]))
        #expect(!Things.isUsed(by: ["org.example.Other"]))
    }

    @Test func passesAnAppThatFits() throws {
        let warnings = try AppCompatibility.check(app([
            .init(name: "org.example.Thing", version: 2, kind: .contract),
            .init(name: "org.example.ThingDelegate", version: 1, kind: .callback),
        ]), provided: provided)
        #expect(warnings.isEmpty)
    }

    @Test func refusesANewerABI() {
        #expect(throws: AppHostError.incompatible("the app needs rt ABI 3; this host provides 2")) {
            try AppCompatibility.check(app([], abiVersion: 3), provided: provided, abiVersion: 2)
        }
    }

    @Test func refusesMissingContractsAndWrongKinds() {
        let expected = AppHostError.incompatible(
            "org.example.Missing isn't implemented by this host; "
                + "org.example.ThingDelegate is a different kind of interface on this host"
        )
        #expect(throws: expected) {
            try AppCompatibility.check(app([
                .init(name: "org.example.Missing", version: 1, kind: .contract),
                .init(name: "org.example.ThingDelegate", version: 1, kind: .contract),
            ]), provided: provided)
        }
    }

    @Test func warnsAboutOlderContracts() throws {
        let warnings = try AppCompatibility.check(app([
            .init(name: "org.example.Thing", version: 3, kind: .contract),
        ]), provided: provided)
        #expect(warnings == ["org.example.Thing is version 2 on this host; the app was built against 3"])
    }
}
