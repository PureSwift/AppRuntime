# Secrets and sign-in

**Status:** implemented in this repository: the guest side of both, and
the part of the host side every host written in Swift shares. No platform
host has a keychain or a browser behind it yet, so no secret has been
kept safely and no provider's page has been shown: the tests keep the
secrets in memory and play the browser.

Two things an app with an account needs, and uses together:

- **Secrets:** a few small values the system keeps encrypted. A refresh
  token, a mail password. `Defaults` and `Files` are not for these.
- **Sign-in:** a web page of the account's provider, shown by the system's
  browser and not the app, which hands the app a redirect when the user
  is done. Gmail and Outlook accept nothing else.

They are two contracts in two modules, so an app that only keeps a
password doesn't ask its host for a browser.

| Contract | Module | iOS / macOS | Android | Linux | Browser |
|---|---|---|---|---|---|
| `Secrets`, `requires: .secrets` | `DynamicSecrets` | Keychain Services | a key in the Android Keystore, and values it encrypts | the Secret Service | a key that can't be exported, and values it encrypts |
| `SecretCallback` | | | | | |
| `WebAuthentication` | `DynamicAuthentication` | `ASWebAuthenticationSession` | Custom Tabs, and an intent for the redirect | the system's browser, and a handler for the redirect | a pop-up window |
| `WebAuthenticationCallback` | | | | | |

Guest-side Swift:

- **`Keychain`**: the app's secrets, by key.
- **`WebAuthenticationSession`**: SwiftUI's name and methods, for one
  sign-in.
- `KeychainAccessibility`, `KeychainError`, `WebAuthenticationError`.

The render IR doesn't change: the host shows the browser over the app's
window.

Host-side Swift: `HostSecrets` in `RuntimeSecrets`, over a host's
`SecretStore`; `HostWebAuthentication` in `RuntimeAuthentication`, over a
host's `WebAuthenticationPresenter`.

## What shapes it

- **A secret is the app's, on this device.** No other app reads it. It
  isn't in a backup and isn't synced to the user's other devices: on a
  new phone the user signs in again. That is the one rule every platform
  can keep.
- **Reading one can wait.** A keyring may need unlocking, and a browser's
  storage is asynchronous. So every call is.
- **A background task reads secrets too.** Mail fetched while the phone
  is locked needs its token then, which iOS allows only for a secret
  stored to permit it.
- **The app never sees the sign-in page.** The system's browser shows it,
  with the user's saved passwords and their existing session, and the app
  can't read what's typed. Some providers require this, and refuse a web
  view.
- **The host knows nothing of OAuth.** It opens a URL and returns the
  URL the provider redirected to. Building the first and checking the
  second, with its `state` and its code verifier, is the app's.
- **The redirect isn't the same everywhere.** A native app is called back
  through a URL scheme of its own. A web page can't have one: it's
  called back at an `https` address. So the app asks the host what
  redirect to give the provider.

## Secrets

```swift
import DynamicSecrets

let keychain = Keychain.default

try await keychain.set(refreshToken, forKey: "mail.refreshToken",
                       accessibility: .afterFirstUnlock)

if let token = try await keychain.string(forKey: "mail.refreshToken") {
    // signed in
}

try await keychain.removeValue(forKey: "mail.refreshToken")     // signing out
```

| `Keychain` | |
|---|---|
| `set(_:forKey:accessibility:)` | stores a `String` or `[UInt8]`, replacing what the key had |
| `string(forKey:)`, `data(forKey:)` | the value, or `nil` when there's none |
| `removeValue(forKey:)` | no error when there's none |
| `removeAll()` | every secret of the app's |
| `keys()` | the keys, sorted |

- **They are `async throws(KeychainError)`,** with completion-handler
  forms.
- **A key** is a string of 1 to 255 bytes. **A value** is at most 16 KB:
  a token or a password, not a file. More is `tooLarge`.
- **Secrets go with the app.** Removing the app removes them.
- **A string is stored as its UTF-8.** `string(forKey:)` of bytes that
  aren't UTF-8 fails with `invalidData`.
- **`accessibility`** says when the value can be read. A host that can't
  tell the two apart reads both whenever it can.

| `KeychainAccessibility` | |
|---|---|
| `.whenUnlocked` (the default) | while the device is unlocked |
| `.afterFirstUnlock` | from the first unlock after a restart, and so by a background task while the phone is locked |

