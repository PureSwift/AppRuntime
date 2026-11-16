# Audio

> **Draft.** Nothing here is implemented: no module, no host. It specifies
> §8.8 of `DynamicRuntime.md`.

Module `DynamicAudio`: sound playback. The host decodes and mixes; the
guest says what to play. Recording isn't part of it.

| Contract | Kind | iOS / macOS | Android | Linux | Browser |
|---|---|---|---|---|---|
| `AudioOutput` | contract, `requires: "audio"` | `AVAudioEngine`, `AVAudioSession` | AAudio (through Oboe) with the host's mixer | SDL3 audio | `AudioContext` |
| `AudioOutputDelegate` | callback | | | | |
| `Sound` | contract | `AVAudioPCMBuffer`, or an `AVAudioFile` when streaming | decoded PCM, or `MediaExtractor` + `MediaCodec` when streaming | decoded PCM, or a decoder when streaming | `AudioBuffer`, or a media element when streaming |
| `Voice` | contract | `AVAudioPlayerNode` + `AVAudioUnitVarispeed` | a mixer channel | a bound `SDL_AudioStream` | `AudioBufferSourceNode` + `GainNode` + `StereoPannerNode` |
| `AudioStream` | contract | an `AVAudioSourceNode` reading a ring buffer | a ring buffer the mixer reads | `SDL_AudioStream` | an `AudioWorkletNode` reading a ring buffer |
| `AudioStreamDelegate` | callback | | | | |

These are one valid implementation each; a host may use anything that
meets the rules below. iOS 6 has no `AVAudioEngine` and uses OpenAL or
Audio Queues.

Guest-side Swift: `AudioOutputState`, `AudioError`, and `PCMBuffer`, which
packs `Int16` samples into the bytes `AudioStream.write` takes.

## Contracts

```swift
@DynamicRuntime("org.pureswift.audio.AudioOutput", requires: .audio)
protocol AudioOutput {
    static func make(_ delegate: AudioOutputDelegate) -> Self
    func state() -> Int32                               // AudioOutputState
    func resume()                                       // from a user action
    func setVolume(_ volume: Float)                     // master, 0…1
    func setMixesWithOthers(_ mixes: Bool)

    // Sounds
    func load(_ resource: String, streaming: Bool) throws -> Sound
    func decode(_ data: [UInt8]) throws -> Sound
    func play(_ sound: Sound, volume: Float, pan: Float, rate: Float, loops: Int32) -> Voice?

    // Generated audio
    func makeStream(sampleRate: Int32, channels: Int32) throws -> AudioStream
}

@DynamicCallback("org.pureswift.audio.AudioOutputDelegate")
protocol AudioOutputDelegate {
    func didChangeState(_ output: AudioOutput)
    func didFinish(_ voice: Voice)
}

@DynamicRuntime("org.pureswift.audio.Sound")
protocol Sound {
    func duration() -> Double                           // seconds
    func channels() -> Int32
}

@DynamicRuntime("org.pureswift.audio.Voice")
protocol Voice {
    func isPlaying() -> Bool
    func setPaused(_ paused: Bool)
    func setVolume(_ volume: Float)                     // 0…1
    func setPan(_ pan: Float)                           // −1 left … 1 right
    func setRate(_ rate: Float)                         // 0.5…2
    func stop()
}

@DynamicRuntime("org.pureswift.audio.AudioStream")
protocol AudioStream {
    func setDelegate(_ delegate: AudioStreamDelegate?)
    func write(_ samples: [UInt8]) -> Int32             // frames accepted
    func queuedFrames() -> Int32
    func capacity() -> Int32                            // frames
    func setPaused(_ paused: Bool)
    func setVolume(_ volume: Float)
    func clear()
}

@DynamicCallback("org.pureswift.audio.AudioStreamDelegate")
protocol AudioStreamDelegate {
    func needsFrames(_ stream: AudioStream, frames: Int32)
}
```

## Permissions

None: no host prompts for playback, so there are no authorization calls.
The manifest capability `audio` (no usage text) adds nothing on Apple
platforms or Android. On the Linux distro it's what lets the launcher bind
the sound server's socket (or `/dev/snd`) into the sandbox; without it the
app has no sound devices, and `make(_:)` returns an output whose state is
`unavailable`.

## The audio thread never enters the guest

Every platform renders audio on its own real-time thread. The guest runs
only on the main thread (§6.4), so that thread can never call it. The
contract is built around that:

- **Sounds are mixed by the host.** Starting, stopping, volume, pan and
  rate are calls from the guest; the samples never cross the boundary
  again after loading. A `play` call is heard within the device's buffer
  (typically 5–20 ms) on every host, including under an interpreter.
- **Streams are queues.** The guest writes PCM ahead of time into a
  host-side ring buffer that the audio thread drains. The queue has to
  cover the longest gap between two turns of the main thread: a frame,
  plus whatever hitches the app has. So a stream's latency is its queue
  depth, typically 50–100 ms.

Use sounds for effects and music, and a stream only for audio the guest
computes.

## Sounds

**Formats.** Every host decodes these; anything else throws
`AudioError.unsupportedFormat`:

| Format | Detail |
|---|---|
| WAV | PCM, 8- or 16-bit, mono or stereo, any sample rate |
| MP3 | mono or stereo, any bit rate |

A host may decode more (AAC, Ogg Vorbis), but an app that relies on it
isn't portable.

