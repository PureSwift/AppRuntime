import Testing
import DynamicFormatting
import DynamicRuntime
import RuntimeNative

/// The test's clock: it says the time it was given, and tells the guest
/// what the test says changed.
final class ScriptedClock: SystemClockInfo {

    nonisolated(unsafe) static var time: Double = 0

    nonisolated(unsafe) static var delegate: (any SystemClockDelegate)?

    /// How many times the guest set a delegate.
    nonisolated(unsafe) static var sets = 0

    static func now() -> Double { time }

    static func setDelegate(_ delegate: SystemClockDelegate?) {
        self.delegate = delegate
        sets += 1
    }
}

final class Counter: @unchecked Sendable {
    var count = 0
}

/// Pins the formatting contracts' names, keys and wire signatures, and the
/// guest's `SystemClock` against a host the test scripts.
///
/// Serialized: the tests share the native runtime and the guest's one
/// listener.
@Suite(.serialized) struct DynamicFormattingTests {

    func method(_ descriptor: ContractDescriptor, _ key: String) -> MethodDescriptor? {
        descriptor.methods.first { $0.key == key }
    }

    @Test func formatting() {
        #expect(method(NumberFormatProxy.descriptor, "make:style:") == MethodDescriptor("make:style:", "(OI)O", .constructor))
        #expect(method(DateFormatProxy.descriptor, "formatRelative:reference:")?.signature == Signature("(JJ)O"))
        #expect(method(LocaleInfoProxy.descriptor, "preferredLanguages")?.kind == .static)
        #expect(LocaleInfoProxy.descriptor.capability == nil)
    }

    @Test func dates() {
        let clock = SystemClockInfoProxy.descriptor
        #expect(clock.name == "org.pureswift.formatting.SystemClock")
        #expect(clock.capability == nil)
        #expect(method(clock, "now") == MethodDescriptor("now", "()D", .static))
        #expect(method(clock, "setDelegate:") == MethodDescriptor("setDelegate:", "(O)V", .static))
        #expect(clock.methods.count == 2)
        #expect(SystemClockDelegateProxy.descriptor.name == "org.pureswift.formatting.SystemClockDelegate")
        #expect(method(SystemClockDelegateProxy.descriptor, "didChange:")?.signature == Signature("(I)V"))

        let zone = TimeZoneInfoProxy.descriptor
        #expect(zone.name == "org.pureswift.formatting.TimeZone")
        #expect(method(zone, "make:") == MethodDescriptor("make:", "(O)O", .constructor))
        #expect(method(zone, "identifiers")?.kind == .static)
        #expect(method(zone, "offset:")?.signature == Signature("(D)I"))
        #expect(method(zone, "nextTransition:")?.signature == Signature("(D)D"))
        #expect(method(zone, "name:locale:")?.signature == Signature("(IO)O"))
        #expect(zone.methods.count == 8)

        let calendar = CalendarInfoProxy.descriptor
        #expect(calendar.name == "org.pureswift.formatting.Calendar")
        #expect(method(calendar, "make:timeZone:locale:firstWeekday:minimumDays:")
            == MethodDescriptor("make:timeZone:locale:firstWeekday:minimumDays:", "(OOOII)O", .constructor))
        #expect(method(calendar, "fields:")?.signature == Signature("(D)O"))
        #expect(method(calendar, "date:")?.signature == Signature("(O)D"))
        #expect(method(calendar, "adding:to:wrapping:")?.signature == Signature("(ODZ)D"))
        #expect(method(calendar, "difference:from:to:")?.signature == Signature("(IDD)O"))
        #expect(method(calendar, "start:of:")?.signature == Signature("(ID)D"))
        #expect(method(calendar, "range:in:for:")?.signature == Signature("(IID)O"))
        #expect(method(calendar, "ordinality:in:for:")?.signature == Signature("(IID)I"))
        #expect(method(calendar, "nextDate:matching:policy:backward:")?.signature == Signature("(DOIZ)D"))
        #expect(method(calendar, "symbols:")?.signature == Signature("(I)O"))
        #expect(calendar.methods.count == 15)

