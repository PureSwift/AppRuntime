# Game controllers

> **Draft.** Nothing here is implemented: no module, no host. It specifies
> §8.7 of `DynamicRuntime.md`.

Module `DynamicGameController`: gamepads, as one standard layout on every
host.

| Contract | Kind | iOS / macOS | Android | Linux | Browser |
|---|---|---|---|---|---|
| `GameControllerManager` | contract, `requires: "gameControllers"` | `GCController` notifications | `InputManager.InputDeviceListener` | SDL3 gamepad events | `gamepadconnected` / `gamepaddisconnected` |
| `GameControllerManagerDelegate` | callback | | | | |
| `GameController` | contract | `GCExtendedGamepad` | `InputDevice`, `KeyEvent`, `MotionEvent` | `SDL_Gamepad` | `Gamepad` with `mapping == "standard"` |
| `GameControllerDelegate` | callback | | | | |

Guest-side Swift: `GameControllerButton`, `GameControllerAxis`,
`GameControllerStyle`, and a `GameControllerState` struct that mirrors a
controller from its delegate calls, so game code reads sticks and buttons
each frame without crossing into the host.

## Contracts

```swift
@DynamicRuntime("org.pureswift.input.GameControllerManager", requires: .gameControllers)
protocol GameControllerManager {
    static func make(_ delegate: GameControllerManagerDelegate) -> Self
    func controllers() -> [GameController]
}

@DynamicCallback("org.pureswift.input.GameControllerManagerDelegate")
protocol GameControllerManagerDelegate {
    func didConnect(_ controller: GameController)
    func didDisconnect(_ controller: GameController)
}

@DynamicRuntime("org.pureswift.input.GameController")
protocol GameController {
    func name() -> String                       // "Xbox Wireless Controller"
    func style() -> Int32                       // GameControllerStyle
    func supports(_ button: Int32) -> Bool
    func setDelegate(_ delegate: GameControllerDelegate?)

    // The state now, for when a delegate is first set.
    func buttons() -> Int32                     // bit n set: button n is pressed
    func value(_ button: Int32) -> Float        // 0…1
    func axis(_ axis: Int32) -> Float           // −1…1

    func playerIndex() -> Int32                 // −1: none
    func setPlayerIndex(_ index: Int32)
    func supportsRumble() -> Bool
    func rumble(low: Float, high: Float, milliseconds: Int32)
}

@DynamicCallback("org.pureswift.input.GameControllerDelegate")
protocol GameControllerDelegate {
    func didChangeButton(_ controller: GameController, button: Int32,
                         pressed: Bool, value: Float, timestamp: Int64)
    func didChangeAxis(_ controller: GameController, axis: Int32,
                       value: Float, timestamp: Int64)
}
```

## Permissions

None: no host prompts for game controllers, so there are no authorization
calls. The manifest capability `gameControllers` (no usage text) is for
packaging and the sandbox:

| Host | What the capability adds |
|---|---|
| iOS / macOS | `GCSupportsControllerUserInteraction` and `GCSupportedGameControllers` (`ExtendedGamepad`) in `Info.plist` |
| Android | `<uses-feature android:name="android.hardware.gamepad">`, `required="false"` unless the capability is `.required()` |
| Linux distro | the launcher binds joystick-class `/dev/input/event*` nodes into the sandbox, and no others: a keyboard's node would let the app read every key typed |
| Browser | nothing |

## One layout

Buttons are named by **position**, not by label, because A and B swap
between Xbox and Nintendo controllers. The numbers are the W3C standard
mapping's button indices.

| Value | `GameControllerButton` | Xbox | PlayStation | Nintendo |
|---|---|---|---|---|
| 0 | `south` | A | Cross | B |
| 1 | `east` | B | Circle | A |
| 2 | `west` | X | Square | Y |
| 3 | `north` | Y | Triangle | X |
| 4, 5 | `leftShoulder`, `rightShoulder` | LB, RB | L1, R1 | L, R |
| 6, 7 | `leftTrigger`, `rightTrigger` | LT, RT | L2, R2 | ZL, ZR |
| 8 | `back` | View | Create / Share | − |
| 9 | `start` | Menu | Options | + |
| 10, 11 | `leftStick`, `rightStick` (click) | LS, RS | L3, R3 | stick click |
| 12–15 | `dpadUp`, `dpadDown`, `dpadLeft`, `dpadRight` | | | |
| 16 | `guide` | Xbox | PS | Home |

| Value | `GameControllerAxis` | Range |
|---|---|---|
| 0, 1 | `leftX`, `leftY` | −1…1; **right and up are positive** |
| 2, 3 | `rightX`, `rightY` | the same |

New buttons and axes (paddles, a touchpad) may be added later with new
values; a guest ignores values it doesn't know.

`GameControllerStyle` says which labels to draw and which face button
confirms: 0 unknown, 1 Xbox, 2 PlayStation, 3 Nintendo.

## One convention for values

