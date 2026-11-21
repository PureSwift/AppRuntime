# Calendar events

**Status:** implemented in this repository: the guest side, and the part
of the host side every host written in Swift shares. No platform host has
a calendar store behind it yet, so no real calendar has been read: the
tests keep the events in memory.

Module `DynamicCalendar`: the user's calendars and the events in them, as
the system keeps them. EventKit's place.

The store is the system's, not the app's. The accounts are set up in the
system and synced by it; an app reads what's there and changes it. The
Calendar app is a client of it, and so is a mail app that adds an
invitation.

| Contract | Kind | iOS / macOS | Android | Linux | Browser |
|---|---|---|---|---|---|
| `Calendars` | contract, `requires: .calendars` | `EKEventStore` | `CalendarContract`, through the `ContentResolver` | the host's calendar service | none |
| `CalendarRecord` | contract: one calendar | `EKCalendar` | a row of `Calendars` | | |
| `CalendarEventRecord` | contract: one event, or one occurrence of it | `EKEvent` | a row of `Events`, or of `Instances` | | |
| `CalendarCallback` | callback: one operation's result | | | | |
| `CalendarsDelegate` | callback: the store changed | `EKEventStoreChanged` | a `ContentObserver` | | |

Guest-side Swift:

- **`EventStore`**: the store app code uses. `EKEventStore`'s place.
- **`Event`**, **`EventCalendar`**: values, as the app reads and writes
  them.
- **`RecurrenceRule`**, `EventAlarm`, `EventSpan`, `EventAvailability`,
  `EventStoreAccess`, `EventStoreError`, and `CivilDate`, for the days an
  all-day event is on.

The render IR doesn't change.

Host-side Swift, in `RuntimeCalendar`: `HostCalendars`, the contract over
a host's `CalendarStore`, and `MemoryCalendarStore`.

## What shapes it

- **The system syncs.** iOS and Android already hold the user's Google,
  iCloud and Exchange calendars and keep them current. An app here needs
  no CalDAV and no accounts of its own. On Linux that work is the host's
  calendar service.
- **The system expands repeats.** An app asks for what happens between
  two dates and gets every occurrence, one by one. Both platforms do
  this themselves. A guest needs no recurrence code.
- **A rule is still data.** An app shows "every second Tuesday" and lets
  the user change it, so the rule crosses as text: an RFC 5545 `RRULE`,
  which is what Android stores and what an invitation carries.
- **Two levels of access.** iOS lets an app add events without reading
  any. A mail app wants only that. The Calendar app wants everything.
- **An event belongs to a calendar,** and some calendars can't be
  changed: holidays, a subscription, someone else's.
- **A day isn't a moment.** An all-day event is on the 5th everywhere,
  whatever the time zone.

## For a guest

```swift
import DynamicCalendar

let store = EventStore.default

guard try await store.requestAccess() == .full else { return }

// What's on this month.
let calendars = try await store.calendars()
let events = try await store.events(from: monthStart, to: monthEnd)

// A new event.
var lunch = Event(title: "Lunch with Ada", start: start, end: start + 3_600_000)
lunch.location = "Canteen"
lunch.alarms = [.before(minutes: 15)]
lunch.recurrence = RecurrenceRule(.weekly, daysOfWeek: [.tuesday], end: .count(10))
lunch = try await store.save(lunch)              // now it has an identifier

// Move one occurrence; delete the series from here on.
var next = events[3]
next.start += 3_600_000
next.end += 3_600_000
try await store.save(next, span: .thisEvent)
try await store.remove(next, span: .futureEvents)
```

### Access

| `EventStore` | |
|---|---|
| `access` | `.notDetermined`, `.denied`, `.restricted`, `.writeOnly`, `.full`, `.unavailable`. Never asks |
| `requestAccess()` | asks the user if they haven't decided, for what the manifest declares |

- **The manifest says which level** the app wants (below). An app can't
  ask for more than it declared.
- **`.writeOnly` can `save` a new event and nothing else.** Every read
  fails with `notAuthorized`: the calendars, the events, and an event's
  own identifier afterwards.
- **`Permissions` works too,** as for any capability. `.writeOnly` is its
  `limited`.
- **Asking has no `async throws`:** `requestAccess()` gives the level the
  app has afterwards, whatever happened.

### Calendars

