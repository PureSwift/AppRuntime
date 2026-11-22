# swift-embedded-foundation: platform hooks

**Status:** agreed, and being built. It is a change to another package,
[swift-embedded-foundation](https://github.com/PureSwift/swift-embedded-foundation),
and the other half of `Formatting.md`, which says why.

The package has no clock, no zone database and no locale data. A build
that has a platform under it can supply them. This adds the place: a
trait, and a C header whose functions a platform defines.

## What was tried

On Swift 6.4.2, in a package made for the purpose:

- A C target with the header; a Swift target that calls its functions
  when a trait is on; another Swift target that defines them with
  `@c @implementation`. It builds, links and runs, with the trait and
  without.
- A definition whose type differs from the header's is refused by the
  compiler: "does not match type '() -> Double' declared by the header".
- AppRuntime's guest build already compiles a dependency's C targets,
  passes their module maps to Swift, and follows dependencies that hang
  on a trait.

- **`timespec_get` on WASI.** The Swift 6.4.2 wasm SDK declares it in
  `time.h`, with `TIME_UTC`, and defines it in `libc.a`. An Embedded
  Swift program for `wasm32-unknown-wasip1` that calls it prints the
  host's time under wasmtime and under WasmKit. It reaches the host as
  the WASI preview 1 import `clock_time_get`.

Not tried: the header and the trait under Embedded Swift for wasm.

## The trait

`PlatformHooks`, off by default.

| | Without it | With it |
|---|---|---|
| `Date()`, `Date.now` | C's `timespec_get` | the platform's clock |
| `TimeZone.current` | the process's zone, from the C library | the user's zone |
| `TimeZone(identifier:)` | `GMT`, `UTC`, `GMT±HHMM` | those, and any name the platform knows |
| `TimeZone.secondsFromGMT(for:)` | the offset in the name | the platform's, for a named zone |
| The rest of `TimeZone` | absent | `knownTimeZoneIdentifiers`, `isDaylightSavingTime(for:)`, `daylightSavingTimeOffset(for:)`, `nextDaylightSavingTimeTransition(after:)`, `abbreviation(for:)`, `localizedName(for:locale:)` |
| `Locale.current` | `en_US_POSIX` | the user's locale |
| `Locale.preferredLanguages` | absent | the user's |
| `Calendar.current` | Gregorian, GMT | the user's calendar, zone and locale |
| `Calendar(identifier:)` | `.gregorian` | Foundation's sixteen |
| `Calendar`'s arithmetic | the package's own, Gregorian in a fixed offset | the platform's, for every calendar |
| The rest of `Calendar` | absent | `dateComponents(_:from:to:)`, `dateInterval(of:for:)`, `ordinality(of:in:for:)`, `nextDate(after:matching:matchingPolicy:direction:)`, `isDateInWeekend`, `isDateInToday` and its neighbours, the symbols |

### The clock

**By default `Date()` and `Date.now` call `timespec_get(&time,
TIME_UTC)`.** It is C11, so it is the one clock a hosted platform can be
counted on to have: Apple's, Linux with glibc or musl, Android from
API 29, Windows, and WASI. The package gets it from a small C target
that includes `time.h`.

Two things follow.

- **A bare-metal target has no `time.h`.** The package's embedded test
  builds for `armv7em-none-none-eabi`, `riscv32-none-none-eabi` and
  `arm64-apple-none-macho` with no C library at all. So the C target
  asks `__has_include(<time.h>)`. Where there is none, the package
  still builds, and `Date()` stops with a message: there is no clock to
  read. A board that has one builds with the trait.
- **With the trait, the clock is the platform's**, and `timespec_get`
  isn't referenced. AppRuntime needs that for its native slices. They
  are compiled with no C library's headers, and a sealed slice may
  leave `clock_gettime` undefined but not `timespec_get`. Its wasm
  guests could use `timespec_get` as it is, since they may import WASI
  preview 1. One clock for every kind of slice is simpler, and it is the
  clock a test can set.

### The zone by default

**Without the trait, `TimeZone.current` is the process's zone**, read
with `localtime_r`: its offset at a moment is `tm_gmtoff`. The package's
own Gregorian calendar reads the offset for each date, so it is right
across a change of clocks in that one zone.

Tried with `TZ=Europe/Berlin`: macOS and Debian answer two hours ahead
in July, with daylight saving. WASI answers UTC whatever `TZ` says, and
doesn't declare `tzset`. So does a target with no `time.h`. That is what
the package answered everywhere before.

The C library can say nothing more:

- **It has no name for the zone.** `identifier` is the `TZ` variable's
  value when there is one, and `Local` when there isn't.
  `TimeZone(identifier:)` doesn't take it back.
- **It knows no zone but its own.** A zone by name, the list of zones,
  the next change of offset, and names in a language all need the
  trait.

POSIX has functions for a locale's names and for ordering strings
(`nl_langinfo`, `strcoll`). The package doesn't use them. What they
answer depends on which locales a machine has installed; on Apple's
platforms the C locale isn't the user's setting; and on WASI and musl
`strcoll` compares bytes.

With the trait, **every** public `Calendar` operation goes to the
platform, the Gregorian calendar in GMT included. Otherwise a calendar
would answer for its week fields in one zone and leave them empty in
another.

**The package's own code doesn't go through the platform.** Its ISO 8601
and HTTP date code call `Calendar(identifier: .gregorian).date(from:)`
today. They move to the internal civil-date functions, which need
nothing, so formatting a timestamp never leaves the package.

With or without the trait, since they are Foundation's:

- `Calendar` gets `firstWeekday` and `minimumDaysInFirstWeek`, stored.
  Zero means the locale's, which the package's own arithmetic reads as
  Sunday and 1.
- `DateComponents` gets `calendar`, `weekdayOrdinal`, `weekOfMonth`,
  `weekOfYear`, `yearForWeekOfYear`, `dayOfYear` and `isLeapMonth`, and
  `Calendar.Component` the cases for them. The package's own arithmetic
  leaves the week fields empty.

## The header

A second target, `FoundationEmbeddedPlatform`: the header and nothing
else. `FoundationEmbedded` depends on it when the trait is on. It is a
product, so a platform can import it.

Three conventions:

- **Text in** is UTF-8 with a length. Nothing is terminated.
- **Text out** is written to the caller's buffer. The function returns
  the length the text needs, which may be more than the buffer holds;
  the caller then asks again with one that size. Less than zero is no
  text. A list is its items with a line feed between.
- **A date** is seconds since 1970 UTC. `nan` is no date.

```c
#include <stdbool.h>
#include <stdint.h>

// MARK: The clock

double   swift_embedded_clock_now(void);

// MARK: Time zones

/// The user's zone: its identifier.
intptr_t swift_embedded_timezone_current(uint8_t *buffer, intptr_t capacity);

bool     swift_embedded_timezone_is_known(const uint8_t *identifier, intptr_t length);

/// Every identifier the platform knows.
intptr_t swift_embedded_timezone_identifiers(uint8_t *buffer, intptr_t capacity);

/// Seconds east of UTC at a moment.
int32_t  swift_embedded_timezone_offset(const uint8_t *identifier, intptr_t length, double seconds);

/// What daylight saving adds at a moment; 0 outside it.
int32_t  swift_embedded_timezone_daylight_saving_offset(const uint8_t *identifier, intptr_t length, double seconds);

/// The next change of offset after a moment.
double   swift_embedded_timezone_next_transition(const uint8_t *identifier, intptr_t length, double seconds);

intptr_t swift_embedded_timezone_abbreviation(const uint8_t *identifier, intptr_t length, double seconds,
                                              uint8_t *buffer, intptr_t capacity);

/// `style` is Foundation's `NSTimeZone.NameStyle`. A locale of no
/// length is the user's.
intptr_t swift_embedded_timezone_name(const uint8_t *identifier, intptr_t length, int32_t style,
                                      const uint8_t *locale, intptr_t locale_length,
                                      uint8_t *buffer, intptr_t capacity);

// MARK: The locale

/// The user's locale: its identifier.
intptr_t swift_embedded_locale_current(uint8_t *buffer, intptr_t capacity);

/// The user's languages, in order.
intptr_t swift_embedded_locale_preferred_languages(uint8_t *buffer, intptr_t capacity);

// MARK: Calendars

/// A calendar as the package's `Calendar` holds it.
typedef struct {
    const uint8_t *identifier;      // "gregorian", "iso8601", "buddhist"
    intptr_t identifier_length;
    const uint8_t *time_zone;
    intptr_t time_zone_length;
    const uint8_t *locale;          // of no length: the user's
    intptr_t locale_length;
    int32_t first_weekday;          // 1 is Sunday; 0: the locale's
    int32_t minimum_days;           // 0: the locale's
} swift_embedded_calendar;

/// A date's fields, in this order: era, year, month, day, hour, minute,
/// second, nanosecond, weekday, weekday ordinal, week of month, week of
/// year, year for week of year, day of year, leap month.
#define SWIFT_EMBEDDED_FIELD_COUNT 15

/// A field that isn't given.
#define SWIFT_EMBEDDED_FIELD_NONE INTPTR_MIN

/// The user's calendar: its identifier.
intptr_t swift_embedded_calendar_current(uint8_t *buffer, intptr_t capacity);

/// What a calendar's first weekday and minimum days are, when the
/// struct leaves them to the locale.
int32_t  swift_embedded_calendar_first_weekday(const swift_embedded_calendar *calendar);
int32_t  swift_embedded_calendar_minimum_days(const swift_embedded_calendar *calendar);

/// Every field of a moment. False if the platform has no such calendar
/// or zone.
bool     swift_embedded_calendar_fields(const swift_embedded_calendar *calendar, double seconds,
                                        intptr_t fields[SWIFT_EMBEDDED_FIELD_COUNT]);

double   swift_embedded_calendar_date(const swift_embedded_calendar *calendar,
                                      const intptr_t fields[SWIFT_EMBEDDED_FIELD_COUNT]);

double   swift_embedded_calendar_adding(const swift_embedded_calendar *calendar,
                                        const intptr_t fields[SWIFT_EMBEDDED_FIELD_COUNT],
                                        double seconds, bool wrapping);

/// `units` has a bit for each field wanted, by its place in the list.
bool     swift_embedded_calendar_difference(const swift_embedded_calendar *calendar, int32_t units,
                                            double start, double end,
                                            intptr_t fields[SWIFT_EMBEDDED_FIELD_COUNT]);

/// Where the unit that holds a moment starts and ends. A unit is a
/// field's place in the list.
double   swift_embedded_calendar_start(const swift_embedded_calendar *calendar, int32_t unit, double seconds);
double   swift_embedded_calendar_end(const swift_embedded_calendar *calendar, int32_t unit, double seconds);

bool     swift_embedded_calendar_range(const swift_embedded_calendar *calendar, int32_t smaller, int32_t larger,
                                       double seconds, intptr_t *lower, intptr_t *count);

/// 0 if there's no answer.
int32_t  swift_embedded_calendar_ordinality(const swift_embedded_calendar *calendar, int32_t smaller,
                                            int32_t larger, double seconds);

/// `policy` is Foundation's `Calendar.MatchingPolicy`, in its order.
double   swift_embedded_calendar_next_date(const swift_embedded_calendar *calendar, double seconds,
                                           const intptr_t fields[SWIFT_EMBEDDED_FIELD_COUNT],
                                           int32_t policy, bool backward);

bool     swift_embedded_calendar_is_weekend(const swift_embedded_calendar *calendar, double seconds);

/// Names: 0 to 5 are the months (long, short, very short, and each
/// standalone), 6 to 11 the weekdays from Sunday in the same six forms,
/// 12 the eras, 13 the long eras, 14 AM and PM.
intptr_t swift_embedded_calendar_symbols(const swift_embedded_calendar *calendar, int32_t kind,
                                         uint8_t *buffer, intptr_t capacity);
```

Twenty-five functions. The numbers for units, kinds, styles and policies
are the ones AppRuntime's contracts carry, so its definitions pass them
through.

### What a platform owes

The rules in `Formatting.md`, "Rules every host follows", stated for C:

- A function is called on whatever thread the package's caller is on,
  and returns at once. AppRuntime's guests have one thread.
- Sunday is 1, in every calendar.
- A wall-clock time that doesn't exist is moved later by the gap; one
  that happens twice is the first.
- Adding goes from the largest unit to the smallest, and a day the new
  month lacks becomes its last.
- A unit, a kind, a style or a policy it doesn't know answers as no
  result. It doesn't trap.
- A platform defines all twenty-five. One with only a clock returns no
  result from the rest.

## For a platform in Swift

```swift
import FoundationEmbeddedPlatform

@c @implementation
public func swift_embedded_clock_now() -> Double {
    SystemClockInfoProxy.now()
}
```

AppRuntime's are in `DynamicFormatting`. Each is a call to a host
contract. A calendar struct is looked up among the host calendars the
module has made, by its settings.

## Tests

- **Without the trait:** the suite as it is.
- **With it:** a platform for the tests, in the package's test support,
  which defines the header over Foundation itself. The parity suites
  then compare the package, through the header, with Foundation. Tests
  of what only the trait's absence gives, such as `TimeZone.current`
  being GMT, are compiled out.
- **CI** runs both. The coverage script measures the build with the
  trait, which has the more code.
- **The embedded smoke test** gains a platform in C that knows one
  fixed zone, so that the trait is built for a bare-metal target too.

## Decided

- **The trait is `PlatformHooks`.**
- **The clock under the trait is the platform's.** `timespec_get` is the
  default, without it.
- **The header is its own target,** `FoundationEmbeddedPlatform`.
- **`Locale` doesn't grow in the package.** AppRuntime adds what it
  needs as extensions over its own contract.
- **Lists cross as lines.**
