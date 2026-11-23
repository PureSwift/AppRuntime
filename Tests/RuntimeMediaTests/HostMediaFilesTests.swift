import Foundation
import Testing
import DynamicFiles
import DynamicMedia
import DynamicRuntime
import RuntimeHost
import RuntimeNative
@testable import RuntimeMedia

/// Tags and tracks through the shared host, from the guest's `MediaTags`
/// and `MediaPlayer`. Part of `RuntimeMediaTests`, which is serialized.
extension RuntimeMediaTests {

    /// Reads run when the test says, and answers come back at once.
    final class Jobs: @unchecked Sendable {
        var waiting: [@Sendable () -> Void] = []
        func runAll() {
            let jobs = waiting
            waiting = []
            jobs.forEach { $0() }
        }
    }

    func heldReads() -> Jobs {
        let jobs = Jobs()
        HostMediaMetadata.reset()
        HostMediaMetadata.work = { jobs.waiting.append($0) }
        HostMediaMetadata.deliver = { $0() }
        return jobs
    }

    func read(_ file: FilePath, artwork: Bool = false) -> Result<MediaTags, MediaError>? {
        var result: Result<MediaTags, MediaError>?
        MediaTags.read(from: file, artwork: artwork) { result = $0 }
        return result
    }

    @Test func tagsAreReadOffTheMainThreadAndAnsweredOnIt() throws {
        defer { HostMediaMetadata.reset() }
        let jobs = heldReads()
        platform.tags["one.m4a"] = HostMediaTags(values: ["title": "One", "trackNumber": "3", "trackCount": "12", "duration": "61.5"], artwork: ([1, 2, 3], "image/png"))

        var result: Result<MediaTags, MediaError>?
        MediaTags.read(from: .documents / "songs/one.m4a", artwork: true) { result = $0 }
        #expect(result == nil && HostMediaMetadata.pendingCount == 1, "waiting for the read")
        #expect(platform.readPaths.isEmpty)
        jobs.runAll()
        #expect(platform.readPaths == [root.appendingPathComponent("Container/Documents/songs/one.m4a").path], "found as a player's file is")
        let tags = try #require(try result?.get())
        #expect(tags.title == "One" && tags.trackNumber == 3 && tags.trackCount == 12 && tags.duration == 61.5)
        #expect(tags.artwork == .data([1, 2, 3], type: "image/png"))
        #expect(HostMediaMetadata.pendingCount == 0)

        // Without asking for it, no cover.
        MediaTags.read(from: .documents / "songs/one.m4a") { result = $0 }
        jobs.runAll()
        #expect(try result?.get().artwork == nil)
    }

    @Test func aReadFailsAsAFileWould() throws {
        defer { HostMediaMetadata.reset() }
        let jobs = heldReads()
        func code(_ result: Result<MediaTags, MediaError>?) -> MediaError.Code? {
            if case .failure(let error)? = result { return error.code }
            return nil
        }
        #expect(code(read(.documents / "songs/missing.mp3")) == .notFound, "answered at once, without a read")
        #expect(code(read(.documents / "songs")) == .notFound, "a directory")

        var result: Result<MediaTags, MediaError>?
        MediaTags.read(from: .documents / "cover.jpg") { result = $0 }
        jobs.runAll()
        #expect(code(result) == .unsupportedFormat, "the platform's answer")

        HostMediaPlayback.findFile = { _, _ throws(FileError) in throw .notPermitted }
        #expect(code(read(.documents / "songs/one.m4a")) == .notPermitted, "a document the app no longer holds")
    }

    @Test func aPlatformThatDoesntReadTagsSaysSo() throws {
        defer { HostMediaMetadata.reset() }
        let jobs = heldReads()
        HostMediaPlayback.platform = QuietPlatform()
        var result: Result<MediaTags, MediaError>?
        MediaTags.read(from: .documents / "songs/one.m4a") { result = $0 }
        jobs.runAll()
        if case .failure(let error)? = result { #expect(error.code == .unavailable) } else { Issue.record("read without a reader") }

        HostMediaPlayback.platform = nil
        result = read(.documents / "songs/one.m4a")
        if case .failure(let error)? = result { #expect(error.code == .unavailable) } else { Issue.record("read without a platform") }
    }

    @Test func numbersAndCountsAreSplit() {
        #expect(HostMediaTags.numberAndCount("3/12") == (3, 12))
        #expect(HostMediaTags.numberAndCount(" 4 / 9 ") == (4, 9))
        #expect(HostMediaTags.numberAndCount("7") == (7, nil))
        #expect(HostMediaTags.numberAndCount("A/B") == (nil, nil))
        #expect(HostMediaTags(values: ["b": "2", "a": "1"]).list == ["a", "1", "b", "2"], "sorted, so answers are the same each time")
    }

    @Test func tracksGoBetweenTheEngineAndThePlayer() throws {
        let (player, engine) = try loaded()
        let host = try #require(engine.player)
        host.tracksChanged(
            audio: [HostMediaTrack(name: "English", language: "en"), HostMediaTrack(name: "Deutsch", language: "de")],
            subtitles: [HostMediaTrack(name: "Français", language: "fr")],
            selectedAudio: 0, selectedSubtitle: nil
        )
        #expect(player.audioTracks.map(\.name) == ["English", "Deutsch"])
        #expect(player.subtitleTracks.first?.language == "fr")
        #expect(player.selectedAudioTrack?.name == "English" && player.selectedSubtitleTrack == nil)

        player.selectedSubtitleTrack = player.subtitleTracks.first
        player.selectedAudioTrack = nil
        #expect(engine.calls.suffix(2) == ["selectTrack subtitles 0", "selectTrack audio default"])

        // An index the engine got wrong is none.
        host.tracksChanged(audio: [], subtitles: [], selectedAudio: 3, selectedSubtitle: -2)
        #expect(player.audioTracks.isEmpty && player.selectedAudioTrack == nil)

        // While another file loads, nothing goes either way. The player
        // keeps its engine.
        player.load(.file(.documents / "songs/one.m4a"))
        #expect(platform.engines.last === engine)
        let calls = engine.calls.count
        host.tracksChanged(audio: [HostMediaTrack(name: "Early")], subtitles: [], selectedAudio: 0, selectedSubtitle: nil)
        #expect(player.audioTracks.isEmpty)
        host.selectTrack(0, index: 0)
        #expect(!engine.calls.dropFirst(calls).contains { $0.hasPrefix("selectTrack") })
    }
}