| `EventCalendar` | |
|---|---|
| `id` | the store's identifier for it |
| `title` | "Work", "Holidays in Ireland" |
| `account` | the account it comes from: "iCloud", an email address. Empty for one that's only on the device |
| `color` | `0xAARRGGBB` |
| `isWritable` | whether events can be added and changed |

- `store.calendars()` gives them all, in the system's order.
- `store.defaultCalendar()` is where the user wants new events, or `nil`
  when no calendar can be written.
- Calendars are read. Making, renaming and deleting them is the
  system's settings'.

### Events

```swift
let events = try await store.events(from: start, to: end, in: [work, home])
```

- **One `Event` per occurrence.** A weekly meeting is four events in a
  month. They share `id` and differ in `occurrence`, the start the rule
  gave that one.
- **Whatever overlaps the range,** sorted by start, then by title.
- **A range is at most four years.** More fails with `invalidRange`.
  EventKit has that limit.
- **`in:`** is the calendars to look in; none means all.
- **`store.event(withID:)`** is one event by its identifier: the first
  occurrence of a repeating one.

| `Event` | |
|---|---|
| `id` | `nil` until it's saved |
| `calendar` | an `EventCalendar.id`; `nil` on a new event means the default |
| `title`, `location`, `notes`, `url` | text |
| `start`, `end` | milliseconds since 1970, as `DateFormat` takes them |
| `isAllDay` | see below |
| `timeZone` | an IANA name: where 9:00 means 9:00 as the clocks change. `nil` is the device's |
| `recurrence` | a `RecurrenceRule`, or `nil` |
| `occurrence` | this occurrence's own start, before any change to it. `nil` for an event that doesn't repeat |
| `isDetached` | an occurrence that was changed by itself |
| `alarms` | `[EventAlarm]`: `.before(minutes:)` |
| `availability` | `.busy`, `.free`, `.tentative`, `.unavailable`, or `.notSupported` |

- **An all-day event** has `start` at 00:00 UTC of its first day and
  `end` at 00:00 UTC of the day after its last. It's on those days in
  every time zone. Format it with a UTC `DateFormat`. One given loosely
  is rounded out to whole days when it's saved.
- **`CivilDate`** turns a year, month and day into such a moment and
  back, and says the weekday: a guest has no Foundation to ask.
- **An `Event` is a value.** It can be kept, compared and copied. To
  change one the store has, change the value and save it: its `id` and
  `occurrence` say which event it is.
- **A `DatePicker`'s value is seconds;** these are milliseconds.

### Saving and removing

| | |
|---|---|
| `save(_:span:)` | adds a new event, or changes one. Gives the event back as the store now has it |
| `remove(_:span:)` | deletes it |

`span` matters only for an event that repeats:

| `EventSpan` | |
|---|---|
| `.thisEvent` (the default) | this occurrence alone |
| `.futureEvents` | this occurrence and every one after it |

- **Changing the rule needs `.futureEvents`.** With `.thisEvent` a
  changed rule fails with `invalidSpan`.
- **A calendar that isn't writable** fails with `readOnly`.
- **`end` before `start`** fails with `invalidDates`.
- **What the app didn't touch is kept:** attendees, attachments, and
  whatever else the store holds that isn't here.

### Repeating

```swift
RecurrenceRule(.daily)
RecurrenceRule(.weekly, interval: 2, daysOfWeek: [.monday, .wednesday])
RecurrenceRule(.monthly, daysOfMonth: [1, 15], end: .until(millisecondsSince1970))
RecurrenceRule(.monthly, daysOfWeek: [.friday], setPositions: [-1])     // the last Friday
RecurrenceRule(.monthly, daysOfWeek: [.nth(2, .tuesday)])               // the second Tuesday
RecurrenceRule(.yearly, end: .count(5))
RecurrenceRule(rrule: "FREQ=WEEKLY;BYDAY=TU;COUNT=10")
```

| `RecurrenceRule` | |
|---|---|
| `frequency` | `.daily`, `.weekly`, `.monthly`, `.yearly`; and RFC 5545's `.hourly`, `.minutely` and `.secondly`, which a store may refuse |
| `interval` | every how many: 1 or more |
| `daysOfWeek`, `daysOfMonth`, `monthsOfYear`, `setPositions` | which ones, as RFC 5545 has them |
| `end` | `.never`, `.count(_:)`, `.until(_:)` |
| `rrule` | the rule as text |

