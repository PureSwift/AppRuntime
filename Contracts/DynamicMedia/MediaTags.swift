import DynamicFiles
import DynamicRuntime
#if hasFeature(Embedded) && !EMBEDDED_NO_CONCURRENCY
// Embedded Swift doesn't import the concurrency module implicitly.
import _Concurrency
#endif

/// A media file's tags and artwork, read by the host without playing it:
/// what a music library shows of each song.
///
/// ```swift
/// let tags = try await MediaTags.read(from: .documents / "Music/so-what.mp3")
/// tags.title          // "So What"
/// tags.trackNumber    // 1
/// ```
///
/// A tag the file doesn't have is `nil`. Every tag the host read is in
/// `values`, by its key, for one this type doesn't name.
public struct MediaTags: Equatable, Sendable {

    /// The host's keys and values. Numbers are decimal text.
    public var values: [String: String]

    /// The cover's image file, when it was asked for and the file has one.
    /// It goes straight to `NowPlayingInfo.artwork`.
    public var artwork: NowPlayingArtwork?

    public init(values: [String: String] = [:], artwork: NowPlayingArtwork? = nil) {
        self.values = values
        self.artwork = artwork
    }

    public var title: String? { values["title"] }

    public var artist: String? { values["artist"] }

    public var album: String? { values["album"] }

    public var albumArtist: String? { values["albumArtist"] }

    public var composer: String? { values["composer"] }

    public var genre: String? { values["genre"] }

    public var comment: String? { values["comment"] }

    public var year: Int? { number("year") }

    public var trackNumber: Int? { number("trackNumber") }

    public var trackCount: Int? { number("trackCount") }

    public var discNumber: Int? { number("discNumber") }

    public var discCount: Int? { number("discCount") }

    /// Part of a compilation of several artists' songs.
    public var isCompilation: Bool { values["compilation"] == "1" }

    /// Seconds, from the stream.
    public var duration: Double? { values["duration"].flatMap(Self.decimal) }

    private func number(_ key: String) -> Int? {
        values[key].flatMap { Int($0) }
    }

    /// `562`, `562.25`: what a host sends. Parsed here: Embedded Swift
    /// can't parse a `Double` from text.
    static func decimal(_ text: String) -> Double? {
        var whole = 0.0
        var fraction = 0.0
        var scale = 1.0
        var seenPoint = false
        var digits = 0
        for byte in text.utf8 {
            if byte == UInt8(ascii: ".") {
                guard !seenPoint else { return nil }
                seenPoint = true
                continue
            }
            guard byte >= UInt8(ascii: "0"), byte <= UInt8(ascii: "9") else { return nil }
            let digit = Double(byte - UInt8(ascii: "0"))
            digits += 1
            if seenPoint {
                scale /= 10
                fraction += digit * scale
            } else {
                whole = whole * 10 + digit
            }
        }
        return digits > 0 ? whole + fraction : nil
    }

    /// From the contract's answer: keys and values in turn.
    init(tags: [String], artwork: [UInt8], artworkType: String) {
        var values: [String: String] = [:]
        var index = 0
        while index + 1 < tags.count {
            values[tags[index]] = tags[index + 1]
            index += 2
        }
        self.values = values
        self.artwork = artwork.isEmpty ? nil : .data(artwork, type: artworkType)
    }

    // MARK: Reading

    /// Reads a file's tags: in the bundle, the app's directories, or a
    /// document. With `artwork`, its cover too. Reads wait in turn, four
    /// at a time.
    public static func read(from file: FilePath, artwork: Bool = false, completion: @escaping (Result<MediaTags, MediaError>) -> Void) {
        MediaTagReads.shared.enqueue(MediaTagRead(file: file, artwork: artwork, completion: completion))
    }

    #if !EMBEDDED_NO_CONCURRENCY
    /// Reads a file's tags, and its cover with `artwork`.
    ///
    /// - Throws: `MediaError`: `notFound`, `notPermitted` for a document the
    ///   app no longer holds, `unsupportedFormat` for a file that isn't
    ///   media, `unavailable` on a host that can't read tags, and
    ///   `cancelled` when the task is cancelled.
    public static nonisolated(nonsending) func read(from file: FilePath, artwork: Bool = false) async throws(MediaError) -> MediaTags {
        let read = MediaTagRead(file: file, artwork: artwork)
        return try await withCallback { (callback: Callback<MediaTags, MediaError>) in
            read.completion = { callback.resume(with: $0) }
            MediaTagReads.shared.enqueue(read)
        } onCancel: { callback in
            MediaTagReads.shared.cancel(read)
            callback.resume(throwing: MediaError(.cancelled))
        }
    }
    #endif
}

/// One read, waiting or with the host.
final class MediaTagRead: MediaMetadataCallback {

    let file: FilePath

    let artwork: Bool

    var completion: ((Result<MediaTags, MediaError>) -> Void)?

    init(file: FilePath, artwork: Bool, completion: ((Result<MediaTags, MediaError>) -> Void)? = nil) {
        self.file = file
        self.artwork = artwork
        self.completion = completion
    }

    /// Answers once; a cancelled read has no completion left.
    private func finish(_ result: Result<MediaTags, MediaError>) {
        let completion = self.completion
        self.completion = nil
        MediaTagReads.shared.finished(self)
        completion?(result)
    }

    func didRead(_ tags: [String], artwork: [UInt8], artworkType: String) {
        finish(.success(MediaTags(tags: tags, artwork: artwork, artworkType: artworkType)))
    }

    func didFail(_ code: Int32, message: String) {
        finish(.failure(MediaError(MediaError.Code(rawValue: code) ?? .unknown, message: message)))
    }
}

/// The reads the guest has asked for: four with the host, the rest in
/// order.
final class MediaTagReads {

    nonisolated(unsafe) static let shared = MediaTagReads()

    /// How many go to the host at once.
    static let limit = 4

    private(set) var waiting: [MediaTagRead] = []

    private(set) var running: [MediaTagRead] = []

    private var made: (any MediaMetadata)?

    private var metadata: any MediaMetadata {
        if let made {
            return made
        }
        let metadata = MediaMetadataProxy.shared()
        made = metadata
        return metadata
    }

    func enqueue(_ read: MediaTagRead) {
        waiting.append(read)
        startNext()
    }

    /// The app stopped waiting: a read not yet started is dropped, and a
    /// running one's answer is let go.
    func cancel(_ read: MediaTagRead) {
        read.completion = nil
        waiting.removeAll { $0 === read }
    }

    func finished(_ read: MediaTagRead) {
        running.removeAll { $0 === read }
        startNext()
    }

    private func startNext() {
        while running.count < Self.limit, !waiting.isEmpty {
            let read = waiting.removeFirst()
            running.append(read)
            metadata.read(read.file.directory.rawValue, path: read.file.path, artwork: read.artwork, callback: read)
        }
    }

    /// Forgets the host's object and every read, for tests.
    func reset() {
        waiting = []
        running = []
        made = nil
    }
}
