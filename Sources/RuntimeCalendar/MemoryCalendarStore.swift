import DynamicCalendar
import Foundation

/// A calendar store in memory, which expands repeating events itself: for
/// a host's tests, and as the contract's rules in their plainest form for
/// a host writing a store over its platform's own to compare with.
///
/// It is not a store an app's events should be in, and `HostCalendars`
/// never uses it unasked: it holds nothing after the process ends, and
/// syncs with nothing.
///
/// It expands daily, weekly, monthly and yearly rules, with an interval,
/// days of the week (and the first, second or last of them in a month),
/// days of the month, months, set positions, a count and an end. Anything
/// else is `unsupportedRecurrence`.
public final class MemoryCalendarStore: CalendarStore, @unchecked Sendable {

    private struct Series {

        /// The event as saved: for one that repeats, its first occurrence.
        var master: Event

        /// Occurrences deleted by themselves.
        var removed: Set<Int64> = []

        /// Occurrences changed by themselves, by their own start.
        var detached: [Int64: Event] = [:]
    }

    private let lock = NSLock()

    private var calendarList: [EventCalendar]

    private var defaultIdentifier: String?

    private var series: [String: Series] = [:]

    private var nextIdentifier = 1

    /// The device's zone, for events that name none.
    private let timeZone: TimeZone

    /// The most occurrences one event is expanded into.
    private static let maximumOccurrences = 20_000

    public init(
        calendars: [EventCalendar] = [EventCalendar(id: "local", title: "Calendar")],
        defaultCalendar: String? = nil,
        timeZone: TimeZone = TimeZone(identifier: "UTC")!
    ) {
        self.calendarList = calendars
        self.defaultIdentifier = defaultCalendar ?? calendars.first { $0.isWritable }?.id
        self.timeZone = timeZone
    }

    /// How many events it holds, a repeating one counted once.
    public var count: Int {
        lock.withLock { series.count }
    }