| `KeychainError` | |
|---|---|
| `unavailable` | the store can't be read now: the device is locked, or this host has none |
| `notAllowed` | the user refused to unlock it |
| `invalidKey` | empty or too long |
| `tooLarge` | more than 16 KB |
| `invalidData` | not a string |
| `cancelled` | the task waiting was cancelled |

## Sign-in

```swift
import DynamicAuthentication

let session = WebAuthenticationSession()

// What to tell the provider to redirect to.
let redirect = session.redirectURL(scheme: "com.example.mail", path: "oauth")

let callback = try await session.authenticate(
    using: "https://accounts.example.com/authorize?client_id=…"
         + "&redirect_uri=" + percentEncoded(redirect) + "&state=" + state + "…",
    redirect: redirect)

// callback: "com.example.mail:/oauth?code=…&state=…"
```

| `WebAuthenticationSession` | |
|---|---|
| `redirectURL(scheme:path:)` | the redirect to register with the provider and put in the URL |
| `authenticate(using:redirect:preferredBrowserSession:)` | shows the page, and gives the URL the provider redirected to |
| `authenticate(using:callbackURLScheme:)` | SwiftUI's form: the same, for the host's redirect for that scheme and anything after it |
| `cancel()` | closes the page; the call fails with `canceledLogin` |

- **`redirectURL` is `scheme:/path` on a native host,** and on a browser
  an `https` address of the page's own. A provider wants every redirect
  registered, so an app that runs in both registers both.
- **The scheme is declared** in the manifest (below), and is the app's
  own: a reverse domain name, with a dot in it.
- **The URL is `https`.** Anything else fails with `invalidURL`.
- **The result is the whole redirect,** as the provider sent it. The app
  checks `state` and takes the code.
- **`preferredBrowserSession: .ephemeral`** asks for a page with no
  cookies from before and none kept after, for signing in to a second
  account. A host that can't shows the ordinary page.
- **Call it from a user action,** with the app in front.
- **One at a time.** A second while one is showing fails with `busy`.
- **Cancelling the task closes the page.**
- **There's a completion-handler form** of `authenticate(using:redirect:)`
  for code that isn't `async`.

| `WebAuthenticationError` | |
|---|---|
| `canceledLogin` | the user closed the page, or the app cancelled |
| `invalidURL` | not `https`, or a redirect whose scheme the manifest doesn't declare |
| `busy` | one is already showing |
| `notAllowed` | the platform refused: not from a user action, or the app isn't in front |
| `unsupported` | this host has no browser to show |

## The contracts

```swift
@DynamicRuntime("org.pureswift.secrets.Secrets", requires: .secrets)
public protocol Secrets: AnyObject {

    static func shared() -> Self

    /// `accessibility`: 0 when unlocked, 1 after the first unlock.
    /// Answered by `didComplete`.
    func set(_ key: String, value: [UInt8], accessibility: Int32, callback: SecretCallback)
    /// Answered by `didGet`.
    func get(_ key: String, callback: SecretCallback)
    func remove(_ key: String, callback: SecretCallback)
    func removeAll(_ callback: SecretCallback)
    /// Answered by `didList`.
    func keys(_ callback: SecretCallback)
}

@DynamicCallback("org.pureswift.secrets.Callback")
public protocol SecretCallback: AnyObject {
    func didComplete()
    /// `found` false: there's no such secret, and `value` is empty.
    func didGet(_ value: [UInt8], found: Bool)
    func didList(_ keys: [String])
    /// A `KeychainError` raw value.
    func didFail(_ error: Int32)
}

@DynamicRuntime("org.pureswift.authentication.WebAuthentication")
public protocol WebAuthentication: AnyObject {

    static func shared() -> Self

    /// The redirect for a scheme and a path, on this host.
    func redirectURL(_ scheme: String, path: String) -> String
    /// Shows `url`, and waits for a redirect that begins with `redirect`.
    /// Answered by `didAuthenticate` or `didFail`.
    func authenticate(_ url: String, redirect: String, ephemeral: Bool, callback: WebAuthenticationCallback)
    /// Closes the page that's showing.
    func cancel()
}

@DynamicCallback("org.pureswift.authentication.Callback")
public protocol WebAuthenticationCallback: AnyObject {
    /// The whole URL the provider redirected to.
    func didAuthenticate(_ url: String)
    /// A `WebAuthenticationError` raw value.
    func didFail(_ error: Int32)
}
```

