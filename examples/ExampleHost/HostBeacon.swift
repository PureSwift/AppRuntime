import ExampleContracts

/// The host's `Beacon` implementation.
public final class HostBeacon: Beacon {

    public static func make() -> HostBeacon {
        HostBeacon()
    }

    public func identifier() -> String {
        "beacon-1"
    }
}