The platforms disagree on signs, ranges and what a trigger is. Hosts
convert, so game code never branches on the platform:

| Quantity | Contract | iOS / macOS | Android | SDL3 | Browser |
|---|---|---|---|---|---|
| Stick y | up is positive | same | down is positive: host negates | negates | negates |
| Stick range | −1…1 | same | same | −32768…32767: host scales | same |
| Triggers | a button with `value` 0…1, `pressed` as the platform reports or above 0.5 | `GCControllerButtonInput` | `AXIS_LTRIGGER` / `AXIS_BRAKE` and the right-hand pair | axes 0…32767 | `buttons[6]`, `buttons[7]` |
| D-pad | four buttons | `GCControllerDirectionPad` | `AXIS_HAT_X` / `AXIS_HAT_Y` or `KEYCODE_DPAD_*` | buttons | `buttons[12…15]` |
| Timestamps | nanoseconds on the `Clock.now()` timeline | `lastEventTimestamp` | `getEventTime()` | event timestamp | `Gamepad.timestamp` |

**Dead zones.** A stick at rest reports exactly 0. Where the platform
doesn't apply a dead zone (SDL3, browsers), the host applies a radial one.

## Platform limitations the contract accounts for

**Only the standard layout.** Flight sticks, wheels and devices the
platform can't map aren't reported. On a browser that means gamepads whose
`mapping` is empty.

**Changes are events, and scalars.** Each change is one dispatch with no
handles to release, like Motion's samples. A host sends **at most one
`didChangeAxis` per axis per frame**, so a stick sweeping across its range
costs four dispatches a frame at most. Button changes are never dropped or
merged: a press and release inside one frame arrive as two calls.

**Initial state.** A delegate hears only changes. `buttons()`, `value(_:)`
and `axis(_:)` give the state when the delegate is set;
`GameControllerState` reads them once and follows the delegate after that.

**No stuck buttons.** When the app stops being active or a controller
disconnects, the host reports every pressed button released and every axis
at 0 before anything else, and stops rumble.

**Browsers hide controllers until used.** A page sees a gamepad only after
the user presses a button on it, so `controllers()` starts empty and
`didConnect` arrives at the first press. Browsers also have no events for
input: the host polls `navigator.getGamepads()` each animation frame and
reports the differences.

**The guide button** often belongs to the system (on iOS it opens the
system's own game overlay). Where the app can't see it, `supports(_:)`
reports `false` for `guide`.

**Android's Back.** Android turns an unhandled B button into Back. The
host consumes the controller's button events while a delegate is set, so
`east` doesn't also leave the screen.

**Player index.** It lights the controller's player LEDs where the
platform allows (`GCController.playerIndex`, `SDL_SetGamepadPlayerIndex`).
Android and browsers assign it themselves: `setPlayerIndex` does nothing
there, and `playerIndex()` reports theirs.

**Rumble.** `low` and `high` are the strengths (0…1) of the low- and
high-frequency motors, for `milliseconds`; both 0 stops. A new call
replaces the last. The host caps the duration at 5 seconds, so a stalled
guest can't leave a controller buzzing.

| Host | Rumble |
|---|---|
| iOS 14+ / macOS 11+ | `GCController.haptics` (Core Haptics) |
| Android | the device's `VibratorManager` (API 31+) or `Vibrator` |
| Linux | `SDL_RumbleGamepad` |
| Browser | `vibrationActuator.playEffect("dual-rumble")` |

`supportsRumble()` is `false` everywhere else.

**Older systems.** iOS 6 has no controller API: `controllers()` is empty.
Xbox and PlayStation controllers pair with iOS 13 and later; before that,
only MFi controllers.

**Built-in controls** (a Steam Deck, a handheld running a PortMaster
build, a clip-on controller) appear as a controller like any other.

**The UI doesn't follow the controller.** Whether a controller moves focus
between SwiftUI controls is the player's choice and isn't part of this
contract (open question, §15).

## Async/await

Guest-side only (§6.2.1):

| Wrapper | Streams |
|---|---|
| `AsyncGameControllers` | `connections`: `EventStream` of `.connected(GameController)` / `.disconnected(GameController)` |
| `GameControllerState` | not a stream: a struct kept current by the delegate, read each frame |

## Threading

Every delegate method runs on the main thread (§6.4), between frames.
Hosts hop from the platform's input thread first.

## Example

```swift
final class Player: GameControllerDelegate {
    var state = GameControllerState()

    func didChangeButton(_ controller: GameController, button: Int32,
                         pressed: Bool, value: Float, timestamp: Int64) {
        state.set(button, pressed: pressed, value: value)
        if button == GameControllerButton.south.rawValue, pressed { jump() }
    }

    func didChangeAxis(_ controller: GameController, axis: Int32,
                       value: Float, timestamp: Int64) {
        state.set(axis, value: value)
    }
}

// In SurfaceDelegate.frame:
move(x: player.state.leftX, y: player.state.leftY)
```
