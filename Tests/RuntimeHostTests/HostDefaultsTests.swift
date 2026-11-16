import Foundation
import Testing
import DynamicDefaults
import DynamicFiles
import DynamicRuntime
import RuntimeNative
@testable import RuntimeHost

/// `HostDefaults` with its file-backed store, on a real file in a temporary
/// directory: the store directly, and then through the runtime from the
/// guest's `UserDefaults`.
///
/// Serialized: `HostDefaults.storage` and the native runtime are shared.
@Suite(.serialized) final class HostDefaultsTests {

    let root: URL

    var path: String {
        root.appendingPathComponent("Library/Defaults").path
    }

    init() {
        root = Foundation.FileManager.default.temporaryDirectory.appendingPathComponent("HostDefaultsTests-\(UUID().uuidString)")
    }

    deinit {
        // A directory a test made read-only can't be removed as it is.
        _ = chmod(root.appendingPathComponent("Library").path, 0o755)
        try? Foundation.FileManager.default.removeItem(at: root)
    }

    var fileBytes: [UInt8]? {
        (try? Data(contentsOf: URL(fileURLWithPath: path))).map(Array.init)
    }

    // MARK: The file

    @Test func valuesAreThereAfterAnotherLaunch() throws {
        let first = try FileDefaultsStorage(path: path)
        #expect(first.keys().isEmpty, "no file yet")
        #expect(first.setString("Ada", key: "name"))
        #expect(first.setData([1, 2, 3], key: "blob"))
        #expect(first.setString("", key: "empty"))

        // The app starts again: another store on the same file.
        let second = try FileDefaultsStorage(path: path)
        #expect(second.string("name") == "Ada")
        #expect(second.data("blob") == [1, 2, 3])
        #expect(second.string("empty") == "", "an empty string is a value")
        #expect(second.keys().sorted() == ["blob", "empty", "name"])
        #expect(second.string("none") == nil && second.data("none") == nil)
    }

    @Test func aKeyHoldsOneValue() throws {
        let storage = try FileDefaultsStorage(path: path)
        _ = storage.setString("text", key: "k")
        #expect(storage.data("k") == nil)
        _ = storage.setData([7], key: "k")
        #expect(storage.string("k") == nil && storage.data("k") == [7])
        storage.remove("k")
        storage.remove("never")
        #expect(storage.keys().isEmpty)
        #expect(try FileDefaultsStorage(path: path).keys().isEmpty, "the removal was written")
    }