- **`init?(rrule:)` reads any rule,** and keeps the parts it has no
  property for in `otherParts`, so saving it back loses nothing.
- **A store may refuse a rule it can't hold:** `unsupportedRecurrence`.
  The forms above work everywhere.
- **`.until` is to the second.** A rule's text says no finer.

### Changes

```swift
for await _ in store.changes {
    reload()
}
```

The store says that something changed, not what: another app, a sync, or
this app. `store.onChange { … }` is the same with a closure. Fetch again.

### Errors

| `EventStoreError` | |
|---|---|
| `notAuthorized` | no access, or not enough for this call |
| `unavailable` | this host has no calendar store |
| `notFound` | the event or calendar is gone |
| `readOnly` | the calendar can't be changed |
| `invalidDates`, `invalidRange`, `invalidSpan` | see above |
| `unsupportedRecurrence` | a rule this store can't hold |
| `cancelled` | the task waiting was cancelled |

## The contract

```swift
@DynamicRuntime("org.pureswift.calendar.Calendars", requires: .calendars)
public protocol Calendars: AnyObject {

    static func shared() -> Self

    /// An `EventStoreAccess` raw value. Never asks.
    func access() -> Int32
    /// Answered by `didChangeAccess`.
    func requestAccess(_ callback: CalendarCallback)

    func setDelegate(_ delegate: CalendarsDelegate?)

    /// Answered by `didListCalendars`.
    func calendars(_ callback: CalendarCallback)
    /// Answered by `didFindCalendar`.
    func defaultCalendar(_ callback: CalendarCallback)

    /// Occurrences that overlap the range, in the calendars named; none
    /// named is all. Milliseconds since 1970. Answered by `didListEvents`.
    func events(_ start: Int64, end: Int64, calendars: [String], callback: CalendarCallback)
    /// Answered by `didFindEvent`.
    func event(_ identifier: String, callback: CalendarCallback)

    /// An event to fill in and save: a new one, until it's told which
    /// event it is.
    func makeEvent() -> CalendarEventRecord
}

@DynamicRuntime("org.pureswift.calendar.Calendar")
public protocol CalendarRecord: AnyObject {
    func identifier() -> String
    func title() -> String
    func account() -> String
    func color() -> Int32                    // 0xAARRGGBB
    func isWritable() -> Bool
}

@DynamicRuntime("org.pureswift.calendar.Event")
public protocol CalendarEventRecord: AnyObject {

    /// Empty until it's saved.
    func identifier() -> String
    func calendar() -> String
    func title() -> String
    func location() -> String
    func notes() -> String
    func url() -> String
    func start() -> Int64
    func end() -> Int64
    func isAllDay() -> Bool
    /// An IANA name; empty for the device's zone.
    func timeZone() -> String
    /// An RFC 5545 `RRULE` value; empty for an event that doesn't repeat.
    func recurrence() -> String
    /// This occurrence's own start; -1 for an event that doesn't repeat.
    func occurrence() -> Int64
    func isDetached() -> Bool
    /// Minutes before the start, as decimal numbers with commas between.
    func alarms() -> String
    /// An `EventAvailability` raw value.
    func availability() -> Int32

    /// Which event this is, to change one the store has; -1 for no
    /// occurrence.
    func setIdentity(_ identifier: String, occurrence: Int64)
    func setCalendar(_ identifier: String)
    func setText(_ title: String, location: String, notes: String, url: String)
    func setDates(_ start: Int64, end: Int64, allDay: Bool, timeZone: String)
    func setRecurrence(_ rule: String)
    func setAlarms(_ minutes: String)
    func setAvailability(_ availability: Int32)

    /// `span`: 0 this occurrence, 1 this and the ones after.
    /// Answered by `didFindEvent`, with the event as saved.
    func save(_ span: Int32, callback: CalendarCallback)
    /// Answered by `didComplete`.
    func remove(_ span: Int32, callback: CalendarCallback)
}

@DynamicCallback("org.pureswift.calendar.Callback")
public protocol CalendarCallback: AnyObject {
    func didComplete()
    func didChangeAccess(_ access: Int32)
    func didListCalendars(_ calendars: [CalendarRecord])
    func didFindCalendar(_ calendar: CalendarRecord?)
    func didListEvents(_ events: [CalendarEventRecord])
    func didFindEvent(_ event: CalendarEventRecord?)
    /// An `EventStoreError` raw value.
    func didFail(_ error: Int32)
}

@DynamicCallback("org.pureswift.calendar.Delegate")
public protocol CalendarsDelegate: AnyObject {
    func didChange()
}
```

