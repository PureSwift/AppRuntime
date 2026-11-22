import DynamicFiles

/// Guest-side names for what the `Transfers` contract carries.

/// Which way the bytes go.
public enum TransferKind: Int32, Sendable {

    /// From a URL to a file.
    case download = 1

    /// From a file to a URL.
    case upload = 2
}

/// Where a transfer is.
public enum TransferState: Int32, Sendable {

    /// Taken on and not moving: for a network, for its turn, for the
    /// system's good moment.
    case waiting = 0

    case running = 1

    /// Stopped by the app, or by the app closing. A download keeps what
    /// it has.
    case paused = 2

    case completed = 3

    case failed = 4

    case cancelled = 5

    /// Whether the transfer has ended: it never changes again.
    public var isFinished: Bool {
        self == .completed || self == .failed || self == .cancelled
    }

    /// The states a transfer ends in.
    public static let allFinished: [TransferState] = [.completed, .failed, .cancelled]
}

/// Why a transfer failed, or was refused.
public enum TransferError: Error, Equatable, Hashable, Sendable {

    /// A code from a newer host, or a failure with no better name.
    case unknown

    /// Guest-side: the task waiting was cancelled. The transfer goes on.
    /// Hosts send it for a transfer cancelled, which `state` also says.
    case cancelled

    /// A URL that isn't `http` or `https`, a method that isn't one, or a
    /// path `Files` wouldn't take.
    case invalidRequest

    /// An upload's file isn't there.
    case fileNotFound

    /// The destination can't be written.
    case fileNotWritable

    case outOfSpace

    /// The network failed: a `NetworkError` raw value from
    /// `DynamicNetworking`, which this module doesn't link.
    case network(Int32)

    /// The server answered outside 200 to 299. `Transfer.response` has the
    /// whole answer.
    case httpStatus(Int)

    /// The server asked for credentials. There may be nobody to ask, so a
    /// transfer is never challenged: put the header in the request.
    case authenticationRequired

    /// The host can't carry a transfer on after the app is closed, or not
    /// to this destination.
    case notAllowedInBackground

    /// This host has no transfers.
    case unavailable

    /// The contract's code.
    public var code: Int32 {
        switch self {
        case .unknown: 0
        case .cancelled: 1
        case .invalidRequest: 2
        case .fileNotFound: 3
        case .fileNotWritable: 4
        case .outOfSpace: 5
        case .network: 6
        case .httpStatus: 7
        case .authenticationRequired: 8
        case .notAllowedInBackground: 9
        case .unavailable: 10
        }
    }

    /// The error for a contract's code. `detail` is the network error or
    /// the HTTP status, where the code has one.
    public init(code: Int32, detail: Int = 0) {
        switch code {
        case 1: self = .cancelled
        case 2: self = .invalidRequest
        case 3: self = .fileNotFound
        case 4: self = .fileNotWritable
        case 5: self = .outOfSpace
        case 6: self = .network(Int32(clamping: detail))
        case 7: self = .httpStatus(detail)
        case 8: self = .authenticationRequired
        case 9: self = .notAllowedInBackground
        case 10: self = .unavailable
        default: self = .unknown
        }
    }

    /// The network error or the HTTP status, where there is one.
    public var detail: Int {
        switch self {
        case .network(let code): Int(code)
        case .httpStatus(let status): status
        default: 0
        }
    }
}

/// What to fetch, or where to send.
public struct TransferRequest: Equatable, Hashable, Sendable {

    /// An absolute `http` or `https` URL.
    public var url: String

    /// Nil: `GET` for a download, `POST` for an upload.
    public var method: String?

    public var headers: [String: String]

    public init(url: String, method: String? = nil, headers: [String: String] = [:]) {
        self.url = url
        self.method = method
        self.headers = headers
    }

    /// The method a transfer of `kind` sends.
    public func method(for kind: TransferKind) -> String {
        if let method, !method.isEmpty {
            return method
        }
        return kind == .download ? "GET" : "POST"
    }

    /// Names and values in turn, sorted by name, as the contract takes
    /// them.
    public var headerList: [String] {
        var list: [String] = []
        for name in headers.keys.sorted() {
            list.append(name)
            list.append(headers[name] ?? "")
        }
        return list
    }
}

/// How a transfer is carried.
public struct TransferOptions: Equatable, Hashable, Sendable {

    /// What the system shows for it, where it shows anything.
    public var title: String

    /// Left to the system, to carry on after the app is closed.
    public var continuesInBackground: Bool

    /// Whether it may use mobile data.
    public var allowsExpensiveNetwork: Bool

    /// The system may wait for a good moment: power, Wi-Fi, the night.
    public var isDiscretionary: Bool

    /// A notification with this text when a transfer that was carried on
    /// finishes with the app closed. It needs the app's leave to notify.
    public var completionMessage: String?

    public init(title: String = "", continuesInBackground: Bool = false, allowsExpensiveNetwork: Bool = true,
                isDiscretionary: Bool = false, completionMessage: String? = nil) {
        self.title = title
        self.continuesInBackground = continuesInBackground
        self.allowsExpensiveNetwork = allowsExpensiveNetwork
        self.isDiscretionary = isDiscretionary
        self.completionMessage = completionMessage
    }

    /// The contract's bits.
    public static let continuesInBackgroundBit: Int32 = 1
    public static let avoidsExpensiveNetworkBit: Int32 = 2
    public static let isDiscretionaryBit: Int32 = 4

