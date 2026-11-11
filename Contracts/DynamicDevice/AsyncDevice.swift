#if !EMBEDDED_NO_CONCURRENCY
import DynamicRuntime
#if hasFeature(Embedded)
// Embedded Swift doesn't import the concurrency module implicitly.
import _Concurrency
#endif

/// A change reported by `Device`.
public enum DeviceEvent: Equatable, Sendable {

    /// 0 to 1, or -1 if unknown.
    case batteryLevel(Float)

    case batteryState(BatteryState)

    case lowPowerMode(Bool)

    case thermalState(ThermalState)

    case orientation(DeviceOrientation)

    /// Whether something is near the proximity sensor.
    case proximity(near: Bool)
}

/// Async/await over `Device` (§6.2.1): its changes as an `EventStream`. The
/// guest-side convenience layer; native hosts never see it.
///
/// ```swift
/// let device = AsyncDevice()
/// for await event in device.events(battery: true) {
///     if case .thermalState(.serious) = event { reduceWork() }
/// }
/// ```
///
/// The stream turns on the monitoring it asks for, and turns it off again
/// when the stream is released or its task is cancelled. Low power and
/// thermal changes need no monitoring. One stream at a time: starting one
/// finishes the previous one. The guest is single-threaded (§6.4).
public final class AsyncDevice: @unchecked Sendable {

    /// The underlying contract object, for its properties.
    public let device: any Device

    let events: DeviceEvents

    public init() {
        self.device = DeviceProxy.current()
        self.events = DeviceEvents()
    }

    /// Changes until the stream is released or its task is cancelled.
    ///
    /// - Parameters:
    ///   - battery: Battery level and state changes.
    ///   - orientation: Orientation changes.
    ///   - proximity: Proximity changes; where the host has a sensor, it also
    ///     turns the screen off while something is near.
    public func events(battery: Bool = true, orientation: Bool = false, proximity: Bool = false) -> EventStream<DeviceEvent, Never> {
        let (stream, continuation) = EventStream<DeviceEvent, Never>.makeStream()
        events.stream?.finish()
        events.generation &+= 1
        let generation = events.generation
        events.stream = continuation
        continuation.onTermination = { [events, device] in
            guard events.generation == generation else { return }
            events.stream = nil
            device.setDelegate(nil)
            if battery {
                device.setBatteryMonitoringEnabled(false)
            }
            if orientation {
                device.setOrientationUpdatesEnabled(false)
            }
            if proximity {
                device.setProximityMonitoringEnabled(false)
            }
        }
        device.setDelegate(events)
        if battery {
            device.setBatteryMonitoringEnabled(true)
        }
        if orientation {
            device.setOrientationUpdatesEnabled(true)
        }
        if proximity {
            device.setProximityMonitoringEnabled(true)
        }
        return stream
    }
}

/// The delegate behind `AsyncDevice`.
final class DeviceEvents: DeviceDelegate {

    var stream: EventStream<DeviceEvent, Never>.Continuation?

    var generation = 0

    func didChangeBatteryLevel(_ device: any Device, level: Float) {
        stream?.yield(.batteryLevel(level))
    }

    func didChangeBatteryState(_ device: any Device, state: Int32) {
        stream?.yield(.batteryState(BatteryState(rawValue: state) ?? .unknown))
    }

    func didChangeLowPowerMode(_ device: any Device, enabled: Bool) {
        stream?.yield(.lowPowerMode(enabled))
    }

    func didChangeThermalState(_ device: any Device, state: Int32) {
        stream?.yield(.thermalState(ThermalState(rawValue: state) ?? .nominal))
    }

    func didChangeOrientation(_ device: any Device, orientation: Int32) {
        stream?.yield(.orientation(DeviceOrientation(rawValue: orientation) ?? .unknown))
    }

    func didChangeProximityState(_ device: any Device, near: Bool) {
        stream?.yield(.proximity(near: near))
    }
}
#endif