A record is the host's object. The guest reads one into an `Event` value
when it arrives, and lets it go. To save, it asks for a record with
`makeEvent`, fills it in from the value, identity included, and tells it
to save: the host finds the event by its identifier.

### Rules every host follows

- **Every answer is on the main thread, once.** The store is read and
  written off it.
- **Occurrences are the store's own expansion.** The host doesn't work
  out repeats itself where the platform does.
- **`events` gives what overlaps the range:** it ends after the range
  starts and starts before it ends. Sorted by start, then title, then
  identifier. A range over four years is `invalidRange`.
- **Times are milliseconds since 1970.** An all-day event is from 00:00
  UTC of its first day to 00:00 UTC of the day after its last, whatever
  the platform stores.
- **A rule is an `RRULE` value,** without the `RRULE:` in front. The host
  writes one for every rule its platform holds, and stores every rule
  its platform can. One it can't is `unsupportedRecurrence`, and nothing
  is saved.
- **A save writes what the guest set and keeps the rest.**
- **`span` 0 on a repeating event makes or changes a detached
  occurrence.** `span` 1 ends the old rule before this occurrence and,
  for a save, starts a new event from it.
- **Without read access, nothing is read:** `calendars`, `events`,
  `event`, and a saved record's getters all answer `notAuthorized` or
  empty. A save still works.
- **`didChange` is sent after any change to the store,** this app's
  included, and not more than once for a burst of them.
- **Alarms are relative.** One at a fixed time is given as minutes
  before the start.

## The shared host

`HostCalendars`, in `RuntimeCalendar`, over a host's `CalendarStore`,
which works in the guest's own values:

```swift
public protocol CalendarStore: AnyObject, Sendable {   // off the main thread, one call at a time
    func calendars() throws(EventStoreError) -> [EventCalendar]
    func defaultCalendar() throws(EventStoreError) -> EventCalendar?
    func events(from start: Int64, to end: Int64, in calendars: [String]) throws(EventStoreError) -> [Event]
    func event(withID identifier: String) throws(EventStoreError) -> Event?
    func save(_ event: Event, span: EventSpan) throws(EventStoreError) -> Event
    func remove(_ event: Event, span: EventSpan) throws(EventStoreError)
}

HostCalendars.store = MyEventStore()
HostCalendars.declaredAccess = .full               // RTCapabilityOptions.calendars.access
HostCalendars.access = .notDetermined              // what the platform says now
HostCalendars.requester = { completion in … }       // the platform's question
HostCalendarsModule.register(in: runtime)

HostCalendars.storeChanged()                       // from the platform
```

A store gets a `RecurrenceRule`, already read from its text, so a host
over EventKit turns one into an `EKRecurrenceRule` without parsing.

- **Access:** what the user granted, capped by what the manifest
  declares, and checked before every call. The user is asked once, and a
  requester that answers twice is heard once. A write-only save gives
  back an event with no identifier.
- **Before a store sees a save:** the dates, the rule, the calendar it's
  going to and the one it's in, and for one occurrence that the rule is
  unchanged. An all-day event is rounded out to whole days.
- **Ranges** over four years, or backwards, are refused. What a store
  returns is sorted by start, title and identifier.
- **Threads:** the store is called off the main thread in order, and
  every answer is on it.
- **Changes:** a burst of `storeChanged` is one `didChange`, and this
  app's own saves and removals are said too.
- **`MemoryCalendarStore`** is a store in memory that expands rules
  itself: for tests, and as the rules in their plainest form. It is not
  a default. Without a store, every call fails with `unavailable`.

## The manifest

```swift
capabilities: [.calendars(.full, usage: "Shows your events and lets you change them.")]
capabilities: [.calendars(.writeOnly, usage: "Adds invitations you accept to your calendar.")]
```

| | `.full` | `.writeOnly` |
|---|---|---|
| iOS / macOS | `NSCalendarsFullAccessUsageDescription` | `NSCalendarsWriteOnlyAccessUsageDescription` |
| Android | `READ_CALENDAR` and `WRITE_CALENDAR` | `WRITE_CALENDAR` |
| Linux | the calendar service on the session bus | the same; the host refuses reads |
| Browser | nothing: there's no store | |

