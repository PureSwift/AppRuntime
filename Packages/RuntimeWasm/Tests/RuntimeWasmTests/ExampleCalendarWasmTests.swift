import Foundation
import Testing
import DynamicCalendar
import DynamicRuntime
import DynamicUI
import RuntimeABI
import RuntimeCalendar
import RuntimeHost
import RuntimeNative
import RuntimeWasm

/// A moment in UTC, in milliseconds since 1970.
private func moment(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0) -> Int64 {
    CivilDate.days(year: year, month: month, day: day) * 86_400_000 + Int64(hour) * 3_600_000
}

/// The agenda's lines: every text that begins with a date.
private func agenda(_ node: RenderNode?) -> [String] {
    guard let node else { return [] }
    var lines: [String] = []
    if node.type == "Text", case .string(let text)? = node.props["text"], text.hasPrefix("20"), text.contains(" ") {
        lines.append(text)
    }
    for child in node.children {
        lines += agenda(child)
    }
    return lines
}

/// The example calendar app as App.wasm under WasmKit, with the shared
/// host implementation over a store in memory: the guest's `EventStore`,
/// the `Calendars` contract and its records, and `HostCalendars`, end to
/// end, with the store expanding the repeats. Part of `WasmShimTests`,
/// which is serialized, since both use `NativeRuntime.shared`.
extension WasmShimTests {

    /// Built by `Scripts/build-wasm.sh ExampleCalendar`; skipped without it.
    static var exampleCalendarURL: URL {
        exampleUIURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ExampleCalendar/wasm32/App.wasm")
    }

    @Test(.enabled(if: FileManager.default.fileExists(atPath: WasmShimTests.exampleCalendarURL.path), "Build the wasm slice first: Scripts/build-wasm.sh ExampleCalendar"))
    func exampleCalendarInWasmMode() throws {
        let native = NativeRuntime.shared
        native.capabilities = nil
        RendererProxy.register(WasmTestRenderer.self, in: native)
        RendererDelegateProxy.registerInterface(in: native)
        let memory = MemoryCalendarStore(calendars: [
            EventCalendar(id: "home", title: "Home"),
            EventCalendar(id: "holidays", title: "Holidays", isWritable: false),
        ])
        var questions = 0
        HostCalendars.reset()
        HostCalendars.store = memory
        HostCalendars.requester = { completion in
            questions += 1
            completion(.full)
        }
        HostCalendars.work = { $0() }
        HostCalendars.deliver = { $0() }
        HostCalendarsModule.register(in: native)
        defer { HostCalendars.reset() }
        WasmTestRenderer.last = nil

        let bytes = Array(try Data(contentsOf: Self.exampleCalendarURL))
        let app = try WasmApp(bytes: bytes, runtime: native.runtime, capabilities: [.calendars])
        let contracts = try #require(WasmApp.contracts(of: app.module))
        #expect(contracts.first { $0.name == "org.pureswift.calendar.Calendars" }?.capability == .calendars)
        #expect(try app.start() == .ok)
        let renderer = try #require(WasmTestRenderer.last)
        func text(_ identifier: String) -> PropValue? {
            renderer.screen?.identified(identifier)?.props["text"]
        }
        func tap(_ title: String) throws {
            renderer.send(try #require(renderer.screen?.button(title)), .tap)
        }
        func lines() -> [String] {
            agenda(renderer.screen)
        }

        // Nothing is read before the user is asked.
        #expect(text("month") == "2026-11" && text("status") == "Not asked" && lines().isEmpty && questions == 0)
        try tap("Add Standup")
        #expect(text("status") == "Not allowed" && memory.count == 0)
        try tap("Allow")
        #expect(questions == 1 && text("status") == "Nothing on")

        // A weekly meeting is one event in the store, and four in the month.
        try tap("Add Standup")
        #expect(memory.count == 1 && text("status") == "4 events")
        #expect(lines() == [3, 10, 17, 24].map { "2026-11-\($0 < 10 ? "0" : "")\($0) 09:00 Standup, weekly" }, "the store expanded it")
        let standup = try #require(try memory.event(withID: "event-1"))
        #expect(standup.calendar == "home" && standup.location == "Room 4" && standup.alarms == [.before(minutes: 10)])
        #expect(standup.recurrence?.rrule == "FREQ=WEEKLY;BYDAY=TU;COUNT=4" && standup.duration == 1_800_000)

        // An all-day event is whole days in UTC.
        try tap("Add Day Off")
        #expect(lines() == [
            "2026-11-03 09:00 Standup, weekly", "2026-11-09 all day Day off", "2026-11-10 09:00 Standup, weekly",
            "2026-11-17 09:00 Standup, weekly", "2026-11-24 09:00 Standup, weekly",
        ], "in order")
        let dayOff = try #require(try memory.event(withID: "event-2"))
        #expect(dayOff.isAllDay && dayOff.start == moment(2026, 11, 9) && dayOff.end == moment(2026, 11, 10))

        // One occurrence is moved by itself.
        try tap("Move Second")
        #expect(lines()[2] == "2026-11-10 10:00 Standup, moved" && lines().count == 5 && memory.count == 2)
        #expect(lines()[3] == "2026-11-17 09:00 Standup, weekly", "the others stay")

        // The rest of the series is cancelled from the third on.
        try tap("Cancel From Third")
        #expect(lines() == ["2026-11-03 09:00 Standup, weekly", "2026-11-09 all day Day off", "2026-11-10 10:00 Standup, moved"])
        #expect(text("status") == "3 events" && memory.count == 2, "the rule ends; the event stays")

        // Another app adds an event, and the store says so.
        var dentist = Event(title: "Dentist", start: moment(2026, 11, 12, 15), end: moment(2026, 11, 12, 16))
        dentist.calendar = "home"
        _ = try memory.save(dentist, span: .thisEvent)
        #expect(lines().count == 3, "not seen until the store says")
        HostCalendars.storeChanged()
        #expect(lines().last == "2026-11-12 15:00 Dentist" && text("status") == "4 events")

        // Another month.
        try tap("Next")
        #expect(text("month") == "2026-12" && text("status") == "Nothing on" && lines().isEmpty)
        try tap("Add Standup")
        #expect(lines().first == "2026-12-01 09:00 Standup, weekly" && lines().count == 4, "December begins on a Tuesday")
        try tap("Previous")
        #expect(text("month") == "2026-11" && lines().count == 4)

        // The user takes the access back in the system's settings.
        HostCalendars.access = .denied
        try tap("Next")
        #expect(text("status") == "Not allowed")
        #expect(questions == 1, "asked once")
    }
}