    @Test func theFileIsWhatItSaysItIs() throws {
        let storage = try FileDefaultsStorage(path: path)
        _ = storage.setString("é", key: "b")
        _ = storage.setData([255], key: "a")
        #expect(fileBytes == Array("RTD1".utf8)
                + [1, 1, 0, 0, 0, 0x61, 1, 0, 0, 0, 255]             // bytes at "a"
                + [0, 1, 0, 0, 0, 0x62, 2, 0, 0, 0, 0xC3, 0xA9])     // "é" at "b"
        // Setting the same value again doesn't write.
        let written = try #require(try Foundation.FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date)
        #expect(storage.setString("é", key: "b"))
        let after = try #require(try Foundation.FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date)
        #expect(written == after)
        // No temporary file is left beside it.
        let beside = try Foundation.FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Library").path)
        #expect(beside == ["Defaults"])
    }

    @Test func aValueTooLargeIsRefused() throws {
        let storage = try FileDefaultsStorage(path: path, maximumValueSize: 8)
        #expect(storage.setString("12345678", key: "k"))
        #expect(!storage.setString("123456789", key: "k"))
        #expect(!storage.setData([UInt8](repeating: 0, count: 9), key: "k"))
        #expect(storage.string("k") == "12345678", "the old value stays")
    }

    @Test func aFileThatIsntSettingsIsMovedAside() throws {
        try Foundation.FileManager.default.createDirectory(at: root.appendingPathComponent("Library"), withIntermediateDirectories: true)
        for damaged in [Array("not settings".utf8), Array("RTD1".utf8) + [0, 9, 0, 0, 0, 0x61], Array("RTD1".utf8) + [7, 1, 0, 0, 0, 0x61, 0, 0, 0, 0]] {
            try Data(damaged).write(to: URL(fileURLWithPath: path))
            let storage = try FileDefaultsStorage(path: path)
            #expect(storage.keys().isEmpty, "the app starts with no settings")
            #expect((try? Data(contentsOf: URL(fileURLWithPath: path + ".corrupt"))).map(Array.init) == damaged, "what was there is kept")
            #expect(fileBytes == Array("RTD1".utf8))
            #expect(storage.setString("works", key: "again"))
        }
    }

    /// Not as root, which writes to a read-only directory anyway.
    @Test(.enabled(if: geteuid() != 0, "root isn't stopped by a read-only directory"))
    func aWriteThatFailsChangesNothing() throws {
        let storage = try FileDefaultsStorage(path: path)
        #expect(storage.setString("kept", key: "k"))
        // The directory can't be written to: a full disk fails the same way.
        #expect(chmod(root.appendingPathComponent("Library").path, 0o555) == 0)
        #expect(!storage.setString("lost", key: "k"))
        #expect(!storage.setString("lost", key: "new"))
        storage.remove("k")
        #expect(storage.string("k") == "kept", "what's in memory is what's in the file")
        #expect(storage.keys() == ["k"])
        #expect(chmod(root.appendingPathComponent("Library").path, 0o755) == 0)
        #expect(storage.setString("now", key: "k"))
    }

    // MARK: Through the runtime

    /// A launch of the app: the host opens the file, the guest gets its
    /// defaults.
    func launch() throws -> DynamicDefaults.UserDefaults {
        let native = NativeRuntime.shared
        native.capabilities = nil
        HostDefaults.storage = try FileDefaultsStorage(path: path)
        HostDefaultsModule.register(in: native)
        return DynamicDefaults.UserDefaults()
    }

    @Test func moduleListsItsContract() {
        #expect(HostDefaultsModule.contracts.map(\.name) == ["org.pureswift.data.Defaults"])
        #expect(HostDefaultsModule.isUsed(by: ["org.pureswift.data.Defaults"]))
    }

    @Test func aGuestsSettingsSurviveALaunch() throws {
        var defaults = try launch()
        #expect(defaults.keys.isEmpty)
        defaults.set(true, forKey: "soundOn")
        defaults.set(0.1, forKey: "volume")
        defaults.set(Int.max, forKey: "count")
        defaults.set("Ada", forKey: "name")
        defaults.set([0, 128, 255], forKey: "blob")

        defaults = try launch()
        #expect(defaults.bool(forKey: "soundOn"))
        #expect(defaults.double(forKey: "volume") == 0.1)
        #expect(defaults.integer(forKey: "count") == Int.max)
        #expect(defaults.string(forKey: "name") == "Ada")
        #expect(defaults.data(forKey: "blob") == [0, 128, 255])
        #expect(defaults.keys == ["blob", "count", "name", "soundOn", "volume"], "sorted by the host")

        defaults.removeObject(forKey: "name")
        #expect(!defaults.set("", forKey: ""), "a key needs a name")
        defaults = try launch()
        #expect(defaults.string(forKey: "name") == nil)
        #expect(defaults.keys.count == 4)
    }

    @Test func withoutAStoreNothingIsKept() {
        let native = NativeRuntime.shared
        native.capabilities = nil
        HostDefaults.storage = nil
        HostDefaultsModule.register(in: native)
        let defaults = DynamicDefaults.UserDefaults()
        #expect(!defaults.set("x", forKey: "k"))
        #expect(defaults.string(forKey: "k") == nil)
        #expect(defaults.keys.isEmpty)
    }
}
