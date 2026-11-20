/// Guest-side names for what the `Documents` contract carries.

/// What an app may do with a document it asks for.
public enum DocumentAccess: Int32, Sendable {

    case read = 0

    /// Asked for when the file is picked: a host can't add it later.
    case readWrite = 1
}

/// Why a picker or a bookmark failed.
public enum DocumentError: Int32, Error, Sendable {

    case unknown = 0

    /// Guest-side: the task waiting was cancelled. The picker stays up, and
    /// what the user picks is dropped. Hosts never send it.
    case cancelled = 1

    /// A picker is already showing.
    case busy = 2

    /// Not called from a user action. A browser shows a picker only while
    /// it handles a tap or a key.
    case notAllowed = 3

    /// This host has no such picker, or can't remember a document.
    case unsupported = 4

    /// A bookmark's file is gone, or an export's source is.
    case notFound = 5

    /// A bookmark's access was taken back.
    case notPermitted = 6

    /// The host keeps no more bookmarks: forget some.
    case limitReached = 7
}

/// A document the host remembers for the app: a short string to keep in
/// `Defaults` or a model. It means nothing to another app or another
/// device.
///
/// ```swift
/// let bookmark = try await document.bookmark()
/// defaults.set(bookmark.rawValue, forKey: "last")
/// // At the next launch:
/// let document = try await Document(resolving: DocumentBookmark(rawValue: saved))
/// ```
public struct DocumentBookmark: RawRepresentable, Equatable, Hashable, Sendable {

    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// Gives up the access. The host may keep only so many, so forget those
    /// the app has dropped.
    public func forget() {
        DocumentsProxy.shared().forget(rawValue)
    }
}

/// What became of an export.
public enum DocumentExport: Sendable {

    /// Saved, and the app may keep writing to it.
    case saved(Document)

    /// Saved, and the host can't reach the copy again: a browser's
    /// download.
    case savedCopy

    case cancelled

    /// The saved document, where there is one.
    public var document: Document? {
        if case .saved(let document) = self {
            return document
        }
        return nil
    }
}