    public var bits: Int32 {
        var bits: Int32 = 0
        if continuesInBackground { bits |= Self.continuesInBackgroundBit }
        if !allowsExpensiveNetwork { bits |= Self.avoidsExpensiveNetworkBit }
        if isDiscretionary { bits |= Self.isDiscretionaryBit }
        return bits
    }

    public init(title: String, bits: Int32, completionMessage: String? = nil) {
        self.init(
            title: title,
            continuesInBackground: bits & Self.continuesInBackgroundBit != 0,
            allowsExpensiveNetwork: bits & Self.avoidsExpensiveNetworkBit == 0,
            isDiscretionary: bits & Self.isDiscretionaryBit != 0,
            completionMessage: completionMessage
        )
    }
}

/// What the server answered.
public struct TransferResponse: Equatable, Hashable, Sendable {

    public var statusCode: Int

    /// A MIME type, where the server gave one.
    public var contentType: String?

    /// The name the server suggests for the file: its
    /// `Content-Disposition`, or the URL's last part.
    public var suggestedFileName: String?

    public init(statusCode: Int, contentType: String? = nil, suggestedFileName: String? = nil) {
        self.statusCode = statusCode
        self.contentType = contentType
        self.suggestedFileName = suggestedFileName
    }

    /// Whether the server said yes.
    public var isSuccess: Bool {
        (200...299).contains(statusCode)
    }
}

/// One transfer as the contract carries it: sixteen strings.
///
/// | Field | |
/// |---|---|
/// | 0 | identifier |
/// | 1 | kind, a `TransferKind` raw value |
/// | 2 | state, a `TransferState` raw value |
/// | 3, 4 | URL, method |
/// | 5, 6 | the file: directory, path |
/// | 7 | title |
/// | 8 | `TransferOptions` bits |
/// | 9 | bytes moved |
/// | 10 | bytes expected; empty if unknown |
/// | 11 | HTTP status; empty before a response |
/// | 12, 13 | content type, suggested file name |
/// | 14 | a `TransferError` code; empty unless it failed |
/// | 15 | the network error or HTTP status behind it |
///
/// Numbers are decimal. Headers and the completion message aren't given
/// back: the host keeps them to itself.
public struct TransferRecord: Equatable, Hashable, Sendable {

    public static let fieldCount = 16

    public var identifier: String
    public var kind: TransferKind
    public var state: TransferState
    public var url: String
    public var method: String
    public var file: FilePath
    public var title: String
    public var options: Int32
    public var bytesTransferred: Int64
    public var bytesExpected: Int64?
    public var statusCode: Int?
    public var contentType: String
    public var suggestedFileName: String
    public var error: TransferError?

    public init(identifier: String, kind: TransferKind, state: TransferState, url: String, method: String,
                file: FilePath, title: String, options: Int32, bytesTransferred: Int64 = 0,
                bytesExpected: Int64? = nil, statusCode: Int? = nil, contentType: String = "",
                suggestedFileName: String = "", error: TransferError? = nil) {
        self.identifier = identifier
        self.kind = kind
        self.state = state
        self.url = url
        self.method = method
        self.file = file
        self.title = title
        self.options = options
        self.bytesTransferred = bytesTransferred
        self.bytesExpected = bytesExpected
        self.statusCode = statusCode
        self.contentType = contentType
        self.suggestedFileName = suggestedFileName
        self.error = error
    }

    public var fields: [String] {
        [
            identifier,
            String(kind.rawValue),
            String(state.rawValue),
            url,
            method,
            String(file.directory.rawValue),
            file.path,
            title,
            String(options),
            String(bytesTransferred),
            bytesExpected.map { String($0) } ?? "",
            statusCode.map { String($0) } ?? "",
            contentType,
            suggestedFileName,
            error.map { String($0.code) } ?? "",
            error.map { String($0.detail) } ?? "",
        ]
    }

    /// A record from sixteen strings; nil if they aren't one. A kind or a
    /// state from a newer host is the nearest this side knows.
    public init?(fields: ArraySlice<String>) {
        guard fields.count >= Self.fieldCount else { return nil }
        let field = Array(fields.prefix(Self.fieldCount))
        guard !field[0].isEmpty, let kind = Int32(field[1]), let state = Int32(field[2]),
              let directory = Int32(field[5]) else {
            return nil
        }
        self.identifier = field[0]
        self.kind = TransferKind(rawValue: kind) ?? .download
        // A state this side doesn't know isn't one to wait on.
        self.state = TransferState(rawValue: state) ?? .waiting
        self.url = field[3]
        self.method = field[4]
        self.file = FilePath(FileDirectory(rawValue: directory), field[6])
        self.title = field[7]
        self.options = Int32(field[8]) ?? 0
        self.bytesTransferred = Int64(field[9]) ?? 0
        self.bytesExpected = Int64(field[10])
        self.statusCode = Int(field[11])
        self.contentType = field[12]
        self.suggestedFileName = field[13]
        self.error = Int32(field[14]).map { TransferError(code: $0, detail: Int(field[15]) ?? 0) }
    }

    /// Records one after another.
    public static func records(_ fields: [String]) -> [TransferRecord] {
        var records: [TransferRecord] = []
        var start = 0
        while start + fieldCount <= fields.count {
            if let record = TransferRecord(fields: fields[start..<(start + fieldCount)]) {
                records.append(record)
            }
            start += fieldCount
        }
        return records
    }
}
