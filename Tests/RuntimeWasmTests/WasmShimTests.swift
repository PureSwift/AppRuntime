import Foundation
import Testing
import ExampleHost
import RuntimeABI
import RuntimeCore
import RuntimeNative
import RuntimeWasm
import WAT
import WasmKit

/// Serialized: the example app test uses `NativeRuntime.shared`.
@Suite(.serialized) struct WasmShimTests {

    // MARK: Imports, with hand-written guests

    static let stringGuest = """
        (module
          (import "rt" "string_new" (func $string_new (param i32 i32) (result i32)))
          (import "rt" "string_utf8" (func $string_utf8 (param i32 i32 i32) (result i32)))
          (import "rt" "release" (func $release (param i32)))
          (import "rt" "class" (func $class (param i32 i32) (result i32)))
          (memory (export "memory") 1)
          (data (i32.const 16) "hello")
          (data (i32.const 32) "org.pureswift.runtime.List")
          (func (export "rt_main") (result i32)
            (local $string i32)
            (local $length i32)
            (local.set $string (call $string_new (i32.const 16) (i32.const 5)))
            (local.set $length (call $string_utf8 (local.get $string) (i32.const 64) (i32.const 16)))
            (call $release (local.get $string))
            ;; length * 1000 + (List class resolved ? 1 : 0)
            (i32.add
              (i32.mul (local.get $length) (i32.const 1000))
              (i32.ne (call $class (i32.const 32) (i32.const 26)) (i32.const 0))))
          (@custom "rt.abi" "\\01\\00\\00\\00")
        )
        """

    @Test func stringsAndClassesThroughImports() throws {
        let runtime = HostRuntime()
        let app = try WasmApp(bytes: try wat2wasm(Self.stringGuest), runtime: runtime)
        #expect(WasmApp.abiVersion(of: app.module) == 1)
        #expect(WasmApp.validate(app.module, runtime: runtime, capabilities: nil) == [])
        // rt_main's status is the raw i32 here: 5 bytes, List resolved.
        #expect(try app.instance.exports[function: "rt_main"]?().first?.i32 == 5001)
        let copied = try #require(app.instance.exports[memory: "memory"]).data[64..<69]
        #expect(Array(copied) == Array("hello".utf8))
        #expect(runtime.handleCount == 0)
    }

    @Test func outOfBoundsAccessTraps() throws {
        let guest = """
            (module
              (import "rt" "string_new" (func $string_new (param i32 i32) (result i32)))
              (memory (export "memory") 1)
              (func (export "rt_main") (result i32)
                (call $string_new (i32.const 65530) (i32.const 100))))
            """
        let app = try WasmApp(bytes: try wat2wasm(guest), runtime: HostRuntime())
        #expect(throws: (any Error).self) { try app.start() }
    }

    @Test func moduleWithoutABISectionFailsValidation() throws {
        let module = try parseWasm(bytes: try wat2wasm("(module)"))
        #expect(WasmApp.validate(module, runtime: HostRuntime(), capabilities: nil).first?.severity == .error)
    }

    // MARK: The example app as App.wasm

    /// Built by `Scripts/build-wasm.sh ExampleApp`; skipped without it.
    static var exampleAppURL: URL {
        if let path = ProcessInfo.processInfo.environment["EXAMPLE_APP_WASM"] {
            return URL(fileURLWithPath: path)
        }
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(".build/guest/ExampleApp/wasm32/App.wasm")
    }

    @Test(.enabled(if: FileManager.default.fileExists(atPath: WasmShimTests.exampleAppURL.path), "Build the wasm slice first: Scripts/build-wasm.sh ExampleApp"))
    func exampleAppInWasmMode() throws {
        let bytes = try Data(contentsOf: Self.exampleAppURL)
        // Host Swift objects and the wasm guest share one handle table.
        let native = NativeRuntime.shared
        ExampleHost.lines = []
        ExampleHost.register(in: native)
        let clock = ManualClock()
        native.runtime.clock = clock
        defer { native.runtime.clock = nil }
        let handles = native.runtime.handleCount

        let app = try WasmApp(bytes: Array(bytes), runtime: native.runtime, capabilities: [])
        #expect(WasmApp.abiVersion(of: app.module) == runtimeABIVersion)
        // guest.py adds the rt.contracts section; validate it like a host would.
        #expect(WasmApp.contracts(of: app.module).map(Set.init) == Set(ExampleHost.contracts))
        let issues = WasmApp.validate(app.module, runtime: native.runtime, capabilities: [])
        #expect(issues.map(\.contract) == ["org.pureswift.example.Beacon"], "only the ungranted capability")
        let status = try app.start()

        var lines = ExampleHost.lines
        #expect(status == .ok, "\(lines.joined(separator: "\n"))")
        #expect(lines.contains("beacon refused"), "the manifest grants no capabilities")
        // The guest executor ran the app's tasks before rt_main returned,
        // up to their sleeps.
        #expect(Array(lines.drop { $0 != "done" }) == [
            "done",
            "ok cancel before sleep",
            "async started",
            "ok task value",
        ])
        #expect(clock.pendingCount == 2, "the 1 ms and 1 s sleeps")

        // The 1 ms timer resumes the main task through rt_dispatch, which
        // cancels the 1 s sleep.
        clock.advance(by: 1_000_000)
        lines = ExampleHost.lines
        #expect(Array(lines.drop { $0 != "ok task value" }.dropFirst()) == [
            "ok sleep",
            "async done",
            "ok cancel while sleeping",
        ])
        #expect(clock.pendingCount == 1)

        // The cancelled sleep's timer still fires, and does nothing.
        clock.advance(by: 1_000_000_000)
        #expect(clock.pendingCount == 0)
        #expect(ExampleHost.lines.count == lines.count)
        #expect(ExampleHost.lines.filter { $0.hasPrefix("FAIL") } == [])
        #expect(native.runtime.handleCount == handles)
    }
}