The option reaches a host as `RTCapabilityOptions.calendars.access`.

## Per host

From each platform's documentation. None of it has been tried.

| | Notes |
|---|---|
| iOS 17+ / macOS 14+ | `EKEventStore`, with `requestFullAccessToEvents` and `requestWriteOnlyAccessToEvents`. `events(matching:)` over `predicateForEvents(withStart:end:calendars:)` gives occurrences, and takes at most four years. `save(_:span:)` and `remove(_:span:)` are the contract's. `EKRecurrenceRule` holds frequency, interval, days, months, positions and an end, which the host writes as an `RRULE` and reads from one. An absolute `EKAlarm` becomes minutes before. `EKEventStoreChanged` for `didChange`. Before iOS 17 there is one level, `requestAccess(to:)`. |
| Android | `CalendarContract`. `Instances` for a range, `Events` for one. `RRULE` and `DTSTART` are stored as text, so a rule passes through. An all-day event is already UTC midnights. One occurrence is changed through `Events.CONTENT_EXCEPTION_URI`; this and the ones after is an `UNTIL` on the old event and a new event. `Reminders` rows for alarms. A `ContentObserver` for `didChange`. |
| Linux | The host's calendar service, which holds the accounts and syncs them. What it is isn't decided: the core apps plan had the Calendar app sync for itself. |
| Browser | No calendar store exists. `access` is `.unavailable`. |

## Not in this design

- **Reminders and tasks,** which EventKit keeps beside events.
- **Attendees and replying to an invitation.** A save keeps the
  attendees an event has; an app can't read or change them.
- **Making, renaming and deleting calendars,** and accounts.
- **The system's own add-event sheet,** which needs no permission at
  all. It would suit a mail app better than write-only access, and it's
  the one thing a browser host could do, by handing over an `.ics` file.
- **Attachments, structured locations with coordinates, travel time.**
- **Alarms at a place,** and alarms with a sound of the app's.
- **Birthdays,** which come from contacts.
- **Reading or writing `.ics` files.** That's a guest library.
- **What changed.** `didChange` says only that something did.

## Example and tests

`examples/ExampleCalendar` is a month's agenda: it asks for access, lists
each occurrence, adds a weekly meeting and a day off, moves one
occurrence, cancels the rest of a series, and looks again when the store
says it changed. It runs as `App.wasm` under WasmKit
(`Packages/RuntimeWasm`) and as a sealed native slice and wasm2c output
(`Packages/LinkedSlice`), against `HostCalendars` over a store in memory.

- `DynamicCalendarTests`: the contracts' keys and signatures, rules as
  `RRULE` text both ways, `CivilDate`, and the guest's `EventStore`
  against a scripted host.
- `RuntimeCalendarTests`: `HostCalendars` over `MemoryCalendarStore`, from
  the guest: access and its two levels, calendars, saving and finding,
  ranges, what's refused, all-day events, each kind of rule, a time zone
  across a clock change, one occurrence changed and removed, this and
  what follows, rules a store can't hold, a burst of changes, and the
  `async` forms.
- `AppManifestTests` and `Scripts/test_manifest.py`: `.calendars` and its
  two levels.

## Decided in review

The design was approved as drafted, so these stand:

- **Names:** `EventStore`, `Event`, `EventCalendar`, `RecurrenceRule`;
  module `DynamicCalendar`.
- **The system syncs, and the Calendar app is its client.** Linux needs a
  calendar service in the host, which isn't decided.
- **A rule crosses as `RRULE` text.**
- **Times are milliseconds since 1970.**
- **Two levels of access,** chosen in the manifest.
- **No attendees.**
- **No add-event sheet.**
- **Calendars are read-only as a list.**
- **No stand-in store.**

Three things changed in building it:

- **The store has its own `access` and `requestAccess`,** as
  notifications and location do, beside the built-in `Permissions`. The
  draft left asking to `Permissions` alone, which has no word for
  write-only but `limited`.
- **An `Event` doesn't keep its record.** The draft had the guest hold
  the host's record beside each value. A value that holds an object
  can't be compared or kept in an app's state, so the event's identity
  crosses with it instead (`setIdentity`).
- **`RecurrenceRule.Frequency` has all seven of RFC 5545's.** With only
  the four calendars use, an hourly rule from a store would read as no
  rule, and saving the event would have removed it.