### Rules every host follows

Secrets:

- **Every answer is on the main thread, once.** The store is read and
  written off it.
- **A secret is scoped to the app.** The host adds the app's identifier
  to whatever names it in the platform's store. A guest can't name
  another app's.
- **A secret stays on the device.** It isn't backed up and isn't synced.
- **Secrets go when the app does.** Where the platform keeps them after
  an app is removed, as iOS does, the host empties the store the first
  time the app runs after being installed.
- **A value is stored as given,** up to 16 KB, and a key up to 255
  bytes. A host that can hold more still refuses more.
- **No secret is not an error:** `didGet` with `found` false, and
  `remove` completes.
- **Nothing is logged:** not a value, and not a key.

Sign-in:

- **The page is the system's browser,** never a web view of the host's
  own. The guest can't see it, script it or read its cookies.
- **Only `https` is shown.**
- **A redirect counts when it begins with `redirect`,** which must be one
  the host gave for a declared scheme. The host returns it whole and
  closes the page.
- **The host doesn't read the redirect.** It checks nothing in it.
- **One at a time,** and the answer comes once, on the main thread.
- **Closing the page, or `cancel`, is `canceledLogin`.**
- **A redirect to the app's scheme that no session is waiting for** is
  dropped.

## The shared host

Two targets, as there are two modules.

`HostSecrets`, in `RuntimeSecrets`, over a host's `SecretStore`:

```swift
public protocol SecretStore: AnyObject, Sendable {   // off the main thread, one call at a time
    func set(_ key: String, value: [UInt8], accessibility: KeychainAccessibility) throws(KeychainError)
    func value(forKey key: String) throws(KeychainError) -> [UInt8]?
    func remove(_ key: String) throws(KeychainError)
    func removeAll() throws(KeychainError)
    func keys() throws(KeychainError) -> [String]
}

HostSecrets.store = MyKeychain(service: appIdentifier)
HostSecretsModule.register(in: runtime)
```

- It checks keys and sizes, runs the store off the main thread in the
  order the guest asked, sorts the keys by their bytes, and answers on
  the main thread.
- An accessibility it doesn't know, from a newer guest, is the stricter
  one.
- **Without a store, every call fails with `unavailable`.** It doesn't
  keep secrets in memory or in a file: a secret that isn't kept safely
  is worse than one that isn't kept.
- **`MemorySecretStore`** is for a host's tests. Nothing uses it unasked.

`HostWebAuthentication`, in `RuntimeAuthentication`, over a host's
`WebAuthenticationPresenter`:

```swift
public protocol WebAuthenticationPresenter: AnyObject {       // main thread
    /// The redirect on this platform. The default is `scheme:/path`.
    func redirectURL(scheme: String, path: String) -> String
    func present(_ url: String, redirect: String, ephemeral: Bool,
                 completion: @escaping (Result<String, WebAuthenticationError>) -> Void)
    func cancel()
}

HostWebAuthentication.presenter = MyBrowser()
HostWebAuthentication.declaredSchemes = ["com.example.mail"]    // RTAuthenticationSchemes
HostWebAuthenticationModule.register(in: runtime)
```

- It refuses a URL that isn't `https`, and a redirect that doesn't begin
  with what the presenter gives for a declared scheme.
- It allows one page at a time, and answers once: a presenter that
  completes twice, or after a cancel, or for a page before, is ignored.
- A redirect that isn't the one waited for is not a sign-in.
- `cancel` answers the guest at once, then tells the presenter.
- **Without a presenter, `authenticate` fails with `unsupported`,** and
  `redirectURL` is still `scheme:/path`.

## The manifest

```swift
capabilities: [.secrets],
authenticationSchemes: ["com.example.mail"]
```

`.secrets` has no usage text and prompts for nothing. The schemes reach a
host in the bundle's `Info.plist`, as `RTAuthenticationSchemes`. The
packager refuses one that isn't lower case with a dot in it, which rules
out the web's own (`http`, `https`, `mailto`, `file` and the like), and
one listed twice.

