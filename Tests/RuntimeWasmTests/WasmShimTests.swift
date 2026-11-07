import Foundation
import XCTest
import ExampleHost
import RuntimeABI
import RuntimeCore
import RuntimeNative
import RuntimeWasm
import WAT
import WasmKit

final class WasmShimTests: XCTestCase {

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

    func testStringsAndClassesThroughImports() throws {
        let runtime = HostRuntime()
        let app = try WasmApp(bytes: try wat2wasm(Self.stringGuest), runtime: runtime)
        XCTAssertEqual(WasmApp.abiVersion(of: app.module), 1)
        XCTAssertEqual(WasmApp.validate(app.module, runtime: runtime, capabilities: nil), [])
        // rt_main's status is the raw i32 here: 5 bytes, List resolved.
        XCTAssertEqual(try app.instance.exports[function: "rt_main"]?().first?.i32, 5001)
        let copied = try XCTUnwrap(app.instance.exports[memory: "memory"]).data[64..<69]
        XCTAssertEqual(Array(copied), Array("hello".utf8))
        XCTAssertEqual(runtime.handleCount, 0)
    }

    func testOutOfBoundsAccessTraps() throws {
        let guest = """
            (module
              (import "rt" "string_new" (func $string_new (param i32 i32) (result i32)))
              (memory (export "memory") 1)
              (func (export "rt_main") (result i32)
                (call $string_new (i32.const 65530) (i32.const 100))))
            """
        let app = try WasmApp(bytes: try wat2wasm(guest), runtime: HostRuntime())
        XCTAssertThrowsError(try app.start())
    }

    func testModuleWithoutABISectionFailsValidation() throws {
        let module = try parseWasm(bytes: try wat2wasm("(module)"))
        XCTAssertEqual(WasmApp.validate(module, runtime: HostRuntime(), capabilities: nil).first?.severity, .error)
    }

    // MARK: The example app as App.wasm

    /// Built by `Scripts/build-wasm.sh ExampleApp`; skipped without it.
    var exampleAppURL: URL {
        if let path = ProcessInfo.processInfo.environment["EXAMPLE_APP_WASM"] {
            return URL(fileURLWithPath: path)
        }
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(".build/guest/ExampleApp/wasm32/App.wasm")
    }

    func testExampleAppInWasmMode() throws {
        guard let bytes = try? Data(contentsOf: exampleAppURL) else {
            throw XCTSkip("Build the wasm slice first: Scripts/build-wasm.sh ExampleApp")
        }
        // Host Swift objects and the wasm guest share one handle table.
        let native = NativeRuntime.shared
        ExampleHost.lines = []
        ExampleHost.register(in: native)
        let handles = native.runtime.handleCount

        let app = try WasmApp(bytes: Array(bytes), runtime: native.runtime, capabilities: [])
        XCTAssertEqual(WasmApp.abiVersion(of: app.module), runtimeABIVersion)
        // guest.py adds the rt.contracts section; validate it like a host would.
        XCTAssertEqual(WasmApp.contracts(of: app.module).map(Set.init), Set(ExampleHost.contracts))
        let issues = WasmApp.validate(app.module, runtime: native.runtime, capabilities: [])
        XCTAssertEqual(issues.map(\.contract), ["org.pureswift.example.Beacon"], "only the ungranted capability")
        let status = try app.start()

        let lines = ExampleHost.lines
        XCTAssertEqual(status, .ok, lines.joined(separator: "\n"))
        XCTAssertEqual(lines.filter { $0.hasPrefix("FAIL") }, [])
        XCTAssertTrue(lines.contains("beacon refused"), "the manifest grants no capabilities")
        XCTAssertEqual(lines.last, "done")
        XCTAssertEqual(native.runtime.handleCount, handles)
    }
}
