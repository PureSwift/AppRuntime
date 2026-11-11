# NFC

Module `DynamicNFC`: read and write NFC tags, and send commands to them.
Reader role only.

| Contract | Kind | iOS | Android | Linux |
|---|---|---|---|---|
| `NFCReader` | contract, `requires: "nfc"` | `NFCTagReaderSession` / `NFCNDEFReaderSession` | `NfcAdapter.enableReaderMode` | neard / libnfc |
| `NFCReaderDelegate` | callback | session delegate | `ReaderCallback` + tag I/O | |
| `NFCTag` | contract | `NFCTag` (`NFCISO7816Tag`, `NFCMiFareTag`, `NFCISO15693Tag`, `NFCFeliCaTag`) | `Tag` + `IsoDep` / `NfcA` / `NfcF` / `NfcV` / `Ndef` | |
| `NDEFMessage`, `NDEFRecord` | contracts | `NFCNDEFMessage`, `NFCNDEFPayload` | `NdefMessage`, `NdefRecord` | |

Guest-side Swift: `NFCAvailability`, `NFCTagTypes`, `NFCTagType`,
`NDEFStatus`, `NDEFTypeNameFormat`, `NFCError`.

## Availability first

NFC has no runtime permission prompt on any platform:
- **iOS:** the system scan sheet that appears with every session is the
  user's consent.
- **Android:** the `NFC` permission is granted at install.

What varies is whether the device can read at all, so the first step is a
check:

```swift
switch NFCAvailability(rawValue: NFCReaderProxy.availability()) {
case .available:  showScanButton()
case .disabled:   showHint("Turn on NFC in Settings")   // Android only
default:          hideNFCFeature()                       // iPad, Mac, TV, no hardware
}
```

Then start a session **from a user action, in the foreground**:
1. `make(_:)`
2. `begin(_:alertMessage:)` → `didBecomeActive`
3. `didDetect` → `connect(_:)` → `didConnect`
4. tag operations, each with exactly one result callback
5. `invalidate(_:)` → `didInvalidate`

A reader is single-use. After `didInvalidate`, make a new one.

The manifest capability `nfc` expands to:

| Host | Declarations |
|---|---|
| iOS | `NFCReaderUsageDescription`; entitlement `com.apple.developer.nfc.readersession.formats` (`NDEF`, plus `TAG` for raw access); `com.apple.developer.nfc.readersession.iso7816.select-identifiers` (AIDs) and `com.apple.developer.nfc.readersession.felica.systemcodes` from the manifest's NFC escape hatch |
| Android | `<uses-permission android:name="android.permission.NFC"/>`, `<uses-feature android:name="android.hardware.nfc" android:required="false"/>` |
| Linux | sandbox access to the neard D-Bus service or the PC/SC reader |

A session that needs a declaration the manifest lacks (an undeclared AID,
for example) ends with `NFCError.missingDeclaration`.

## Platform limitations the contract accounts for

**iOS sessions are short and visible.**
- iOS shows a system sheet for every session.
- It ends the session after 60 seconds (`.sessionTimeout`), when the user
  taps Cancel (`.userCancelled`), or when the app leaves the foreground
  (`.appInBackground`).
- Only iPhone 7 and later can read, so iPad, Mac and Apple TV report
  `.unsupported`.

`setAlertMessage(_:)` updates the sheet, and `invalidate(_:)` shows success
or the given failure message. Android has no system sheet, so hosts show
their own prompt or nothing, and impose no timeout.

**NDEF-only vs. raw access.** `NFCTagTypes.ndef` maps to iOS's
`NFCNDEFReaderSession`. It needs no `TAG` entitlement format, but iOS then
exposes neither the UID nor raw commands: `identifier()` is empty, and
`transceive` fails with `.notAvailableInNDEFSession`. Other polling options
give full access where the manifest allows it.

**Raw commands differ by technology.** `transceive(_:)` sends bytes in the
tag's own protocol:
- ISO 7816 APDUs (`NFCISO7816Tag.sendCommand` / `IsoDep.transceive`). The
  response keeps the status word at the end, so it reads the same on both
  hosts.
- MIFARE Ultralight / DESFire / Plus native commands (`NfcA`).
- FeliCa commands (`NfcF`) and ISO 15693 requests (`NfcV`).

**MIFARE Classic is excluded.** iOS can't authenticate it, and many
Android devices (those without NXP controllers) can't either.

**UIDs aren't identities.** Many ISO 14443-4 cards (payment cards, passports,
phones) present a random UID on every tap. `identifier()` is for
anti-collision and logging. Read an identity from the card's data instead.

**Android foreground only.** Reader mode needs the app's activity in the
foreground. Hosts disable platform sounds and NDEF dispatch to other apps
while a session is active. Background tag dispatch (intent filters) and
iOS's background tag reading launch the app from outside it, so they belong
to the manifest, not to this contract.

**Not included:** card emulation (Android HCE; iOS only in some regions
from 17.4), peer-to-peer (Android Beam, removed in Android 14), tag
formatting (`NdefFormatable`, Android only), MIFARE Classic.

## Async/await

Guest code can use `AsyncNFCReader` instead of the delegate (§6.2.1). It's
guest-side only; hosts never see it.

- `AsyncNFCReader.availability`: never starts a session.
- `session(tagTypes:alertMessage:)`: `EventStream<[any NFCTag], NFCError>`.
  It finishes normally after `invalidate()`, or by throwing the host's reason
  (`userCancelled`, `sessionTimeout`, …). Releasing it ends the session.
- `connect(_:)`, `ndefStatus(of:)`, `readNDEF(_:)`, `writeNDEF(_:to:)`,
  `lock(_:)`, `transceive(_:with:)`: async, in order per tag. They throw when
  the session ends.

`cancelled` (17) is a guest-side code: the wrapper throws it when a task is
cancelled, hosts never send it.

## Threading

Every delegate method runs on the main thread (§6.4). Tag I/O happens on
the host's NFC queue or thread, never on the guest's.

## Example

```swift
final class TagReader: NFCReaderDelegate {
    var reader: NFCReaderProxy?

    func scan() {                                   // from a button tap
        guard NFCReaderProxy.availability() == NFCAvailability.available.rawValue else { return }
        let reader = NFCReaderProxy.make(self)
        self.reader = reader
        reader.begin(NFCTagTypes.iso14443.rawValue, alertMessage: "Hold your iPhone near the tag")
    }

    func didDetect(_ reader: NFCReader, tags: [NFCTag]) {
        if let tag = tags.first { reader.connect(tag) }
    }

    func didConnect(_ reader: NFCReader, tag: NFCTag, error: Int32) {
        guard error == 0 else { return reader.invalidate("Couldn't connect") }
        tag.readNDEF()
    }

    func didReadNDEF(_ reader: NFCReader, tag: NFCTag, message: NDEFMessage?, error: Int32) {
        let uri = message?.records().first?.uri()
        reader.invalidate(uri == nil ? "No link on this tag" : nil)
    }
    // …
}
```
