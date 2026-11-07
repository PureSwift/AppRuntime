import ExampleContracts

/// Collects lines recorded by the example app.
public final class HostReporter: Reporter {

    public static func make() -> HostReporter {
        HostReporter()
    }

    public func record(_ line: String) {
        ExampleHost.lines.append(line)
    }
}