**Loading.**
- `load(_:streaming:)` reads a bundle resource by path, as `Bundle` does.
- `decode(_:)` takes a whole file's bytes, for sounds the app downloaded
  or generated.
- A sound is resampled to the output's rate once, when it loads.
- **`streaming: false`** decodes the whole sound into memory: right for
  effects, and it can play as many voices at once as the host has.
- **`streaming: true`** decodes as it plays: right for music, where three
  minutes of stereo would be 30 MB decoded. A streaming sound plays one
  voice at a time; a second `play` returns `nil`.

**Playing.** `play` returns a `Voice` that is already playing.

| Argument | Meaning |
|---|---|
| `volume` | 0…1 |
| `pan` | −1 left, 0 centre, 1 right; mono sounds are placed, stereo sounds are balanced |
| `rate` | 0.5…2: speed and pitch together |
| `loops` | 0 plays once, a positive count repeats that many more times, −1 loops until stopped |

- **Voices:** every host mixes at least 32 at once. Past the host's limit
  `play` returns `nil`; the guest decides what to drop.
- `didFinish` arrives when a voice ends by itself or by `stop()`, and the
  host releases its hold on it. Releasing a playing `Voice` handle doesn't
  stop it: a one-shot effect needs no bookkeeping. Keep the handle of a
  voice that loops forever, since `stop()` is the only way to end it.
- Releasing a `Sound` frees it once its voices finish.

## Streams

- **Format:** signed 16-bit little-endian PCM, interleaved, 1 or 2
  channels, at the `sampleRate` the guest asked for. The host resamples.
  A frame is one sample per channel.
- `write` copies as many whole frames as fit and returns that count; it
  never blocks.
- **`needsFrames`** is called on the main thread when the queue falls
  below half of `capacity()`, with the frames that would fill it. The
  guest answers with `write`. A game can instead write from its `frame`
  callback and ignore the delegate.
- **Underrun:** when the queue is empty the host plays silence and carries
  on. Nothing is reported; `queuedFrames()` shows how close a stream is.
- `clear()` drops what's queued, for a seek or a reset.
- A new stream is silent until the first `write`.

## State

`AudioOutputState`, from `state()` and `didChangeState`:

| Value | State | Meaning |
|---|---|---|
| 0 | `running` | sound is audible |
| 1 | `suspended` | waiting for `resume()` from a user action |
| 2 | `interrupted` | the system took the output (a call, another app); the host resumes by itself afterwards |
| 3 | `unavailable` | no output device, or no capability |

Voices and streams keep their position while the output isn't running;
they don't play on in silence.

## Platform limitations the contract accounts for

**Browsers start suspended.** An `AudioContext` makes no sound until a
user gesture. The output starts `suspended`; call `resume()` from inside
an input callback (a tap, a key, a controller button). Elsewhere the
output starts `running` and `resume()` does nothing.

**Interruptions.** A phone call or another app can take the output:
`AVAudioSession` interruptions on iOS, audio focus on Android. The host
pauses everything, reports `interrupted`, and resumes when the system
gives the output back.

**Other apps' audio.** `setMixesWithOthers(true)` lets the user's music
keep playing under the app (`AVAudioSession`'s ambient category; no audio
focus request on Android). The default, `false`, silences other apps
while this one is active. Desktop hosts always mix.

**The silent switch.** On iOS the app's sound follows the ring/silent
switch, as games do. Playback that ignores it is part of background
playback, below.

**Foreground only.** The host suspends the output when the app leaves the
foreground and resumes it on return. Background playback (a music player)
needs `UIBackgroundModes` on iOS and a foreground service on Android, and
would be a separate capability.

**Output rate.** The device decides it (44.1 or 48 kHz, usually). Guests
never need to know: sounds and streams are resampled.

**No effects.** No reverb, filters or 3D positioning. A game that needs
them mixes in the guest and uses a stream.

## Errors

`AudioError`, thrown by `load`, `decode` and `makeStream`:

| Value | Case |
|---|---|
| 1 | `notFound`: no such resource |
| 2 | `unsupportedFormat` |
| 3 | `unavailable`: no output device, or no capability |
| 4 | `invalidArgument`: a sample rate outside 8000…48000, or channels other than 1 or 2 |

## Async/await

Guest-side only (§6.2.1):

| Wrapper | Calls |
|---|---|
| `AsyncAudioOutput` | `states`: `EventStream` of `AudioOutputState`; `play(_:…) async`, which returns when the voice finishes and stops it when cancelled |
| `AsyncAudioStream` | `write(_:) async`, which suspends while the queue is full |

## Threading

Every delegate method runs on the main thread (§6.4). The host's audio
thread touches only the host's mixer and ring buffers.

## Example

```swift
final class GameAudio: AudioOutputDelegate {
    var output: AudioOutput!
    var jump: Sound!

    func start() throws {
        output = AudioOutputProxy.make(self)
        output.setMixesWithOthers(true)
        jump = try output.load("sounds/jump.wav", streaming: false)
        let music = try output.load("music/level1.mp3", streaming: true)
        _ = output.play(music, volume: 0.6, pan: 0, rate: 1, loops: -1)
    }

    func playJump() {
        _ = output.play(jump, volume: 1, pan: 0, rate: 1, loops: 0)
    }

    func didChangeState(_ output: AudioOutput) {}
    func didFinish(_ voice: Voice) {}
}
```
