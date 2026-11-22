import DynamicTransfers
import Foundation

/// What a platform supplies to move a transfer's bytes. `HostTransfers`
/// keeps the rules (`Documentation/Contracts/Transfers.md`): the records,
/// the states, where a download's bytes go and when they become the file.
/// An engine only moves bytes, and says what happened.
///
/// An engine is told to start a job, and to stop it. It reports through the
/// job's `TransferReporter`, from any thread, in order: `waiting` whenever
/// it has to wait, one `response`, any number of `progress`, then one
/// `finished`. After `stop` it reports nothing more for that job, and what
/// it had written stays where it is.
///
/// A download writes to `job.file`, a part file the host keeps. With an
/// `offset`, the part file holds that many bytes already: the engine asks
/// the server for the rest (`Range`, and `If-Range` with the validator),
/// and appends to the file if the server sends the rest, or empties it and
/// says `startsOver` if the server sends everything.
///
/// An engine for transfers carried on after the app is closed may be told
/// to start a job it already runs, at the next launch: it goes on as it
/// was, and reports to the new reporter.
public protocol TransferEngine: AnyObject {

    func start(_ job: TransferJob, reporter: TransferReporter)

    func stop(_ identifier: String)
}

/// One transfer, as an engine runs it.
public struct TransferJob: Equatable, Sendable {

    public let identifier: String

    public let kind: TransferKind

    public let url: String

    public let method: String

    /// Names and values, in the order the app gave them.
    public let headers: [TransferHeader]

    /// A download's part file, which the engine writes; an upload's file,
    /// which it reads. An absolute path.
    public let file: String

    /// For a download: the bytes the part file holds already.
    public let offset: Int64

    /// For a download that goes on: the `ETag`, or else the
    /// `Last-Modified`, of what the part file holds.
    public let validator: String?

    public let allowsExpensiveNetwork: Bool

    public let isDiscretionary: Bool

    /// What the system shows for it, where it shows anything.
    public let title: String

    public init(identifier: String, kind: TransferKind, url: String, method: String, headers: [TransferHeader],
                file: String, offset: Int64 = 0, validator: String? = nil, allowsExpensiveNetwork: Bool = true,
                isDiscretionary: Bool = false, title: String = "") {
        self.identifier = identifier
        self.kind = kind
        self.url = url
        self.method = method
        self.headers = headers
        self.file = file
        self.offset = offset
        self.validator = validator
        self.allowsExpensiveNetwork = allowsExpensiveNetwork
        self.isDiscretionary = isDiscretionary
        self.title = title
    }
}

public struct TransferHeader: Equatable, Hashable, Codable, Sendable {

    public let name: String

    public let value: String

    public init(_ name: String, _ value: String) {
        self.name = name
        self.value = value
    }
}

/// Where an engine tells `HostTransfers` what one job did. Call it from any
/// thread; what it says reaches the host on the main thread, in order.
/// After the job is stopped, or a new launch has begun, it says nothing.
public final class TransferReporter: @unchecked Sendable {

    public let identifier: String

    /// Which run of the job this is: the host ignores reports from one it
    /// stopped.
    let token: Int

    init(identifier: String, token: Int) {
        self.identifier = identifier
        self.token = token
    }

    /// The job can't move now: no network, its turn, the system's moment.
    public func waiting() {
        report(.waiting)
    }

    /// The server's answer. `expectedBytes` is the whole file's size, or
    /// the upload's, where it's known. `startsOver`: a download asked to go
    /// on was sent everything, and the part file was emptied.
    public func response(status: Int, contentType: String? = nil, suggestedFileName: String? = nil,
                         expectedBytes: Int64? = nil, validator: String? = nil, startsOver: Bool = false) {
        report(.response(status: status, contentType: contentType, suggestedFileName: suggestedFileName,
                         expectedBytes: expectedBytes, validator: validator, startsOver: startsOver))
    }

    /// How many bytes have moved in all, a download's offset included.
    /// `expectedBytes`, where it's known only now: an upload's size.
    public func progress(_ bytes: Int64, expectedBytes: Int64? = nil) {
        report(.progress(bytes: bytes, expectedBytes: expectedBytes))
    }

    /// The job ended: nil when every byte moved, whatever the server's
    /// status; the host judges that.
    public func finished(_ error: TransferError?) {
        report(.finished(error))
    }

    enum Report: Sendable {
        case waiting
        case response(status: Int, contentType: String?, suggestedFileName: String?, expectedBytes: Int64?,
                      validator: String?, startsOver: Bool)
        case progress(bytes: Int64, expectedBytes: Int64?)
        case finished(TransferError?)
    }

    private func report(_ report: Report) {
        let identifier = identifier
        let token = token
        HostTransfers.deliver {
            HostTransfers.shared().engineReported(identifier, token: token, report)
        }
    }
}