| | `.secrets` | A scheme |
|---|---|---|
| iOS / macOS | nothing | nothing: the session is given the scheme when it starts |
| Android | nothing | an activity with an intent filter for it |
| Linux | the Secret Service on the session bus | a handler for it in the app's desktop entry |
| Browser | nothing | nothing: the redirect is a page of the app's own |

## Per host

From each platform's documentation. None of it has been tried.

| | Secrets | Sign-in |
|---|---|---|
| iOS / macOS | `kSecClassGenericPassword`, with the app's identifier as the service and the key as the account. `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` and `…AfterFirstUnlockThisDeviceOnly`. Keychain items outlive the app on iOS, so a marker in the app's container says whether to empty them. | `ASWebAuthenticationSession`, with `prefersEphemeralWebBrowserSession`. The system asks the user before it shares the browser's cookies, unless the session is ephemeral. |
| Android | An AES-GCM key in the Android Keystore, and each value encrypted in a file of the app's own, which is left out of backups. A Keystore key works while the device is locked, so both accessibilities read alike. | Custom Tabs for the page, and an activity that catches the redirect and hands it back. An ephemeral page where the browser has one. |
| Linux | The Secret Service (`org.freedesktop.secrets`), each item with the app's identifier as an attribute. The keyring may ask the user to unlock it; a refusal is `notAllowed`. Any app on the session bus can read an unlocked keyring, so the sandbox must keep guests off it and leave the host's own access. | The system's browser through the launcher, and the scheme's handler, which the launcher registers and which passes the redirect to the running app. The plan's accounts service sits here. |
| Browser | A key made with `crypto.subtle.generateKey` as not extractable, kept in IndexedDB with the values it encrypts. This stops a value being copied out of storage, and not a script on the page from using it. | A pop-up window, and a page of the app's own at the redirect that passes its address back with `postMessage`. Pop-ups need a user action. `ephemeral` is ignored. |

## Not in this design

- **Asking for a fingerprint or a face before a secret is read.** iOS and
  Android can; Linux and a browser have nothing like it.
- **Secrets shared between apps,** and secrets synced to the user's
  other devices.
- **The user's saved passwords:** autofill, and the system's password
  manager.
- **Passkeys,** and Sign in with Apple or Google as buttons of their own.
- **Loopback redirects** (`http://127.0.0.1:…`), which some providers
  want from desktop apps.
- **Redirects to an `https` address the app owns** on native hosts:
  universal links and app links.
- **Accounts the system already has.** The plan's accounts service on
  Linux could give an app a token with no sign-in at all.
- **Encryption for an app's own files.** A key can be kept as a secret;
  the cipher is the app's.

## Example and tests

`examples/ExampleSignIn` is an account with a provider: it asks the host
for its redirect, shows the provider's page, checks the reply's `state`,
keeps what it was given in the keychain for a background task to read,
and signs out by removing it. It runs as `App.wasm` under WasmKit
(`Packages/RuntimeWasm`) and as a sealed native slice and wasm2c output
(`Packages/LinkedSlice`), against both shared hosts, with the test
playing the browser.

- `DynamicSecretsTests`, `DynamicAuthenticationTests`: the contracts'
  keys and signatures, and the guest's `Keychain` and
  `WebAuthenticationSession` against scripted hosts.
- `RuntimeSecretsTests`: `HostSecrets` over a store in memory, from the
  guest: secrets by key, limits, a store's refusals, no store, the order
  of work, and the `async` forms.
- `RuntimeAuthenticationTests`: `HostWebAuthentication` over a browser
  the test plays, from the guest: the redirect on a native host and on a
  browser host, what's shown and what isn't, one page at a time, a
  cancel, late and repeated answers, and a cancelled task.
- `AppManifestTests` and `Scripts/test_manifest.py`: `.secrets` and
  `authenticationSchemes`.

## Decided in review

The design was approved as drafted, so these stand:

- **Names:** `Keychain` in `DynamicSecrets`; `WebAuthenticationSession`
  in `DynamicAuthentication`. Neither module is renamed in a guest build.
- **Two modules.**
- **A `.secrets` capability,** with no prompt.
- **A secret never leaves the device.**
- **No store, no secrets.**
- **The app asks the host for its redirect.**
- **No fingerprint before a read.**
- **Both were built together,** with one example.
