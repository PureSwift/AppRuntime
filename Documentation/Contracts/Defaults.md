# Defaults

Module `DynamicDefaults`: small settings kept across launches. The guest's
`UserDefaults`, and SwiftUI's `@AppStorage`.

| Contract | Kind | iOS / macOS | Android | Linux | Browser |
|---|---|---|---|---|---|
| `Defaults` | contract (no capability) | `UserDefaults` | `SharedPreferences` | a file in `/data` | `localStorage`, under the app's prefix |

Guest-side Swift: `UserDefaults` and `@AppStorage`.

The guest side is implemented, and so is a host side: `HostDefaults` in
`RuntimeHost`, over any store a host gives it, with a file-backed one
included. The design is §7.9 of `DynamicRuntime.md`.

## Why it's synchronous

The app's files and its model store are asynchronous because a browser's
larger storage can't be used synchronously on the main thread. Settings
are different: every platform has a small key-value store that answers at
once, and so does the browser. So this one contract's calls return their
values, and `@AppStorage` can be a plain property.

It's for small values. A host may refuse a value over 64 KB, and a browser
keeps about 5 MB for all of them. A list of records belongs in the
[model store](Persistence.md), and anything large in a [file](Files.md).

## For a guest

```swift
import DynamicDefaults
import SwiftUI

struct SettingsView: View {

    @AppStorage("soundOn") var soundOn = true
    @AppStorage("volume") var volume = 0.5

    var body: some View {
        Toggle("Sound", isOn: $soundOn)
        Slider(value: $volume, in: 0...1)
    }
}

let defaults = UserDefaults.standard
defaults.set(defaults.integer(forKey: "launches") + 1, forKey: "launches")
```

**`@AppStorage`** works for `Bool`, `Int`, `Double`, `String`, bytes, and
enums whose raw value is an `Int` or a `String`. It reads the stored value,
or its default while there's none, and stores what it's set to.

**`UserDefaults`** follows Foundation's:

| | |
|---|---|
| `string(forKey:)`, `data(forKey:)` | `nil` when there's no value |
| `bool(forKey:)`, `integer(forKey:)`, `double(forKey:)` | `false` or 0 when there's no value, or it isn't one |
| `set(_:forKey:)` | for each of those types; `nil` removes the key. Returns whether the host kept the value |
| `removeObject(forKey:)` | fine if there's nothing |
| `hasValue(forKey:)`, `keys` | not in Foundation's: whether a key is set, and every key, sorted |

- **It's observable.** A view that reads a key, through `@AppStorage` or
  `UserDefaults` itself, updates when the app sets it. So do views that
  read `keys`.
- **A change from outside the app isn't seen** until the key is read
  again: another process, another browser tab, the system's settings.
  There's no notification for those.
- **Numbers and booleans are stored as text** (`"true"`, `"-42"`,
  `"0.1"`), so a host's own tools show something readable. A `Double`
  comes back as exactly the value stored.
- **A value of another kind reads as missing:** `integer(forKey:)` of
  `"seven"` is 0, and an enum's unknown raw value is the default.
- **`Int` is 32 bits in a wasm guest** and 64 in a native slice. A count
  stored by one that the other can't hold reads as 0.
- The class is named `UserDefaults`, as Foundation's is. Host-side Swift
  that imports both writes `DynamicDefaults.UserDefaults`; a guest has no
  Foundation to confuse it with.

## The contract

```swift
@DynamicRuntime("org.pureswift.data.Defaults")
protocol Defaults {
    static func standard() -> Self
    func string(_ key: String) -> String?
    func data(_ key: String) -> [UInt8]?
    func setString(_ value: String, key: String) -> Bool
    func setData(_ value: [UInt8], key: String) -> Bool
    func remove(_ key: String)
    func keys() -> [String]
}
```

### Rules every host follows

- **A key holds one value**, a string or bytes. Setting one kind replaces
  the other; `string` of a key that holds bytes is `nil`, and the other
  way around.
- **An empty string is a value.** A key is absent only before it's set and
  after it's removed.
- **A setter returns whether the value was kept.** `false` when it's over
  the host's limit or storage is full; the old value stays.
- **`keys` is sorted by UTF-8 bytes**, so every host gives the same order.
- **An empty key is refused.** Keys are otherwise any string.
- **A value that was set is there at the next launch.** The host writes it
  before the call returns, or at the latest before the app next loses the
  foreground.
- **Only the app's own values.** The host keeps them apart from its own
  settings: a prefix or a suite of its own.

### A host in Swift

`HostDefaults` (in `RuntimeHost`) is the contract over a `DefaultsStorage`,
which a host supplies:

```swift
HostDefaults.storage = try FileDefaultsStorage(path: container + "/Defaults")
HostDefaultsModule.register(in: runtime)
```

- **`FileDefaultsStorage`** keeps every value in memory and rewrites one
  file, atomically, at each change. It has no Foundation. It's the Linux
  host's store, and works for any host with a POSIX file system.
  - A value over `maximumValueSize` (64 KB) is refused.
  - A write that fails changes nothing: the value in memory stays what the
    file has.
  - A file that doesn't read as settings is moved aside to
    `<path>.corrupt`, and the app starts with none.
  - The file is `"RTD1"`, then for each key, in order: a kind byte (0 a
    string, 1 bytes), the key's length and bytes, and the value's length
    and bytes; lengths are 32-bit, little-endian.
- **A host with a store of its own** (`UserDefaults`, in a suite named for
  the app) conforms it to `DefaultsStorage`: six methods.

| | Notes |
|---|---|
| iOS / macOS | `UserDefaults(suiteName:)` behind `DefaultsStorage`, or `FileDefaultsStorage` in Application Support. |
| Android | `SharedPreferences`, with `apply()`; bytes as Base64 under a marked key, since it has no byte type. |
| Linux distro | `FileDefaultsStorage` in `/data`. |
| Browser | `localStorage` under `<app id>.`; bytes as Base64 with a marker. `setItem` throws at the quota: answer `false`. Private windows may keep nothing after they close. |

## Capability

None. These are the app's own values.

## Threading

Every call is on the main thread (§6.4), and returns its answer.

## Example

`examples/ExampleDefaults`: a settings screen with a toggle, a slider, a
name, a theme kept as an enum, and a count of launches. Its tests keep the
settings in a real file through `HostDefaults`: as `App.wasm` under
WasmKit, launched twice, where the second launch finds what the first
stored (`Packages/RuntimeWasm`), and as a sealed native slice and wasm2c
output (`Packages/LinkedSlice`).
