# Formatting, dates and sorting

**Status:** partly implemented. The eight contracts, the shared host
behind them and the guest's `SystemClock` are in this repository, tested
on macOS and Linux. Foundation's types for a guest are not: `Date.now`,
`Calendar`, `TimeZone`, `Locale` and the comparing methods on `String`
wait for a change to another package, swift-embedded-foundation
([In swift-embedded-foundation](#in-swift-embedded-foundation)). Until
then a guest reaches the new contracts through their proxies. No platform
host has been changed.

Module `DynamicFormatting`: what an app needs to work with dates and with
the user's language. Foundation's place, for `Date`, `Calendar`,
`DateComponents`, `TimeZone`, `Locale` and string comparison.

A guest can't do this today. It has no way to ask what the time is: the
built-in `Clock` counts nanoseconds from an arbitrary start. It can format
a date and can't take one apart, add a month to it, or find where a week
begins. It can't order names as the user's language does.

| Contract | Kind | State | iOS / macOS | Android | Linux | Browser |
|---|---|---|---|---|---|---|
| `LocaleInfo` | contract | exists | `Locale` | `java.util.Locale` | Foundation | `Intl.Locale` |
| `NumberFormat` | contract | exists | `NumberFormatter` | `android.icu.text.NumberFormat` | Foundation | `Intl.NumberFormat` |
| `DateFormat` | contract | exists | `DateFormatter` | `android.icu.text.DateFormat` | Foundation | `Intl.DateTimeFormat` |
| `SystemClockInfo` | contract | new | the system clock, and Foundation's change notifications | `System.currentTimeMillis`, and the time and locale broadcasts | `clock_gettime`, `timedated` | `Date.now()` |
| `SystemClockDelegate` | callback | new | | | | |
| `CalendarInfo` | contract | new | `Calendar` | `android.icu.util.Calendar` | Foundation | `Temporal`, where there is one |
| `TimeZoneInfo` | contract | new | `TimeZone` | `android.icu.util.TimeZone` | Foundation, over the system's zone files | `Intl.DateTimeFormat` |
| `Collator` | contract | new | `String.compare(_:options:range:locale:)` | `android.icu.text.Collator` | Foundation | `Intl.Collator` |

None needs a capability.

Guest-side Swift:

- **`Calendar`**, **`DateComponents`**, **`TimeZone`**, **`Locale`**,
  `Date` and `DateInterval`: the ones a guest already has, from
  [swift-embedded-foundation](https://github.com/PureSwift/swift-embedded-foundation)
  through CoreModel. They are Foundation's by name and by method. That
  package learns to ask a platform for what it doesn't know, and this
  module is the platform: its answers come from the host.
  `import DynamicFormatting` brings the package's types with it.
  An app does nothing to join the two: the package is built with its
  `PlatformHooks` trait, and the linker finds this module's answers.
  That brings `Date.now` and `Date()` with it.
- `String.Comparator`, `String.StandardComparator`, `String.CompareOptions`
  and Foundation's comparing methods on `String`, which the package
  doesn't have.
- **`SystemClock`**: what changed, when the user's settings or the clock
  do. Not Foundation's: it stands where its notifications are.

Host-side Swift, in `RuntimeFormatting`: `HostSystemClock`,
`HostCalendarInfo`, `HostTimeZoneInfo` and `HostCollator`, over Swift
Foundation.

The render IR doesn't change.

## What shapes it

- **The host already has all of it.** Foundation, ICU and `java.time`
  know every time zone's history, every calendar, and how each language
  orders its letters. A guest that carried that would carry megabytes,
  and a zone database that goes stale. So the host answers, as it does
  for formatting.
- **A guest can't link Foundation.** It gets Foundation's value types
  from swift-embedded-foundation, which is exact about what it leaves
  out: its `TimeZone` is a fixed offset, its `Calendar` is Gregorian in
  that offset, its `Locale` is an identifier, and it has no clock.
  Those are the gaps a host can fill.
- **One `Calendar` in a guest.** A second type with the same name, in
  this module, would have to be told apart from the package's in every
  file that sees both. And a library built on the package, such as an
  iCalendar parser, should get the user's real time zone without knowing
  this runtime exists.
- **App code should read as it does on Apple's platforms.** The planned
  apps are SwiftUI apps. `Calendar.current.date(byAdding: .month, value:
  1, to: date)` should compile in a guest and mean the same.
- **A call to the host is cheap and isn't free.** These are answers the
  host returns at once, on the main thread. A month's grid is a few
  calls, not one for each cell. A list of a thousand names is sorted in
  one call, not in ten thousand comparisons.
- **The settings change while the app runs.** The user flies to another
  zone, midnight passes, the clock is set. A view that shows "today"
  has to be evaluated again, and Embedded Swift has no
  `@Environment(\.calendar)` to do it.

## For a guest

```swift
import DynamicFormatting

let now = Date.now
let calendar = Calendar.current

// A month's grid.
let month = calendar.dateInterval(of: .month, for: now)!
let days = calendar.range(of: .day, in: .month, for: now)!          // 1..<32 in March
let leading = (calendar.component(.weekday, from: month.start) - calendar.firstWeekday + 7) % 7
let header = calendar.veryShortStandaloneWeekdaySymbols             // from Sunday

// The same time next month, and the next 7:00.
let later = calendar.date(byAdding: .month, value: 1, to: now)!
let alarm = calendar.nextDate(after: now, matching: DateComponents(hour: 7, minute: 0),
                              matchingPolicy: .nextTime)!

// A world clock.
let tokyo = TimeZone(identifier: "Asia/Tokyo")!
let ahead = tokyo.secondsFromGMT(for: now) - TimeZone.current.secondsFromGMT(for: now)

// Names in the user's order, and a search.
let sorted = people.sorted(using: .localizedStandard) { $0.name }
let found = people.filter { $0.name.localizedStandardContains(query) }
```

### Now

`Date.now` and `Date()` ask the system's clock. That clock can be set, by
the user or by the network, so it can go backwards: measure how long
something took with `RuntimeClock.now()`.

`DateFormat` gains `string(from: Date)` and `date(from: String) -> Date?`
beside the forms that take milliseconds.

### Calendar

| | |
|---|---|
| `Calendar.current` | the user's calendar, in their time zone and locale ([When the settings change](#when-the-settings-change)) |
| `Calendar(identifier:)` | `.gregorian`, `.iso8601`, and Foundation's others where the host has them |
| `identifier`, `timeZone`, `locale`, `firstWeekday`, `minimumDaysInFirstWeek` | `timeZone`, `locale` and the last two can be set, as in Foundation |
| `dateComponents(_:from:)`, `component(_:from:)` | the parts of a moment |
| `date(from:)` | the moment for some parts; nil if there's none |
| `date(byAdding:to:wrappingComponents:)`, `date(byAdding:value:to:wrappingComponents:)` | |
| `dateComponents(_:from:to:)` | the difference between two moments |
| `startOfDay(for:)`, `dateInterval(of:for:)` | where a day, a week, a month or a year starts and ends |
| `range(of:in:for:)`, `ordinality(of:in:for:)` | how many days this month has; which day of the year this is |
| `nextDate(after:matching:matchingPolicy:direction:)` | |
| `isDate(_:inSameDayAs:)`, `isDate(_:equalTo:toGranularity:)`, `compare(_:to:toGranularity:)`, `isDateInToday`, `isDateInYesterday`, `isDateInTomorrow`, `isDateInWeekend` | |
| `monthSymbols`, `weekdaySymbols`, their `short`, `veryShort` and `standalone` forms, `eraSymbols`, `longEraSymbols`, `amSymbol`, `pmSymbol` | in the calendar's locale |

`Calendar` is a value, as in Foundation. Changing its `timeZone` changes
that copy alone.

`DateComponents` has Foundation's fields: `calendar`, `timeZone`, `era`,
`year`, `month`, `day`, `hour`, `minute`, `second`, `nanosecond`,
`weekday`, `weekdayOrdinal`, `weekOfMonth`, `weekOfYear`,
`yearForWeekOfYear`, `dayOfYear`, `isLeapMonth`, and `date`,
`value(for:)` and `setValue(_:for:)`. It has no `quarter`: Foundation's
own answer for it has never been dependable.

**A grid without a call for each cell.** `dateComponents(_:from:)`
returns every field asked for in one call. A month's grid needs three
answers: where the month starts, how many days it has, and the
calendar's first weekday. The cells are day numbers, counted in the
guest. A cell becomes a `Date` when the user taps it.

### Time zones

| | |
|---|---|
| `TimeZone.current` | the user's zone |
| `TimeZone(identifier:)` | an IANA name such as `Europe/Berlin`; nil if the host doesn't know it |
| `TimeZone(secondsFromGMT:)`, `.gmt` | a fixed offset |
| `TimeZone.knownTimeZoneIdentifiers` | every zone the host knows |
| `secondsFromGMT(for:)`, `abbreviation(for:)` | |
| `isDaylightSavingTime(for:)`, `daylightSavingTimeOffset(for:)`, `nextDaylightSavingTimeTransition(after:)` | |
| `localizedName(for:locale:)` | "Central European Time", "CET" |

A world clock's city is not a zone's name. `DateFormat` already gives
it: the pattern `VVV` in a zone formats as "Berlin", in the user's
language.

### Locale

The package's `Locale`, with what `LocaleInfo` already answers:

| | |
|---|---|
| `Locale.current`, `Locale(identifier:)`, `Locale.preferredLanguages` | |
| `identifier` | BCP 47, `en-GB` |
| `language.languageCode?.identifier`, `region?.identifier`, `currency?.identifier` | |
| `decimalSeparator`, `groupingSeparator`, `hourCycle` | |
| `calendar` | the locale's calendar |

### Sorting and searching

| | |
|---|---|
| `first.localizedStandardCompare(second)` | as a file manager orders names: `Item 2` before `Item 10`, case and width ignored |
| `localizedCompare`, `localizedCaseInsensitiveCompare`, `compare(_:options:locale:)` | |
| `strings.sorted(using: .localizedStandard)` | one call to the host for the whole list |
| `items.sorted(using: .localizedStandard) { $0.name }` | the same, for items. Foundation takes a key path here, which Embedded Swift lacks |
| `String.Comparator(options:locale:order:)` | for other options: `.caseInsensitive`, `.diacriticInsensitive`, `.widthInsensitive`, `.numeric`, `.forcedOrdering` |
| `string.localizedStandardContains(part)`, `localizedCaseInsensitiveContains` | a search field's test |
| `string.folding(options:locale:)`, `strings.folding(options:locale:)` | a string with what the options ignore taken out |

All return Foundation's `ComparisonResult` where Foundation does.

**Sort a list in one call.** `sorted(by:)` with
`localizedStandardCompare` in the closure works, and calls the host for
every comparison: about ten thousand times for a thousand names.
`sorted(using:)` sends the names once.

**Fold once, search often.** `localizedStandardContains` is a call for
each item at each keystroke. For a long list, fold the names once with
`strings.folding(options:locale:)`, fold the query, and compare in the
guest.

### When the settings change

A view that reads `Calendar.current`, `TimeZone.current` or
`Locale.current` is evaluated again when what it read may have changed.
The app writes nothing for it. That happens when:

- the user changes their region, language or calendar;
- the time zone changes;
- the clock is set;
- a new day begins in the user's zone.

So a row that shows "Today" from `calendar.isDateInToday(date)` is right
after midnight.

Code that isn't a view asks to be told:

```swift
SystemClock.onChange { changes in
    if changes.contains(.day) { reload() }
}

for await changes in SystemClock.changes { … }
```

`SystemClock.Change` is a set of `.locale`, `.timeZone`, `.clock` and
`.day`. One listener at a time, as elsewhere: a new closure or a stream
replaces the last.

What reads the user's settings calls `SystemClock.noteAccess()`, and
that is all a view's part in this is. The guest sets its delegate once,
the first time anything listens or reads, and keeps it.

`current` is a copy of the settings at the time it was asked for, as in
Foundation. A view asks again each time it's evaluated, so it needs
nothing more. There is no `autoupdatingCurrent`.

## In swift-embedded-foundation

The package keeps its rule: it has no clock, no zone database and no
locale data of its own. It gains a place for a platform to supply them,
and the platform is joined to it by the linker. Nothing is registered
and an app calls nothing.

**It's a package trait, `PlatformHooks`, off by default.** Without it
the package behaves as it does today: `TimeZone.current` is GMT and
folds to a constant, and nothing in its public surface is outside
Foundation's. A bare-metal user gains a few fields and nothing else.

**With the trait, the package calls functions it declares and doesn't
define.** They are in a C header that ships with it, one for each thing
its types can't know by themselves. Whoever is the platform defines
them, and the link joins the two.

```c
// FoundationEmbeddedPlatform.h
double  swift_embedded_clock_now(void);
bool    swift_embedded_timezone_is_known(const uint8_t *identifier, intptr_t length);
int32_t swift_embedded_timezone_offset(const uint8_t *identifier, intptr_t length, double seconds);
// …
```

```swift
// DynamicFormatting
@c @implementation
func swift_embedded_timezone_offset(_ identifier: UnsafePointer<UInt8>?, _ length: Int, _ seconds: Double) -> Int32 {
    HostZones.zone(identifier, length).offset(seconds)       // the TimeZoneInfo contract
}
```

| Type | A function for | Without the trait |
|---|---|---|
| `Date` | now | no `Date()` and no `Date.now`, as today |
| `TimeZone` | `current`; whether a name is a zone; every name; the offset at a date; daylight saving's part of it; the next change; the abbreviation; the localized name | GMT; `GMT±HHMM` alone; the offset in the name; no daylight saving |
| `Locale` | `current`; the preferred languages; each property | `en_US_POSIX`, and nothing known about it |
| `Calendar` | `current`; each operation: the fields of a date, a date from fields, adding, the difference, where a unit starts and ends, a range, an ordinality, the next match, the weekend, the symbols | Gregorian arithmetic in a fixed offset |

Text crosses as UTF-8 with a length, and a date's fields as an array of
integers. The header is the package's to design; this lists what it has
to cover.

Why a header and the linker:

- **Nothing to forget.** A guest that uses `Calendar` and doesn't link
  this module has undefined symbols, and the guest build already refuses
  a slice that leaves any outside its allowed set. The mistake is found
  when the app is built, by name.
- **The compiler checks both sides.** `@c @implementation` compares each
  definition here with the header.
- **A board can be a platform too.** Firmware with a real-time clock can
  define the same functions in C.
- **One platform for each build,** and all of it: a platform defines
  every function. There is no keeping part of the default.

The types also have to hold what a platform answers about. An extension
can't add a stored property, so these are the package's to add.

With the trait, since only a platform can answer for them:

- `Date()` and `Date.now`.
- `TimeZone` holds any identifier. `init?(identifier:)` asks the
  platform about a name it can't read as an offset.
- `Calendar.Identifier` gets Foundation's other cases.

With or without it, since they are Foundation's and cost a bare-metal
user a few words of storage:

- `Calendar` gets `firstWeekday` and `minimumDaysInFirstWeek`.
- `DateComponents` gets `calendar`, `weekdayOrdinal`, `weekOfMonth`,
  `weekOfYear`, `yearForWeekOfYear`, `dayOfYear` and `isLeapMonth`, and
  `Calendar.Component` the cases for them. The package's own arithmetic
  leaves the week fields empty, as it has no week arithmetic today.

What the trait means for a build:

- **A trait belongs to the whole build.** Once one package asks for it,
  every module in that build sees the package with hooks. That's right
  for a guest: a library three dependencies away should see the user's
  zone too. AppRuntime asks for it where it names the package, and the
  guest build already passes a dependency's traits to its sources.
- **The package is tested both ways.** Its tests against Foundation run
  without the trait, and with it against a platform made for the tests.

**What this module does.** It defines the header's functions, each a
call to the host. A `Calendar` is a value and can't hold a host object,
so this module keeps the host's calendars and zones by the value's
settings and finds one for each call. Its `current` functions are also
where a view's reading is noted, which is how the view comes to be
evaluated again.

## The contracts

Dates cross as seconds since 1970 UTC in a `Double`, which is what a
`Date` holds. `DateFormat` and the other contracts carry milliseconds in
an `Int64`; a calendar can't, since adding a day to a moment has to give
back the same fraction of a second. `nan` is no date.

```swift
@DynamicRuntime("org.pureswift.formatting.SystemClock")
public protocol SystemClockInfo: AnyObject {

    static func now() -> Double

    /// One delegate at a time. Nil stops it.
    static func setDelegate(_ delegate: SystemClockDelegate?)
}

@DynamicCallback("org.pureswift.formatting.SystemClockDelegate")
public protocol SystemClockDelegate: AnyObject {

    /// `SystemClock.Change` bits: 1 locale, 2 time zone, 4 clock, 8 day.
    func didChange(_ changes: Int32)
}

@DynamicRuntime("org.pureswift.formatting.TimeZone")
public protocol TimeZoneInfo: AnyObject {

    /// Nil identifier: the user's zone, whatever it becomes. Nil
    /// result: a zone this host doesn't know.
    static func make(identifier: String?) -> Self?

    static func identifiers() -> [String]

    func identifier() -> String

    /// Seconds east of UTC at a moment.
    func offset(_ seconds: Double) -> Int32

    /// What daylight saving adds at a moment; 0 outside it.
    func daylightSavingOffset(_ seconds: Double) -> Int32

    /// The next change of offset after a moment; `nan` if none is known.
    func nextTransition(_ seconds: Double) -> Double

    func abbreviation(_ seconds: Double) -> String?

    /// A `TimeZone.NameStyle` raw value.
    func name(_ style: Int32, locale: String?) -> String?
}

@DynamicRuntime("org.pureswift.formatting.Calendar")
public protocol CalendarInfo: AnyObject {

    /// Nil for the user's. `firstWeekday` and `minimumDays` 0: the
    /// locale's. Nil result: a calendar or zone this host doesn't know.
    static func make(identifier: String?, timeZone: String?, locale: String?,
                     firstWeekday: Int32, minimumDays: Int32) -> Self?

    func identifier() -> String
    func firstWeekday() -> Int32
    func minimumDaysInFirstWeek() -> Int32

    /// Every field of a moment.
    func fields(_ seconds: Double) -> String

    func date(_ fields: String) -> Double

    func adding(_ fields: String, to seconds: Double, wrapping: Bool) -> Double

    /// `units` has a bit for each field wanted.
    func difference(_ units: Int32, from start: Double, to end: Double) -> String

    /// Where the unit that holds a moment starts and ends.
    func start(_ unit: Int32, of seconds: Double) -> Double
    func end(_ unit: Int32, of seconds: Double) -> Double

    /// "1,31": the first value and how many. Empty if there's no answer.
    func range(_ smaller: Int32, in larger: Int32, for seconds: Double) -> String

    /// 0 if there's no answer.
    func ordinality(_ smaller: Int32, in larger: Int32, for seconds: Double) -> Int32

    /// A `Calendar.MatchingPolicy` raw value.
    func nextDate(_ seconds: Double, matching fields: String, policy: Int32, backward: Bool) -> Double

    func isWeekend(_ seconds: Double) -> Bool

    /// Names by kind: months, weekdays from Sunday, eras, and AM and PM.
    func symbols(_ kind: Int32) -> [String]
}

@DynamicRuntime("org.pureswift.formatting.Collator")
public protocol Collator: AnyObject {

    /// `options` is a `String.CompareOptions` raw value. Locale nil:
    /// the user's. `und`: no language's rules.
    static func make(locale: String?, options: Int32) -> Self

    /// -1, 0 or 1.
    func compare(_ first: String, _ second: String) -> Int32

    /// The strings' indexes in ascending order: "2,0,1".
    func order(_ strings: [String]) -> String

    func contains(_ string: String, _ part: String) -> Bool

    func fold(_ strings: [String]) -> [String]
}
```

`LocaleInfo`, `NumberFormat` and `DateFormat` don't change.

**Fields** are decimal integers with commas between, in this order. One
left empty isn't given. A unit is a field's place in the list, and a set
of units has that bit.

| 0 | 1 | 2 | 3 | 4 | 5 | 6 | 7 |
|---|---|---|---|---|---|---|---|
| era | year | month | day | hour | minute | second | nanosecond |

| 8 | 9 | 10 | 11 | 12 | 13 | 14 |
|---|---|---|---|---|---|---|
| weekday | weekdayOrdinal | weekOfMonth | weekOfYear | yearForWeekOfYear | dayOfYear | isLeapMonth |

`2026-03-28 13:30:05` in Berlin is
`1,2026,3,28,13,30,5,0,7,4,4,13,2026,87,0`.

Contracts can carry lists of strings and not of numbers, which is why
these are text. `EventAlarm` and a fetch of photos cross the same way.

### Rules every host follows

- **A host calendar never changes.** What `make` was given is what it
  is. The guest's `Calendar` is a value; setting its time zone uses
  another host object from then on. A host can share one object among
  every guest value with the same settings.
- **Nil follows the user.** An object made with no identifier, zone or
  locale answers by the user's settings at the time of each call.
- **Sunday is 1** and Saturday 7, in every calendar. The first weekday is
  a setting and doesn't renumber them.
- **A wall-clock time that doesn't exist** is moved later by the length
  of the gap: 02:30 on the night the clocks go forward is 03:30. **One
  that happens twice** is the first of the two.
- **Adding goes from the largest unit to the smallest.** A day that the
  new month lacks becomes its last: 31 January and a month is 28 or 29
  February. Adding days keeps the wall-clock time across a change of
  offset. Adding hours, minutes and seconds adds that much time.
- **`gregorian` and `iso8601` are everywhere.** Other calendars are
  where the platform has them, by their Unicode names (`buddhist`,
  `hebrew`, `islamic-umalqura`, `japanese`, `persian`). `make` returns
  nil for the rest.
- **Zones are IANA names,** and `GMT`, `UTC` and `GMT+0100` for fixed
  offsets.
- **An order is stable and total for a host.** `order` keeps strings
  that compare equal in the order they came. With `.forcedOrdering`,
  strings that differ at all never compare equal. Two hosts may order
  the same list differently where their rules for a language differ.
- **`.day` is sent once for each midnight** in the user's zone, and
  `.clock` when the clock is set by more than a second. A change of
  offset alone, as daylight saving begins, is neither.
- **What the app missed in the background is sent when it returns.** The
  host compares the zone, the locale and the day with what it last
  reported.
- **Unknown units, kinds, styles and policies** answer as no result:
  `nan`, 0 or an empty string. A host doesn't trap on them.

## The shared host

`RuntimeFormatting` implements the new contracts over Swift Foundation,
as it does the three it has. `HostFormattingModule` registers them, so a
host that registers the module today serves them with no change of its
own.

- **`HostCalendarInfo`** over `Calendar`, **`HostTimeZoneInfo`** over
  `TimeZone`, **`HostCollator`** over `String.compare(_:options:range:locale:)`
  and `folding(options:locale:)`. A calendar none of whose settings is
  the user's is made once; one that follows the user is made at each
  call.
- **`HostSystemClock`** has three settings a test or a host replaces:
  `clock`, `userTimeZone` and `schedule`, which is its timer. The whole
  module asks `userTimeZone` for the user's zone, `DateFormat` and
  `LocaleInfo` included.
- **A platform calls two things.** `changed(_:)`, for what Foundation
  doesn't report, and `applicationWillEnterForeground()`, which compares
  the zone, the locale and the day with what the guest was last told. On
  Apple platforms the shared host listens for Foundation's notifications
  itself.
- **Midnight is a timer** on every platform, set for a second after the
  next day begins in the user's zone, and set again when the zone or the
  clock changes. `.day` is sent only when the day's number has changed
  since the last one reported, so a platform's own notice and the timer
  don't both count.
- **`dayOfYear`** is a calendar component from macOS 15 and iOS 18. On
  earlier systems the host answers it with `ordinality(of: .day, in:
  .year, for:)`.

## Capability

None. The time, the user's zone and their language aren't guarded on any
platform, and `LocaleInfo` already gives the zone.

## Per host

From each platform's documentation. None of it has been tried.

| Host | |
|---|---|
| iOS / macOS | The shared host. `NSLocale.currentLocaleDidChangeNotification`, `NSSystemTimeZoneDidChange`, `NSSystemClockDidChange` and `NSCalendarDayChanged`. DarwinPackager lists the contracts a host has by hand (`HostContracts`), and needs these four added. |
| Linux | The shared host. Zones come from the system's zone files. The user's zone changes through `org.freedesktop.timedate1`; a `timerfd` with `TFD_TIMER_CANCEL_ON_SET` says when the clock was set. The locale is read once at start, as today. |
| Android | Its checkout here has none of the formatting contracts. Either the shared host, which brings Foundation's ICU data into the app, or its own over `android.icu`: `Calendar`, `TimeZone`, and a `RuleBasedCollator` with `setNumericCollation`. `ACTION_TIMEZONE_CHANGED`, `ACTION_LOCALE_CHANGED`, `ACTION_TIME_CHANGED` and `ACTION_DATE_CHANGED`. |
| Browser | `Temporal` where there is one; otherwise Gregorian arithmetic in script over the offsets `Intl.DateTimeFormat` gives. `Intl.supportedValuesOf("timeZone")`, `Intl.Locale.prototype.getWeekInfo()`, `Intl.Collator` with `numeric` and `sensitivity`. A page isn't told when the zone changes, so it looks when it becomes visible. |

## Not in this design

- **Text encodings.** A text file's are in `TextBuffer`
  (`TextEditor.md`). Turning a message's bytes into a string belongs
  with the mail client's design.
- **`DateFormatter`, `NumberFormatter` and `FormatStyle`** by those
  names. `DateFormat` and `NumberFormat` are used as they are.
- **`DatePicker` with a `Binding<Date>`** and `Text(_:style:)`. The
  frontend doesn't depend on this module. That's the next step once
  guests have a `Date` they can do something with.
- **`Date` in the other contracts.** The event store, notifications and
  files keep their milliseconds. Overloads that take a `Date` can come
  module by module.
- **Measurement systems, and the names of languages and regions.** A
  weather app wants the first. Both are additions to `LocaleInfo`.
- **Quarters,** and Foundation's `enumerateDates`.
- **A zone's history as data.** See below.

## Alternatives weighed

- **The host sends a zone's rules, and the guest does the arithmetic.**
  swift-embedded-foundation's `Calendar` would then be right for a real
  zone, with no call for each answer. It stays Gregorian, so a user
  whose calendar is Persian or Buddhist gets the wrong months; week
  numbers and `nextDate` would be written again in the guest; and every
  app would carry that code. The analysis in `PlannedApps.md` chose the
  host for this reason.
- **This module's own `Calendar`, `TimeZone` and `Locale`,** with
  Foundation's names. The first draft. A guest file that sees both
  modules has two of each name, and a library built on the package
  still gets fixed offsets.
- **The package without those members, and extensions here in their
  place.** An extension can add a member and can't replace one. So guest
  builds of the package would have to leave out `current`,
  `TimeZone(identifier:)`, `secondsFromGMT(for:)` and all of the
  calendar's arithmetic. A library that adds a month to a date would
  then compile for a guest only if it imported this module.
- **Hooks in every build of the package,** with no trait. Every
  bare-metal user would then have to be a platform, or the package would
  need defaults the linker can replace, which Swift has no supported way
  to write.
- **Closures the platform registers when the app starts,** kept in a
  static of each type, with the package's behaviour as the default. The
  second draft. Embedded Swift runs no code when a module loads, so the
  app would call `Formatting.install()` first. One that forgot would get
  GMT with no error, or would have to be stopped at its first `current`.
- **A list of start functions in a linker section,** which the runtime
  walks before the app's code. It would register the closures unasked.
  It's a mechanism to build and test on three engines for what the
  linker already does.
- **Calling the module `Foundation` in guest builds,** as the frontend
  is `SwiftUI`. Packages decide with `canImport(Foundation)` whether the
  whole of Foundation is there. CoreModel and Bluetooth do, and would
  take this module for it.
- **The contracts used as they are,** as `LocaleInfo` is today, with no
  Foundation types over them. Every app would then write its own
  wrapper around milliseconds and field numbers.
- **Sort keys.** ICU and Java make a key for each string that compares
  as bytes, so the guest could sort by itself. `Intl.Collator` has none,
  and Foundation doesn't expose them.
- **Milliseconds,** as the rest of the module carries. A `Date` holds
  less than a millisecond, and a round trip through the calendar would
  lose it.

## Example and tests

Planned:

- **`examples/ExampleDates`**: today's date, a month's grid in the
  calendar's own week, three world clocks, and a list of names sorted
  and searched. Run as `App.wasm`, as a sealed slice and through wasm2c,
  with the clock, the zone and the locale fixed.
- **In the package:** its tests against Foundation pass unchanged
  without the trait; with it, a platform made for the tests is reached
  by each function.
- **`DynamicFormattingTests`**: the contracts' names and signatures; the
  package's types against a stand-in host; fields to text and back; a
  view evaluated again after a change.
- **`RuntimeFormattingTests`**, on macOS and on Linux: each rule above.
  The night the clocks go forward and the night they go back, in Berlin
  and in a zone south of the equator; a month's end; a leap day; week
  numbers at a year's end; a non-Gregorian calendar; orders with digits,
  case and accents, in English, Swedish and German. **These exist and
  pass on both.** So do the contracts' signatures and the guest's
  `SystemClock` in `DynamicFormattingTests`. The rest is still planned.

## To check while building

- **Checked:** Foundation picks the first of a repeated hour and moves
  a missing one later, on macOS 26 and on Linux, and the two order
  English, German and Swedish alike in the cases tested. Older Apple
  systems, which use ICU's calendar, haven't been tried.
- **`@c @implementation` against a header from another package,** on
  this toolchain. If it can't, the definitions are plain `@c` functions
  and a test compares the names.
- **A guest that links the package and never asks it the time.** A
  CoreModel app does. The link drops unused code, so it should seal
  without this module; that wants trying on each target. If it doesn't,
  such a guest links this module too, and declares its contracts.
- **This repository's own tests build the guest module beside
  Foundation,** where `Calendar` is Foundation's. They have to name the
  package's module to reach the registered one.
- **CoreModel asks for the package `from: "0.1.0"`,** so a new minor
  release reaches guests without a change there. That wants confirming
  against what the release changes.
- **What a call costs** under WasmKit, for the guidance on grids and
  lists.

## Order of work

1. The package: the `PlatformHooks` trait, its header, the new storage,
   and a release.
2. Here: the four contracts, the shared host, the header's functions,
   the example and the tests.
