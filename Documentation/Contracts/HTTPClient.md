# HTTP Client

Module `DynamicNetworking`: HTTP requests, modeled on `URLSession`, plus host
URL parsing. TCP and UDP sockets are not part of the spec.

| Contract | Kind | iOS | Android | Linux |
|---|---|---|---|---|
| `HTTPSession` | contract, `requires: .network` | `URLSession` | `OkHttpClient` / `HttpURLConnection` | libcurl |
| `HTTPSessionConfiguration` | contract | `URLSessionConfiguration` | client builder | curl options |
| `HTTPRequest` | contract | `URLRequest` | `Request` | |
| `HTTPResponse` | contract | `HTTPURLResponse` | `Response` | |
| `HTTPTask` | contract | `URLSessionDataTask` / `URLSessionUploadTask` | `Call` | easy handle |
| `HTTPTaskDelegate` | callback | `URLSessionTaskDelegate` / `URLSessionDataDelegate` | `Callback`, interceptors, `Authenticator` | curl callbacks |
| `HTTPCredential` | contract | `URLCredential` | `Credentials` | |
| `ParsedURL` | contract | `URL` / `URLComponents` | `java.net.URI` / `HttpUrl` | curl URL API |

Guest-side Swift: `HTTPTaskState`, `HTTPCachePolicy`,
`HTTPAuthenticationMethod`, `HTTPCredentialPersistence`, `NetworkError`.

## Permissions first

Most HTTP needs no prompt, but three things can stop a request:

| Gate | iOS | Android | How the app finds out |
|---|---|---|---|
| Internet access | none | `INTERNET` (granted at install) | the `.network` capability adds it; without the capability, `rt_class` refuses `HTTPSession` |
| Plain `http` | App Transport Security blocks it | cleartext blocked by default (API 28+) | `.insecureConnectionNotAllowed` |
| Local network | a prompt on the first request to a LAN address (iOS 14+), needs `NSLocalNetworkUsageDescription` | none | `.localNetworkDenied` |

Neither platform has an API to request local network access or to check its
status, so the contract can't offer a `requestAuthorization()` here. The app
should make its first LAN request from a user action, and treat
`.localNetworkDenied` as a Settings hint.

Allowing plain `http` for a domain is a manifest decision (ATS exceptions,
Android network security config). Guests can't change it at runtime.

## Using a session

1. Get `HTTPSession.shared()`, or `make(_:)` with a configuration.
2. `HTTPRequest.make(url:)`, which returns nil unless the URL is absolute
   `http` or `https`.
3. `dataTask(_:delegate:)` or `uploadTask(_:body:delegate:)` create a
   suspended task. `resume()` starts it.
4. The delegate receives, in order: redirects and challenges as they occur,
   one `didReceiveResponse`, any number of `didReceiveData`, and exactly one
   `didComplete`.

## Platform limitations the contract accounts for

**Delegates are per task.** OkHttp has per-call callbacks, and `URLSession`
supports them from iOS 15. On older iOS, hosts route session-delegate events
to the task's delegate themselves.

**Decisions are synchronous on the guest side only.**
`willPerformRedirect`, `didReceiveResponse` and `didReceiveChallenge` return
values. The host calls them on the main thread and holds the request until
they return, using completion handlers on iOS and a waiting network thread
on Android. Keep them fast.

**No `suspend`.** OkHttp can't pause a running call, so tasks only have
`resume()` and `cancel()`. A task is `.suspended` only before its first
`resume()`.

**Server trust stays in the host.** Certificate evaluation never reaches the
guest, so a guest can't disable TLS checks. Certificate pinning isn't in v1;
it needs a manifest-level design. Failures report
`.serverCertificateUntrusted`.

**Challenges** cover Basic, Digest and proxy Basic. NTLM and Negotiate are
reported as `.other` and can't be answered with a password. `HTTPCredential`
is write-only, so the password can't be read back.

**Network policy.** `setAllowsCellularAccess`,
`setAllowsExpensiveNetworkAccess` and `setAllowsConstrainedNetworkAccess` map
to the `URLSessionConfiguration` flags. Android hosts check
`NetworkCapabilities` (`NOT_METERED`, Data Saver). Requests that a policy
forbids fail with `.networkAccessNotAllowed`.

**Waiting for connectivity.** With `setWaitsForConnectivity(true)` the task
reports `taskIsWaitingForConnectivity` and continues when a network returns.
Android hosts implement this with a `NetworkCallback`.

**Resource timeout.** `URLSession` has one; other hosts enforce
`timeoutForResource` themselves.

**Headers.** Lookups are case-insensitive, and multiple values are joined
with `, `. `Set-Cookie` is managed by the host's cookie store when
`setShouldSetCookies(true)`.

**Bodies are bytes.** A request body is one `[UInt8]`, copied in once.
Responses stream as chunks, so a guest can write large downloads to its
container through WASI as they arrive.

**Not included in v1:** background sessions (their lifecycle relaunches the
app and isn't portable), download-to-file tasks, streamed request bodies,
suspending tasks, WebSockets, certificate pinning, and a reachability or
network-path contract.

## Async/await

Guest code can use the `HTTPSession` extensions instead of a task delegate
(§6.2.1). They are guest-side only; hosts never see them.

| Call | Returns |
|---|---|
| `data(for:followRedirects:challenge:)` | `HTTPResult`: the response and the whole body |
| `upload(for:body:followRedirects:challenge:)` | `HTTPResult` |
| `events(for:body:followRedirects:challenge:)` | `EventStream<HTTPEvent, NetworkError>`: upload progress, the response, body chunks |

Cancelling the task, or releasing an event stream, cancels the request.
`challenge` answers authentication challenges with an `HTTPCredential`;
without one, the host handles them by default.

## Threading

Every delegate method runs on the main thread (§6.4).

## Example

```swift
final class Fetch: HTTPTaskDelegate {
    var body = [UInt8]()

    func start() {
        guard let request = HTTPRequestProxy.make(url: "https://example.com/data.json") else { return }
        request.setHeader("Accept", value: "application/json")
        HTTPSessionProxy.shared().dataTask(request, delegate: self).resume()
    }

    func willPerformRedirect(_ task: HTTPTask, response: HTTPResponse, newRequest: HTTPRequest) -> Bool { true }

    func didReceiveChallenge(_ task: HTTPTask, method: Int32, host: String, realm: String?, previousFailureCount: Int32) -> HTTPCredential? { nil }

    func didReceiveResponse(_ task: HTTPTask, response: HTTPResponse) -> Bool {
        response.statusCode() == 200
    }

    func didReceiveData(_ task: HTTPTask, data: [UInt8]) {
        body += data
    }

    func didComplete(_ task: HTTPTask, error: Int32, message: String?) {
        if error == 0 { parse(body) }
    }
    // …
}
```