    private func locked<Value>(_ body: () throws(EventStoreError) -> Value) throws(EventStoreError) -> Value {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    // MARK: Calendars

    public func calendars() throws(EventStoreError) -> [EventCalendar] {
        lock.withLock { calendarList }
    }

    public func defaultCalendar() throws(EventStoreError) -> EventCalendar? {
        lock.withLock { calendarList.first { $0.id == defaultIdentifier } }
    }

    // MARK: Reading

    public func events(from start: Int64, to end: Int64, in calendars: [String]) throws(EventStoreError) -> [Event] {
        try locked { () throws(EventStoreError) in
            var found: [Event] = []
            for series in series.values {
                let master = series.master
                guard calendars.isEmpty || calendars.contains(master.calendar ?? "") else { continue }
                guard master.recurrence != nil else {
                    if master.overlaps(start, end) {
                        found.append(master)
                    }
                    continue
                }
                // An occurrence moved by itself may be in the range though
                // its own start isn't.
                for event in series.detached.values where event.overlaps(start, end) {
                    found.append(event)
                }
                // An occurrence that starts before the range can still
                // reach into it.
                for occurrence in try starts(of: master, before: end)
                where !series.removed.contains(occurrence) && series.detached[occurrence] == nil {
                    var event = master
                    event.start = occurrence
                    event.end = occurrence + master.duration
                    event.occurrence = occurrence
                    if event.overlaps(start, end) {
                        found.append(event)
                    }
                }
            }
            return found
        }
    }

    public func event(withID identifier: String) throws(EventStoreError) -> Event? {
        lock.withLock { series[identifier]?.master }
    }

    // MARK: Writing

    public func save(_ event: Event, span: EventSpan) throws(EventStoreError) -> Event {
        try locked { () throws(EventStoreError) in
            guard let identifier = event.id else {
                return try insert(event)
            }
            guard var existing = series[identifier] else {
                throw .notFound
            }
            guard existing.master.recurrence != nil else {
                let updated = try whole(event, calendar: existing.master.calendar)
                series[identifier] = Series(master: updated)
                return updated
            }
            let occurrence = event.occurrence ?? existing.master.start
            switch span {
            case .thisEvent:
                guard event.recurrence == existing.master.recurrence else {
                    throw .invalidSpan
                }
                var detached = event
                detached.calendar = existing.master.calendar
                detached.occurrence = occurrence
                detached.isDetached = true
                existing.detached[occurrence] = detached
                existing.removed.remove(occurrence)
                series[identifier] = existing
                return detached
            case .futureEvents:
                if occurrence <= existing.master.start {
                    // From the first occurrence on: the whole event.
                    let updated = try whole(event, calendar: existing.master.calendar)
                    series[identifier] = Series(master: updated)
                    return updated
                }
                // The old rule ends before this occurrence, and a new
                // event starts from it.
                var started = event
                started.id = nil
                started.calendar = event.calendar ?? existing.master.calendar
                let new = try insert(started)
                truncate(&existing, before: occurrence)
                series[identifier] = existing
                return new
            }
        }
    }

    public func remove(_ event: Event, span: EventSpan) throws(EventStoreError) {
        try locked { () throws(EventStoreError) in
            guard let identifier = event.id, var existing = series[identifier] else {
                throw .notFound
            }
            guard existing.master.recurrence != nil else {
                series[identifier] = nil
                return
            }
            let occurrence = event.occurrence ?? existing.master.start
            switch span {
            case .thisEvent:
                existing.removed.insert(occurrence)
                existing.detached[occurrence] = nil
                series[identifier] = existing
            case .futureEvents:
                if occurrence <= existing.master.start {
                    series[identifier] = nil
                } else {
                    truncate(&existing, before: occurrence)
                    series[identifier] = existing
                }
            }
        }
    }

    /// A new event, with an identifier of its own.
    private func insert(_ event: Event) throws(EventStoreError) -> Event {
        var new = try whole(event, calendar: defaultIdentifier)
        let identifier = "event-\(nextIdentifier)"
        nextIdentifier += 1
        new.id = identifier
        series[identifier] = Series(master: new)
        return new
    }

    /// An event as the store keeps a whole one: in a calendar, with a rule
    /// it can expand, and marked as its own first occurrence.
    private func whole(_ event: Event, calendar: String?) throws(EventStoreError) -> Event {
        var event = event
        event.calendar = event.calendar ?? calendar
        event.isDetached = false
        event.occurrence = event.recurrence == nil ? nil : event.start
        // Refuses a rule it can't expand before anything is kept.
        _ = try starts(of: event, before: event.start + 1)
        return event
    }

    /// Ends a rule before an occurrence, and forgets what was changed
    /// from there on.
    private func truncate(_ series: inout Series, before occurrence: Int64) {
        // A second before, which is as fine as a rule's text says.
        series.master.recurrence?.end = .until(occurrence - 1000)
        series.removed = series.removed.filter { $0 < occurrence }
        series.detached = series.detached.filter { $0.key < occurrence }
    }

    // MARK: Repeats

    /// The starts of an event's occurrences that are before `limit`, in
    /// order, the first included.
    private func starts(of master: Event, before limit: Int64) throws(EventStoreError) -> [Int64] {
        guard let rule = master.recurrence else {
            return master.start < limit ? [master.start] : []
        }
        var weekStart = RecurrenceRule.Weekday.monday
        for part in rule.otherParts {
            guard part.hasPrefix("WKST="), let day = RecurrenceRule.Weekday(code: String(part.dropFirst(5))) else {
                throw .unsupportedRecurrence
            }
            weekStart = day
        }
        switch rule.frequency {
        case .daily, .weekly, .monthly, .yearly:
            break
        case .secondly, .minutely, .hourly:
            throw .unsupportedRecurrence
        }
        if rule.frequency == .yearly, rule.monthsOfYear.isEmpty, rule.daysOfWeek.contains(where: { $0.week != 0 }) {
            // The nth weekday of the year.
            throw .unsupportedRecurrence
        }

        var calendar = Foundation.Calendar(identifier: .gregorian)
        if master.isAllDay {
            calendar.timeZone = TimeZone(identifier: "UTC")!
        } else {
            calendar.timeZone = master.timeZone.flatMap { TimeZone(identifier: $0) } ?? timeZone
        }
        let first = Date(timeIntervalSince1970: Double(master.start) / 1000)
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: first)
        guard let year = parts.year, let month = parts.month, let day = parts.day else {
            throw .unsupportedRecurrence
        }
        let base = CivilDate(year: year, month: month, day: day)
        let subsecond = ((master.start % 1000) + 1000) % 1000

        /// A day at the event's time, in its zone.
        func moment(_ date: CivilDate) -> Int64? {
            var components = DateComponents()
            components.year = date.year
            components.month = date.month
            components.day = date.day
            components.hour = parts.hour
            components.minute = parts.minute
            components.second = parts.second
            guard let moment = calendar.date(from: components) else { return nil }
            return Int64((moment.timeIntervalSince1970 * 1000).rounded()) + subsecond
        }

        var limitCount: Int?
        var until: Int64?
        switch rule.end {
        case .never: break
        case .count(let count): limitCount = count
        case .until(let end): until = end
        }

        var starts: [Int64] = []
        var counted = 0
        var period = 0
        while period < Self.maximumOccurrences {
            let (periodStart, candidates) = Self.candidates(rule, base: base, period: period * rule.interval, weekStart: weekStart)
            period += 1
            // A period that begins a day or more after the limit has
            // nothing before it, whatever the zone.
            if periodStart.millisecondsSince1970 - 86_400_000 >= limit {
                break
            }
            for date in Self.positions(candidates, rule.setPositions) {
                guard let start = moment(date), start >= master.start else { continue }
                if let until, start > until {
                    return starts
                }
                counted += 1
                if start < limit {
                    starts.append(start)
                    if starts.count >= Self.maximumOccurrences {
                        return starts
                    }
                }
                if let limitCount, counted >= limitCount {
                    return starts
                }
            }
        }
        return starts
    }

