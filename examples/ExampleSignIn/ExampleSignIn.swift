import DynamicRuntime
import DynamicAuthentication
import DynamicSecrets
// Guest builds call the frontend `SwiftUI`; host builds of this package
// can't, since Apple's SDK has one. A guest package just says `import SwiftUI`.
#if canImport(DynamicSwiftUI)
import DynamicSwiftUI
#else
import SwiftUI
#endif

/// The example sign-in app: an account with a provider. It asks the host
/// for its redirect, shows the provider's page in the system's browser,
/// checks that the reply is to its own request, keeps what it was given in
/// the keychain, and signs out by removing it.

/// The closures hold the account, which lives as long as the app does:
/// Embedded Swift has no weak or unowned references. The guest is
/// single-threaded (§6.4), which the compiler can't see.
@Observable
final class Account: @unchecked Sendable {

    var status: String = "Checking"

    var isSignedIn: Bool = false

    /// A page is showing.
    var isSigningIn: Bool = false

    @ObservationIgnored let keychain = Keychain.default

    @ObservationIgnored let session = WebAuthenticationSession()

    /// What this request's reply must carry back.
    @ObservationIgnored var state = ""

    /// The scheme the manifest declares, and the key the token is kept by.
    static let scheme = "org.pureswift.example.signin"

    static let tokenKey = "account.token"

    /// Whether the app was left signed in.
    func start() {
        keychain.string(forKey: Self.tokenKey) { result in
            switch result {
            case .success(let token):
                self.isSignedIn = token != nil
                self.status = token == nil ? "Signed out" : "Signed in"
            case .failure(let error):
                self.report(error)
            }
        }
    }

    func signIn(privately: Bool) {
        // Ask the host: a scheme of the app's own on a native host, a page
        // in a browser. The provider is told the same.
        let redirect = session.redirectURL(scheme: Self.scheme, path: "oauth")
        state = String(UInt64.random(in: .min ... .max), radix: 16)
        let url = "https://id.example.com/authorize?response_type=code&client_id=example"
            + "&redirect_uri=" + Self.percentEncoded(redirect) + "&state=" + state
        isSigningIn = true
        status = "Signing in"
        session.authenticate(using: url, redirect: redirect, preferredBrowserSession: privately ? .ephemeral : .shared) { result in
            self.isSigningIn = false
            switch result {
            case .success(let reply):
                self.finish(reply)
            case .failure(.canceledLogin):
                self.status = "Sign-in cancelled"
            case .failure(.busy):
                self.status = "Already signing in"
            case .failure(let error):
                self.status = "Couldn't sign in: error \(error.rawValue)"
            }
        }
    }

    func cancel() {
        session.cancel()
    }

    /// The host returned the redirect as the provider sent it. Checking it
    /// is the app's: the host read none of it.
    func finish(_ reply: String) {
        guard Self.parameter("state", in: reply) == state, !state.isEmpty else {
            status = "The reply didn't match the request"
            return
        }
        guard let code = Self.parameter("code", in: reply), !code.isEmpty else {
            status = "The provider refused"
            return
        }
        // A real app trades the code for tokens over HTTPS first, and
        // keeps the refresh token. A background task reads it while the
        // phone is locked, so it's stored for that.
        keychain.set(code, forKey: Self.tokenKey, accessibility: .afterFirstUnlock) { result in
            switch result {
            case .success:
                self.isSignedIn = true
                self.status = "Signed in"
            case .failure(let error):
                self.report(error)
            }
        }
    }

    func signOut() {
        keychain.removeValue(forKey: Self.tokenKey) { result in
            switch result {
            case .success:
                self.isSignedIn = false
                self.status = "Signed out"
            case .failure(let error):
                self.report(error)
            }
        }
    }

    func report(_ error: KeychainError) {
        switch error {
        case .unavailable: status = "The keychain can't be read now"
        case .notAllowed: status = "The keychain wasn't unlocked"
        default: status = "Keychain error \(error.rawValue)"
        }
    }

    /// A query parameter's value, as it is in the URL.
    static func parameter(_ name: String, in url: String) -> String? {
        guard let query = url.split(separator: "?", maxSplits: 1).dropFirst().first else { return nil }
        let pairs = query.split(separator: "#", maxSplits: 1)[0].split(separator: "&")
        for pair in pairs {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            if parts.count == 2, String(parts[0]) == name {
                return String(parts[1])
            }
        }
        return nil
    }

    /// For a query's value: everything but letters, digits and `-._~`.
    static func percentEncoded(_ string: String) -> String {
        let digits = Array("0123456789ABCDEF".utf8)
        var bytes: [UInt8] = []
        for byte in string.utf8 {
            let isPlain = (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A)
                || byte == 0x2D || byte == 0x2E || byte == 0x5F || byte == 0x7E
            if isPlain {
                bytes.append(byte)
            } else {
                bytes.append(0x25)
                bytes.append(digits[Int(byte >> 4)])
                bytes.append(digits[Int(byte & 0x0F)])
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}

struct ContentView: View {

    let account: Account

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(account.status)
                .accessibilityIdentifier("status")
            Text(account.isSignedIn ? "A token is kept" : "No token")
                .accessibilityIdentifier("token")
            if account.isSigningIn {
                Button("Cancel") { account.cancel() }
            } else if account.isSignedIn {
                Button("Sign Out") { account.signOut() }
            } else {
                Button("Sign In") { account.signIn(privately: false) }
                Button("Sign In Privately") { account.signIn(privately: true) }
            }
        }
        .padding()
    }
}

struct ExampleSignInApp: App {

    let account = Account()

    init() {
        account.start()
    }

    var body: some Scene {
        WindowGroup {
            ContentView(account: account)
        }
    }
}

/// The app's entry point. The host calls it once after loading the slice.
@_expose(wasm, "rt_main")
@c(rt_main)
public func exampleSignInMain() -> rt_status {
    Runtime.main { ExampleSignInApp.run() }
}
