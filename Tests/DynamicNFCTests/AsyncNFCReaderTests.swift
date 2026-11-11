import Testing
@testable import DynamicNFC
import DynamicRuntime
import RuntimeNative

// MARK: - Host fakes

final class HostNDEFRecord: NDEFRecord {
    let textValue: String
    init(text: String) { self.textValue = text }
    static func make(format: Int32, type: [UInt8], identifier: [UInt8], payload: [UInt8]) -> HostNDEFRecord { HostNDEFRecord(text: "") }
    static func makeURI(_ uri: String) -> HostNDEFRecord? { HostNDEFRecord(text: uri) }
    static func makeText(_ text: String, locale: String) -> HostNDEFRecord { HostNDEFRecord(text: text) }
    func typeNameFormat() -> Int32 { NDEFTypeNameFormat.wellKnown.rawValue }
    func type() -> [UInt8] { [0x54] }
    func identifier() -> [UInt8] { [] }
    func payload() -> [UInt8] { Array(textValue.utf8) }
    func uri() -> String? { nil }
    func text() -> String? { textValue }
}

final class HostNDEFMessage: NDEFMessage {
    let recordList: [any NDEFRecord]
    init(_ records: [any NDEFRecord]) { self.recordList = records }
    static func make(_ records: [any NDEFRecord]) -> HostNDEFMessage { HostNDEFMessage(records) }
    func records() -> [any NDEFRecord] { recordList }
    func length() -> Int32 { 10 }
}

final class HostNFCTag: NFCTag {
    unowned(unsafe) let reader: HostNFCReader
    init(reader: HostNFCReader) { self.reader = reader }
    func type() -> Int32 { NFCTagType.ndef.rawValue }
    func identifier() -> [UInt8] { [1, 2, 3, 4] }
    func isAvailable() -> Bool { true }
    func historicalBytes() -> [UInt8]? { nil }
    func selectedApplicationIdentifier() -> String? { nil }
    func maximumTransceiveLength() -> Int32 { 253 }
    func queryNDEFStatus() {
        reader.delegate.didQueryNDEF(reader, tag: self, status: NDEFStatus.readWrite.rawValue, capacity: 137, error: 0)
    }
    func readNDEF() {
        reader.delegate.didReadNDEF(reader, tag: self, message: HostNDEFMessage([HostNDEFRecord(text: "hello")]), error: 0)
    }
    func writeNDEF(_ message: any NDEFMessage) {
        reader.delegate.didWriteNDEF(reader, tag: self, error: NFCError.tagReadOnly.rawValue)
    }
    func writeLock() { }
    func transceive(_ data: [UInt8]) {
        reader.delegate.didTransceive(reader, tag: self, response: data.reversed(), error: 0)
    }
}

final class HostNFCReader: NFCReader {

    nonisolated(unsafe) static var last: HostNFCReader?

    let delegate: any NFCReaderDelegate

    var active = false

    var invalidations = 0

    init(delegate: any NFCReaderDelegate) {
        self.delegate = delegate
    }

    static func availability() -> Int32 { NFCAvailability.available.rawValue }

    static func make(_ delegate: any NFCReaderDelegate) -> HostNFCReader {
        let reader = HostNFCReader(delegate: delegate)
        last = reader
        return reader
    }

    func begin(_ tagTypes: Int32, alertMessage: String?) {
        active = true
        delegate.didBecomeActive(self)
    }

    func setAlertMessage(_ message: String) { }
    func restartPolling() { }

    func connect(_ tag: any NFCTag) {
        delegate.didConnect(self, tag: tag, error: 0)
    }

    func invalidate(_ errorMessage: String?) {
        invalidations += 1
        end(error: 0)
    }

    func isActive() -> Bool { active }

    func detect() {
        delegate.didDetect(self, tags: [HostNFCTag(reader: self)])
    }

    func end(error: Int32) {
        active = false
        delegate.didInvalidate(self, error: error, message: nil)
    }
}

// MARK: - Tests

/// `AsyncNFCReader` against a fake host, through the native runtime.
/// Serialized: every test shares `NativeRuntime.shared`.
@Suite(.serialized) struct AsyncNFCReaderTests {

    init() {
        let native = NativeRuntime.shared
        native.capabilities = nil
        NFCReaderProxy.register(HostNFCReader.self, in: native)
        NFCReaderDelegateProxy.registerInterface(in: native)
        NFCTagProxy.register(HostNFCTag.self, in: native)
        NDEFMessageProxy.register(HostNDEFMessage.self, in: native)
        NDEFRecordProxy.register(HostNDEFRecord.self, in: native)
        HostNFCReader.last = nil
    }

    @Test func sessionReadsATag() async throws {
        #expect(AsyncNFCReader.availability == .available)
        let reader = AsyncNFCReader()
        let session = reader.session(tagTypes: .ndef, alertMessage: "Hold near a tag")
        let host = try #require(HostNFCReader.last)
        #expect(host.active)
        host.detect()

        for try await tags in session {
            let tag = try #require(tags.first)
            #expect(tag.identifier() == [1, 2, 3, 4])
            try await reader.connect(tag)
            let status = try await reader.ndefStatus(of: tag)
            #expect(status == NDEFTagStatus(status: .readWrite, capacity: 137))
            let message = try #require(try await reader.readNDEF(tag))
            #expect(message.records().first?.text() == "hello")
            #expect(try await reader.transceive([1, 2], with: tag) == [2, 1])
            await #expect(throws: NFCError.tagReadOnly) {
                try await reader.writeNDEF(message, to: tag)
            }
            reader.invalidate()
        }
        #expect(host.invalidations == 1, "the session ended normally")
    }

    @Test func sessionEndsWithTheHostsReason() async throws {
        let reader = AsyncNFCReader()
        do {
            let session = reader.session(tagTypes: .ndef)
            let host = try #require(HostNFCReader.last)
            host.end(error: NFCError.userCancelled.rawValue)
            await #expect(throws: NFCError.userCancelled) {
                for try await _ in session { }
            }
        }

        // Releasing the stream of an active session ends it.
        do {
            let session = reader.session(tagTypes: .ndef)
            _ = session
        }
        #expect(HostNFCReader.last?.invalidations == 1)
    }
}
