import Testing
import DynamicFiles
@testable import DynamicMedia
import DynamicRuntime
import DynamicSwiftUI
import RuntimeNative

/// A host that reads tags when the test says: it keeps each read's callback.
final class ScriptedMetadata: MediaMetadata {

    nonisolated(unsafe) static let instance = ScriptedMetadata()

    static func shared() -> ScriptedMetadata { instance }

    var reads: [(file: String, artwork: Bool, callback: any MediaMetadataCallback)] = []

    func read(_ directory: Int32, path: String, artwork: Bool, callback: any MediaMetadataCallback) {
        reads.append(("\(directory) \(path)", artwork, callback))
    }
}

/// Tags and tracks, against scripted hosts. Part of `DynamicMediaTests`,
/// which is serialized.
extension DynamicMediaTests {

    func metadataHost() -> ScriptedMetadata {
        let native = NativeRuntime.shared
        MediaMetadataProxy.register(ScriptedMetadata.self, in: native)
        MediaMetadataCallbackProxy.registerInterface(in: native)
        MediaTagReads.shared.reset()
        ScriptedMetadata.instance.reads = []
        return ScriptedMetadata.instance
    }

    // MARK: Contracts

    @Test func tagsAreAContractOfTheirOwn() {
        let metadata = MediaMetadataProxy.descriptor
        #expect(metadata.name == "org.pureswift.media.Metadata")
        #expect(metadata.capability == nil, "reading a file plays nothing")
        #expect(method(metadata, "shared")?.kind == .constructor)
        #expect(method(metadata, "read:path:artwork:callback:")?.signature == Signature("(IOZO)V"))
        let callback = MediaMetadataCallbackProxy.descriptor
        #expect(callback.kind == .callback)
        #expect(method(callback, "didRead:artwork:artworkType:")?.signature == Signature("(OOO)V"))
        #expect(method(callback, "didFail:message:")?.signature == Signature("(IO)V"))

        #expect(method(MediaPlaybackProxy.descriptor, "selectTrack:index:")?.signature == Signature("(II)V"))
        #expect(method(MediaPlaybackDelegateProxy.descriptor, "didChangeTracks:audioLanguages:subtitleNames:subtitleLanguages:selectedAudio:selectedSubtitle:")?.signature == Signature("(OOOOII)V"))
        let descriptors = [metadata, callback]
        #expect(ContractMetadata.decode(descriptors.flatMap(ContractMetadata.encode)) == descriptors)
    }

    // MARK: Tags

    @Test func tagsComeFromTheHostsKeys() throws {
        let host = metadataHost()
        var results: [Result<MediaTags, MediaError>] = []
        MediaTags.read(from: .documents / "Music/so-what.mp3", artwork: true) { results.append($0) }
        let read = try #require(host.reads.first)
        #expect(read.file == "0 Music/so-what.mp3" && read.artwork)
        read.callback.didRead([
            "title", "So What", "artist", "Miles Davis", "album", "Kind of Blue",
            "trackNumber", "1", "trackCount", "5", "discNumber", "one", "year", "1959",
            "duration", "562.25", "compilation", "1", "TCOP", "1959 Columbia", "dangling",
        ], artwork: [0xFF, 0xD8, 0xFF], artworkType: "image/jpeg")

        let tags = try #require(try results.first?.get())
        #expect(tags.title == "So What" && tags.artist == "Miles Davis" && tags.album == "Kind of Blue")
        #expect(tags.trackNumber == 1 && tags.trackCount == 5 && tags.year == 1959)
        #expect(tags.discNumber == nil, "a number that isn't one")
        #expect(tags.duration == 562.25)
        #expect(tags.isCompilation)
        #expect(tags.genre == nil && tags.albumArtist == nil)
        #expect(tags.values["TCOP"] == "1959 Columbia", "a key the type doesn't name")
        #expect(tags.values["dangling"] == nil, "a key without a value")
        #expect(tags.artwork == .data([0xFF, 0xD8, 0xFF], type: "image/jpeg"))

        // A file with no tags: everything nil but what the stream says.
        MediaTags.read(from: .bundle / "music/morning.mp3") { results.append($0) }
        try #require(host.reads.last).callback.didRead(["duration", "3"], artwork: [], artworkType: "")
        let bare = try #require(try results.last?.get())
        #expect(bare.title == nil && bare.artwork == nil && bare.duration == 3 && !bare.isCompilation)
    }

    @MainActor @Test func failuresAreMediaErrors() async throws {
        let host = metadataHost()
        let reading = Task { @MainActor in try await MediaTags.read(from: .documents / "gone.mp3") }
        while host.reads.isEmpty {
            await Task.yield()
        }
        host.reads[0].callback.didFail(MediaError.Code.notFound.rawValue, message: "no such file")
        await #expect(throws: MediaError(.notFound, message: "no such file")) { try await reading.value }

        var result: Result<MediaTags, MediaError>?
        MediaTags.read(from: .documents / "odd.bin") { result = $0 }
        host.reads[1].callback.didFail(99, message: "newer")
        #expect(result.map { if case .failure(let error) = $0 { error.code == .unknown } else { false } } == true)
    }

