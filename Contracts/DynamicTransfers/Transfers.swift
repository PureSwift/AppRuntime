import DynamicRuntime

/// Downloads to a file and uploads from one, with the host moving the
/// bytes (`Documentation/Contracts/Transfers.md`). App code uses
/// `TransferManager`, which wraps this contract.
///
/// A transfer is the host's: it has an identifier, outlives the guest
/// object that started it, and can be left to the system to carry on after
/// the app is closed. Every operation that answers does so once, through
/// its `callback`, on the main thread.
///
/// | Host | Implementation |
/// |---|---|
/// | iOS / macOS | `URLSession`, and a background session for what's carried on |
/// | Android | OkHttp to a file; a user-initiated data transfer job |
/// | Linux | `URLSession` in the host |
/// | Browser | `fetch` to the origin's private files; Background Fetch |
@DynamicRuntime("org.pureswift.transfers.Transfers", requires: .network)
public protocol Transfers: AnyObject {

    static func shared() -> Self

    /// `kind` is a `TransferKind` raw value. `headers`: names and values in
    /// turn. A file as `Files` names it: the destination of a download, the
    /// body of an upload. `options`: `TransferOptions` bits.
    /// `completionMessage` empty: no notification. Answered by `didStart`,
    /// with the transfer's record.
    func start(_ kind: Int32, url: String, method: String, headers: [String],
               directory: Int32, path: String,
               title: String, completionMessage: String, options: Int32,
               callback: TransferCallback)

    /// Every transfer the host has, oldest first. Answered by `didList`.
    func list(_ callback: TransferCallback)

    func pause(_ identifier: String)

    func resume(_ identifier: String)

    /// Stops a transfer and discards what it had.
    func cancel(_ identifier: String)

    /// Forgets a transfer that has ended. One still moving is left.
    func remove(_ identifier: String)

    /// Told when a transfer changes. Nil stops it.
    func setDelegate(_ delegate: TransfersDelegate?)
}

/// One operation's answer. The host calls exactly one method, once.
@DynamicCallback("org.pureswift.transfers.TransferCallback")
public protocol TransferCallback: AnyObject {

    /// A `TransferRecord`.
    func didStart(_ record: [String])

    /// Records one after another, each `TransferRecord.fieldCount` long.
    func didList(_ records: [String])

    /// A `TransferError` code, and the host's description of it.
    func didFail(_ error: Int32, message: String)
}

/// Told when the host's transfers change, on the main thread.
@DynamicCallback("org.pureswift.transfers.TransfersDelegate")
public protocol TransfersDelegate: AnyObject {

    /// A `TransferRecord`.
    func didChange(_ record: [String])

    func didRemove(_ identifier: String)
}
