/// Why drawing an image, or asking about one, failed.
public enum DrawingError: Int32, Error, Sendable {

    case unknown = 0

    /// Guest-side: the task waiting was cancelled. Hosts never send it.
    case cancelled = 1

    /// No such file, or not a file.
    case notFound = 2

    /// Not an image this host decodes, or a damaged one.
    case undecodable = 3

    /// More pixels than the host takes.
    case tooLarge = 4

    /// This host decodes no images.
    case unavailable = 5

    /// The app may not read the file: a document it let go of.
    case notPermitted = 6
}