    @Test func fourReadsGoToTheHostAtOnce() throws {
        let host = metadataHost()
        var answered: [String] = []
        for name in ["a", "b", "c", "d", "e", "f"] {
            MediaTags.read(from: .documents / "\(name).mp3") { result in
                answered.append((try? result.get().title) ?? "failed")
            }
        }
        #expect(host.reads.map(\.file) == ["0 a.mp3", "0 b.mp3", "0 c.mp3", "0 d.mp3"])
        #expect(MediaTagReads.shared.waiting.count == 2)

        // Answers in any order; the next waiting read starts with each.
        host.reads[2].callback.didRead(["title", "C"], artwork: [], artworkType: "")
        #expect(host.reads.map(\.file).last == "0 e.mp3")
        host.reads[0].callback.didFail(MediaError.Code.unsupportedFormat.rawValue, message: "")
        #expect(host.reads.map(\.file).last == "0 f.mp3")
        #expect(host.reads.count == 6 && MediaTagReads.shared.waiting.isEmpty)
        for index in [1, 3, 4, 5] {
            host.reads[index].callback.didRead(["title", "\(index)"], artwork: [], artworkType: "")
        }
        #expect(answered == ["C", "failed", "1", "3", "4", "5"])
        #expect(MediaTagReads.shared.running.isEmpty)
    }

    @MainActor @Test func aCancelledReadIsDropped() async throws {
        let host = metadataHost()
        for name in ["a", "b", "c", "d"] {
            MediaTags.read(from: .documents / "\(name).mp3") { _ in }
        }
        // A fifth waits, and its task is cancelled.
        let waiting = Task { @MainActor in try await MediaTags.read(from: .documents / "e.mp3") }
        while MediaTagReads.shared.waiting.isEmpty {
            await Task.yield()
        }
        waiting.cancel()
        await #expect(throws: MediaError(.cancelled)) { try await waiting.value }
        #expect(MediaTagReads.shared.waiting.isEmpty, "dropped before it reached the host")
        host.reads[0].callback.didRead([], artwork: [], artworkType: "")
        #expect(host.reads.count == 4, "nothing left to start")
    }

    @Test func durationsAreDecimalText() {
        #expect(MediaTags.decimal("562") == 562)
        #expect(MediaTags.decimal("562.25") == 562.25)
        #expect(MediaTags.decimal("0.5") == 0.5)
        #expect(MediaTags.decimal(".5") == 0.5)
        #expect(MediaTags.decimal("") == nil)
        #expect(MediaTags.decimal(".") == nil)
        #expect(MediaTags.decimal("1.2.3") == nil)
        #expect(MediaTags.decimal("-3") == nil)
        #expect(MediaTags.decimal("1e3") == nil)
    }

    // MARK: Tracks

    @Test func tracksComeFromTheHostAndAreChosen() throws {
        let (player, host) = try loaded()
        #expect(player.audioTracks.isEmpty && player.subtitleTracks.isEmpty)

        nonisolated(unsafe) var changes = 0
        _ = withObservationTracking { player.subtitleTracks } onChange: { changes += 1 }
        host.delegate.didChangeTracks(["English", "Deutsch"], audioLanguages: ["en", "de"], subtitleNames: ["English", "Français", "Commentary"], subtitleLanguages: ["en", "fr", ""], selectedAudio: 0, selectedSubtitle: -1)
        #expect(changes == 1)
        #expect(player.audioTracks.map(\.name) == ["English", "Deutsch"])
        #expect(player.subtitleTracks.map(\.language) == ["en", "fr", nil], "empty is no language")
        #expect(player.selectedAudioTrack?.name == "English")
        #expect(player.selectedSubtitleTrack == nil, "off")

        // The app chooses.
        player.selectedSubtitleTrack = player.subtitleTracks.first { $0.language == "fr" }
        #expect(host.calls.last == "selectTrack 1 1")
        #expect(player.selectedSubtitleTrack?.name == "Français")
        player.selectedAudioTrack = player.audioTracks.last
        #expect(host.calls.last == "selectTrack 0 1")
        player.selectedSubtitleTrack = nil
        #expect(host.calls.last == "selectTrack 1 -1")
        player.selectedAudioTrack = nil
        #expect(host.calls.last == "selectTrack 0 -1", "the file's default")
        let calls = host.calls.count

        // The user chooses in the platform's controls.
        host.delegate.didChangeTracks(["English", "Deutsch"], audioLanguages: ["en", "de"], subtitleNames: ["English", "Français", "Commentary"], subtitleLanguages: ["en", "fr", ""], selectedAudio: 1, selectedSubtitle: 2)
        #expect(player.selectedAudioTrack?.language == "de")
        #expect(player.selectedSubtitleTrack?.name == "Commentary")
        #expect(host.calls.count == calls, "nothing asked back")

        // A track from another file isn't chosen; an index out of range is
        // none.
        let elsewhere = player.subtitleTracks[0]
        host.delegate.didChangeTracks([], audioLanguages: [], subtitleNames: ["Español"], subtitleLanguages: ["es"], selectedAudio: 4, selectedSubtitle: 0)
        #expect(player.selectedAudioTrack == nil)
        player.selectedSubtitleTrack = elsewhere
        #expect(player.selectedSubtitleTrack?.name == "Español")
        #expect(host.calls.count == calls)

        // Another file: no tracks until it says.
        player.load(.url("https://example.com/other.mp4"))
        host.delegate.didChangeState(MediaState.loading.rawValue, reason: 0)
        #expect(player.subtitleTracks.isEmpty && player.selectedSubtitleTrack == nil)
    }
}