    /// The days a rule gives in one period, in order, with the period's
    /// first day: the `period`th day, week, month or year from the first
    /// occurrence's.
    private static func candidates(
        _ rule: RecurrenceRule, base: CivilDate, period: Int, weekStart: RecurrenceRule.Weekday
    ) -> (start: CivilDate, days: [CivilDate]) {
        let wantsMonth: (Int) -> Bool = { rule.monthsOfYear.isEmpty || rule.monthsOfYear.contains($0) }
        switch rule.frequency {
        case .daily:
            let date = CivilDate(days: base.days + Int64(period))
            var matches = wantsMonth(date.month)
            if !rule.daysOfMonth.isEmpty {
                matches = matches && monthDays(rule, date.year, date.month).contains(date.day)
            }
            if !rule.daysOfWeek.isEmpty {
                matches = matches && rule.daysOfWeek.contains { $0.weekday == date.weekday }
            }
            return (date, matches ? [date] : [])
        case .weekly:
            let offset = (base.weekday.rawValue - weekStart.rawValue + 7) % 7
            let start = CivilDate(days: base.days - Int64(offset) + Int64(period) * 7)
            let wanted = rule.daysOfWeek.isEmpty ? [base.weekday] : rule.daysOfWeek.map { $0.weekday }
            var days: [CivilDate] = []
            for index in 0..<7 {
                let date = CivilDate(days: start.days + Int64(index))
                if wanted.contains(date.weekday), wantsMonth(date.month) {
                    days.append(date)
                }
            }
            return (start, days)
        case .monthly:
            let months = base.year * 12 + (base.month - 1) + period
            let year = months / 12
            let month = months % 12 + 1
            let start = CivilDate(year: year, month: month, day: 1)
            guard wantsMonth(month) else { return (start, []) }
            return (start, days(rule, year, month, base: base).map { CivilDate(year: year, month: month, day: $0) })
        case .yearly:
            let year = base.year + period
            let start = CivilDate(year: year, month: 1, day: 1)
            let months = rule.monthsOfYear.isEmpty ? [base.month] : rule.monthsOfYear.sorted()
            var found: [CivilDate] = []
            for month in months {
                found += days(rule, year, month, base: base).map { CivilDate(year: year, month: month, day: $0) }
            }
            return (start, found)
        case .secondly, .minutely, .hourly:
            return (base, [])
        }
    }

    private static func daysInMonth(_ year: Int, _ month: Int) -> Int {
        let next = month == 12 ? CivilDate.days(year: year + 1, month: 1, day: 1) : CivilDate.days(year: year, month: month + 1, day: 1)
        return Int(next - CivilDate.days(year: year, month: month, day: 1))
    }

    /// The days of the month a rule names, counted from the end where
    /// they're negative.
    private static func monthDays(_ rule: RecurrenceRule, _ year: Int, _ month: Int) -> [Int] {
        let length = daysInMonth(year, month)
        return rule.daysOfMonth.map { $0 > 0 ? $0 : length + $0 + 1 }.filter { $0 >= 1 && $0 <= length }
    }

    /// The days of one month a monthly or yearly rule gives, in order.
    private static func days(_ rule: RecurrenceRule, _ year: Int, _ month: Int, base: CivilDate) -> [Int] {
        let length = daysInMonth(year, month)
        var byWeekday: [Int] = []
        for wanted in rule.daysOfWeek {
            let matching = (1...length).filter { CivilDate(year: year, month: month, day: $0).weekday == wanted.weekday }
            if wanted.week == 0 {
                byWeekday += matching
            } else if wanted.week > 0, wanted.week <= matching.count {
                byWeekday.append(matching[wanted.week - 1])
            } else if wanted.week < 0, -wanted.week <= matching.count {
                byWeekday.append(matching[matching.count + wanted.week])
            }
        }
        let byMonthDay = monthDays(rule, year, month)
        let days: [Int]
        switch (rule.daysOfWeek.isEmpty, rule.daysOfMonth.isEmpty) {
        case (true, true):
            // The day the event began on, in the months that have it.
            days = base.day <= length ? [base.day] : []
        case (false, true):
            days = byWeekday
        case (true, false):
            days = byMonthDay
        case (false, false):
            days = byWeekday.filter { byMonthDay.contains($0) }
        }
        return Array(Set(days)).sorted()
    }

    /// The occurrences of one period a rule's set positions keep: all of
    /// them when it names none.
    private static func positions(_ candidates: [CivilDate], _ positions: [Int]) -> [CivilDate] {
        guard !positions.isEmpty else { return candidates }
        var kept: [CivilDate] = []
        for position in positions {
            let index = position > 0 ? position - 1 : candidates.count + position
            if index >= 0, index < candidates.count, !kept.contains(candidates[index]) {
                kept.append(candidates[index])
            }
        }
        return kept.sorted { $0.days < $1.days }
    }
}