        let collator = CollatorProxy.descriptor
        #expect(collator.name == "org.pureswift.formatting.Collator")
        #expect(method(collator, "make:options:") == MethodDescriptor("make:options:", "(OI)O", .constructor))
        #expect(method(collator, "compare::")?.signature == Signature("(OO)I"))
        #expect(method(collator, "order:")?.signature == Signature("(O)O"))
        #expect(method(collator, "contains::")?.signature == Signature("(OO)Z"))
        #expect(collator.methods.count == 5)
    }

    @Test func recordsRoundTrip() {
        let descriptors = [
            NumberFormatProxy.descriptor, DateFormatProxy.descriptor, LocaleInfoProxy.descriptor,
            SystemClockInfoProxy.descriptor, SystemClockDelegateProxy.descriptor,
            TimeZoneInfoProxy.descriptor, CalendarInfoProxy.descriptor, CollatorProxy.descriptor,
        ]
        #expect(ContractMetadata.decode(descriptors.flatMap(ContractMetadata.encode)) == descriptors)
    }

    @Test func rawValues() {
        #expect(CalendarUnit.allCases.map(\.rawValue) == Array(0...14))
        #expect(CalendarUnit.isLeapMonth.bit == 1 << 14)
        #expect(SystemClockChange.all.rawValue == 15)
        #expect(SystemClockChange.day.rawValue == 8)
        #expect(CollatorOptions.standard.rawValue == 1 | 64 | 256 | 512)
        #expect(CollatorOptions.diacriticInsensitive.rawValue == 128)
        #expect(TimeZoneNameStyle.shortGeneric.rawValue == 5)
        #expect(CalendarMatchingPolicy.strict.rawValue == 3)
        #expect(CalendarSymbols.amPm.rawValue == 14)
    }

    @Test func theClock() {
        let native = NativeRuntime.shared
        native.capabilities = nil
        SystemClockInfoProxy.register(ScriptedClock.self, in: native)
        SystemClockDelegateProxy.registerInterface(in: native)
        defer { SystemClock.onChange(nil) }

        ScriptedClock.time = 1_774_701_005
        #expect(SystemClock.secondsSince1970 == 1_774_701_005)

        var heard: [SystemClock.Change] = []
        SystemClock.onChange { heard.append($0) }
        let delegate = ScriptedClock.delegate
        #expect(delegate != nil)
        delegate?.didChange(SystemClockChange.timeZone.rawValue)
        delegate?.didChange(SystemClockChange([.clock, .day]).rawValue)
        #expect(heard == [.timeZone, [.clock, .day]])

        // What the guest doesn't know is dropped, and so is nothing at all.
        delegate?.didChange(64)
        delegate?.didChange(0)
        delegate?.didChange(64 | 1)
        #expect(heard == [.timeZone, [.clock, .day], .locale])

        // A new listener replaces the last; the host isn't asked again.
        let sets = ScriptedClock.sets
        var second: [SystemClock.Change] = []
        SystemClock.onChange { second.append($0) }
        delegate?.didChange(SystemClockChange.day.rawValue)
        #expect(heard.count == 3)
        #expect(second == [.day])
        #expect(ScriptedClock.sets == sets)

        // Nil stops the app hearing.
        SystemClock.onChange(nil)
        delegate?.didChange(SystemClockChange.day.rawValue)
        #expect(second == [.day])
    }

    /// What read the settings is evaluated again when they change.
    @Test func aViewThatReadTheSettings() {
        let native = NativeRuntime.shared
        native.capabilities = nil
        SystemClockInfoProxy.register(ScriptedClock.self, in: native)
        SystemClockDelegateProxy.registerInterface(in: native)

        let counter = Counter()
        withObservationTracking {
            SystemClock.noteAccess()
        } onChange: {
            counter.count += 1
        }
        #expect(counter.count == 0)
        let delegate = ScriptedClock.delegate
        #expect(delegate != nil, "reading the settings is enough to listen")
        delegate?.didChange(SystemClockChange.day.rawValue)
        #expect(counter.count == 1)

        // Told once for each reading.
        delegate?.didChange(SystemClockChange.locale.rawValue)
        #expect(counter.count == 1)

        // Nothing it knows changed, so nothing is evaluated.
        withObservationTracking {
            SystemClock.noteAccess()
        } onChange: {
            counter.count += 1
        }
        delegate?.didChange(64)
        #expect(counter.count == 1)
    }

    #if !EMBEDDED_NO_CONCURRENCY
    @Test @MainActor func aStreamOfChanges() async {
        let native = NativeRuntime.shared
        native.capabilities = nil
        SystemClockInfoProxy.register(ScriptedClock.self, in: native)
        SystemClockDelegateProxy.registerInterface(in: native)
        defer { SystemClock.onChange(nil) }

        let stream = SystemClock.changes
        ScriptedClock.delegate?.didChange(SystemClockChange.timeZone.rawValue)
        ScriptedClock.delegate?.didChange(SystemClockChange.day.rawValue)
        var heard: [SystemClock.Change] = []
        for await change in stream {
            heard.append(change)
            if heard.count == 2 { break }
        }
        #expect(heard == [.timeZone, .day])
    }
    #endif
}
