import DynamicRuntime
import DynamicCalendar
// Guest builds call the frontend `SwiftUI`; host builds of this package
// can't, since Apple's SDK has one. A guest package just says `import SwiftUI`.
#if canImport(DynamicSwiftUI)
import DynamicSwiftUI
#else
import SwiftUI
#endif

/// The example calendar app: a month's agenda. It asks for the user's
/// calendars, lists what's on in a month, one line for each occurrence,
/// adds a weekly meeting and a day off, moves one occurrence, cancels the
/// rest of a series, and looks again whenever the store says it changed.

/// One line of the agenda.
struct Line: Identifiable {
    let id: String
    let text: String
}

/// The closures hold the agenda, which lives as long as the app does:
/// Embedded Swift has no weak or unowned references. The guest is
/// single-threaded (§6.4), which the compiler can't see.
@Observable
final class Agenda: @unchecked Sendable {

    var status: String = "Not asked"

    var lines: [Line] = []

    /// The month shown: months since January of year 0.
    var month: Int = 2026 * 12 + 10

    /// What's on in the month, as the store gave it.
    @ObservationIgnored var events: [Event] = []

    @ObservationIgnored let store = EventStore.default

    var year: Int { month / 12 }

    var monthOfYear: Int { month % 12 + 1 }

    var title: String {
        "\(year)-\(Self.two(monthOfYear))"
    }

    /// 00:00 UTC on the first of a month.
    static func start(ofMonth month: Int) -> Int64 {
        CivilDate(year: month / 12, month: month % 12 + 1, day: 1).millisecondsSince1970
    }

    static func time(_ day: Int, _ hour: Int, in month: Int) -> Int64 {
        start(ofMonth: month) + Int64(day - 1) * 86_400_000 + Int64(hour) * 3_600_000
    }

    func start() {
        // The store says when anything changes, this app's own saves
        // included: one place to look again.
        store.onChange {
            self.reload()
        }
        show(store.access)
    }

    func allow() {
        store.requestAccess { access in
            self.show(access)
        }
    }

    func show(_ access: EventStoreAccess) {
        switch access {
        case .full:
            reload()
        case .writeOnly:
            status = "This app may only add events"
        case .notDetermined:
            status = "Not asked"
        case .unavailable:
            status = "No calendars here"
        default:
            status = "Not allowed"
        }
    }

    func step(_ months: Int) {
        month += months
        reload()
    }

    func reload() {
        let shown = month
        store.events(from: Self.start(ofMonth: shown), to: Self.start(ofMonth: shown + 1)) { result in
            // Another month was asked for meanwhile.
            guard shown == self.month else { return }
            switch result {
            case .success(let events):
                self.events = events
                self.lines = events.map { Line(id: "\($0.id ?? "")@\($0.occurrence ?? $0.start)", text: Self.describe($0)) }
                self.status = events.isEmpty ? "Nothing on" : "\(events.count) events"
            case .failure(let error):
                self.report(error)
            }
        }
    }

    /// A meeting every Tuesday at nine, four times, with a reminder.
    func addStandup() {
        let first = CivilDate(millisecondsSince1970: Self.start(ofMonth: month))
        // The month's first Tuesday.
        let offset = (RecurrenceRule.Weekday.tuesday.rawValue - first.weekday.rawValue + 7) % 7
        let start = Self.time(1 + offset, 9, in: month)
        var event = Event(title: "Standup", start: start, end: start + 1_800_000)
        event.location = "Room 4"
        event.alarms = [.before(minutes: 10)]
        event.recurrence = RecurrenceRule(.weekly, daysOfWeek: [.tuesday], end: .count(4))
        save(event, span: .thisEvent)
    }

    /// The ninth, all day.
    func addDayOff() {
        let start = Self.time(9, 0, in: month)
        save(Event(title: "Day off", start: start, end: start + 86_400_000, isAllDay: true), span: .thisEvent)
    }

    /// Moves the second occurrence of the meeting an hour later, alone.
    func moveSecond() {
        guard var event = standups.dropFirst().first else {
            status = "No second standup"
            return
        }
        event.start += 3_600_000
        event.end += 3_600_000
        save(event, span: .thisEvent)
    }

    /// Cancels the meeting from its third occurrence on.
    func cancelFromThird() {
        guard let event = standups.dropFirst(2).first else {
            status = "No third standup"
            return
        }
        store.remove(event, span: .futureEvents) { result in
            if case .failure(let error) = result {
                self.report(error)
            }
        }
    }

    var standups: [Event] {
        events.filter { $0.title == "Standup" }
    }

    func save(_ event: Event, span: EventSpan) {
        store.save(event, span: span) { result in
            if case .failure(let error) = result {
                self.report(error)
            }
        }
    }

    func report(_ error: EventStoreError) {
        switch error {
        case .notAuthorized: status = "Not allowed"
        case .unavailable: status = "No calendars here"
        case .readOnly: status = "That calendar can't be changed"
        default: status = "Calendar error \(error.rawValue)"
        }
    }

    static func two(_ value: Int) -> String {
        value < 10 ? "0\(value)" : "\(value)"
    }

    /// "2026-11-03 09:00 Standup, weekly": in UTC, which is enough for an
    /// example. An app formats with `DateFormat`, in the user's zone.
    static func describe(_ event: Event) -> String {
        let date = CivilDate(millisecondsSince1970: event.start)
        var text = "\(date.year)-\(two(date.month))-\(two(date.day))"
        if event.isAllDay {
            text += " all day"
        } else {
            let minutes = Int((event.start % 86_400_000 + 86_400_000) % 86_400_000 / 60_000)
            text += " \(two(minutes / 60)):\(two(minutes % 60))"
        }
        text += " " + event.title
        if event.isDetached {
            text += ", moved"
        } else if event.recurrence?.frequency == .weekly {
            text += ", weekly"
        }
        return text
    }
}

struct ContentView: View {

    let agenda: Agenda

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(agenda.title)
                .accessibilityIdentifier("month")
            Text(agenda.status)
                .accessibilityIdentifier("status")
            HStack(spacing: 8) {
                Button("Allow") { agenda.allow() }
                Button("Previous") { agenda.step(-1) }
                Button("Next") { agenda.step(1) }
            }
            HStack(spacing: 8) {
                Button("Add Standup") { agenda.addStandup() }
                Button("Add Day Off") { agenda.addDayOff() }
                Button("Move Second") { agenda.moveSecond() }
                Button("Cancel From Third") { agenda.cancelFromThird() }
            }
            ForEach(agenda.lines) { line in
                Text(line.text)
            }
        }
        .padding()
    }
}

struct ExampleCalendarApp: App {

    let agenda = Agenda()

    init() {
        agenda.start()
    }

    var body: some Scene {
        WindowGroup {
            ContentView(agenda: agenda)
        }
    }
}

/// The app's entry point. The host calls it once after loading the slice.
@_expose(wasm, "rt_main")
@c(rt_main)
public func exampleCalendarMain() -> rt_status {
    Runtime.main { ExampleCalendarApp.run() }
}
