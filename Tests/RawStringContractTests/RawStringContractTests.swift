import DynamicRuntime
import RuntimeNative
import Testing

/// A raw string type with a validity rule, like `BluetoothUUID`.
struct Token: RawRepresentable, Equatable {

    let rawValue: String

    init?(rawValue: String) {
        guard rawValue.hasPrefix("tok-") else { return nil }
        self.rawValue = rawValue
    }
}

// The guest's typed view of the contract.

@DynamicRuntime("org.example.Vault")
protocol Vault: AnyObject {
    static func make(_ observer: VaultObserver) -> Self
    func token() throws(RuntimeError) -> Token
    func optionalToken() throws(RuntimeError) -> Token?
    func tokens() throws(RuntimeError) -> [Token]
    func store(_ token: Token)
    func storeAll(_ tokens: [Token]?)
    func notify(_ raw: String) throws(RuntimeError)
}

@DynamicCallback("org.example.VaultObserver")
protocol VaultObserver: AnyObject {
    func didStore(_ token: Token)
}

// The same wire contract as plain strings, so the host can send invalid ones.

@DynamicRuntime("org.example.Vault")
protocol RawVault: AnyObject {
    static func make(_ observer: RawVaultObserver) -> Self
    func token() -> String
    func optionalToken() -> String?
    func tokens() -> [String]
    func store(_ token: String)
    func storeAll(_ tokens: [String]?)
    func notify(_ raw: String) throws(RuntimeError)
}

@DynamicCallback("org.example.VaultObserver")
protocol RawVaultObserver: AnyObject {
    func didStore(_ token: String) throws(RuntimeError)
}

final class HostVault: RawVault {

    let observer: any RawVaultObserver
    var current = ""
    var optionalCurrent: String?
    var currentList: [String] = []
    var stored: [String] = []
    var storedAll: [String]?

    init(observer: any RawVaultObserver) {
        self.observer = observer
    }

    static func make(_ observer: any RawVaultObserver) -> HostVault {
        HostVault(observer: observer)
    }

    func token() -> String { current }
    func optionalToken() -> String? { optionalCurrent }
    func tokens() -> [String] { currentList }
    func store(_ token: String) { stored.append(token) }
    func storeAll(_ tokens: [String]?) { storedAll = tokens }

    func notify(_ raw: String) throws(RuntimeError) {
        try observer.didStore(raw)
    }
}

final class RecordingObserver: VaultObserver {

    var received: [Token] = []

    func didStore(_ token: Token) {
        received.append(token)
    }
}

/// Serialized: every test shares `NativeRuntime.shared`.
@Suite(.serialized) struct RawStringContractTests {

    let invalid = RuntimeError.thrown("Invalid string value: bad")

    init() {
        RawVaultProxy.register(HostVault.self, in: NativeRuntime.shared)
        RawVaultObserverProxy.registerInterface(in: NativeRuntime.shared)
    }

    /// Runs `body` with a vault, then checks no handle outlived it.
    func withVault(
        observer: RecordingObserver = RecordingObserver(),
        _ body: (VaultProxy, HostVault) throws -> Void
    ) throws {
        let handles = NativeRuntime.shared.runtime.handleCount
        try {
            let vault = VaultProxy.make(observer)
            let host = try #require(NativeRuntime.shared.swiftObject(for: vault) as? HostVault)
            try body(vault, host)
        }()
        #expect(NativeRuntime.shared.runtime.handleCount == handles)
    }

    @Test func argumentTravelsAsItsRawValue() throws {
        try withVault { vault, host in
            vault.store(try #require(Token(rawValue: "tok-1")))
            #expect(host.stored == ["tok-1"])
        }
    }

    @Test func validResultDecodes() throws {
        try withVault { vault, host in
            host.current = "tok-2"
            let token = try vault.token()
            #expect(token == Token(rawValue: "tok-2"))
        }
    }

    @Test func invalidResultThrows() throws {
        try withVault { vault, host in
            host.current = "bad"
            #expect(throws: invalid) { _ = try vault.token() }
        }
    }

    @Test func optionalResult() throws {
        try withVault { vault, host in
            let missing = try vault.optionalToken()
            #expect(missing == nil)
            host.optionalCurrent = "tok-3"
            let present = try vault.optionalToken()
            #expect(present == Token(rawValue: "tok-3"))
            host.optionalCurrent = "bad"
            #expect(throws: invalid) { _ = try vault.optionalToken() }
        }
    }

    @Test func arrayResult() throws {
        try withVault { vault, host in
            host.currentList = ["tok-4", "tok-5"]
            let tokens = try vault.tokens()
            #expect(tokens.map(\.rawValue) == ["tok-4", "tok-5"])
        }
    }

    @Test func invalidArrayElementThrowsWithoutLeaking() throws {
        try withVault { vault, host in
            host.currentList = ["tok-6", "bad", "tok-7"]
            #expect(throws: invalid) { _ = try vault.tokens() }
        }
    }

    @Test func optionalArrayArgument() throws {
        try withVault { vault, host in
            vault.storeAll([try #require(Token(rawValue: "tok-8"))])
            #expect(host.storedAll == ["tok-8"])
            vault.storeAll(nil)
            #expect(host.storedAll == nil)
        }
    }

    @Test func callbackReceivesDecodedValue() throws {
        let observer = RecordingObserver()
        try withVault(observer: observer) { vault, _ in
            try vault.notify("tok-9")
        }
        #expect(observer.received.map(\.rawValue) == ["tok-9"])
    }

    @Test func invalidCallbackArgumentFailsTheCall() throws {
        let observer = RecordingObserver()
        try withVault(observer: observer) { vault, _ in
            #expect(throws: invalid) { try vault.notify("bad") }
        }
        #expect(observer.received.isEmpty)
    }
}
