import Testing
import DynamicUI

/// The render codec's bytes, pinned: little-endian on every host, so a
/// change that went through the host's own order, which a big-endian
/// PowerPC would show (`Documentation/PowerPC.md`), fails here too.
@Suite struct ByteOrderTests {

    @Test func aDoubleIsItsBitsLowByteFirst() throws {
        // 1.5 is 0x3FF8_0000_0000_0000.
        let bytes = RenderCodec.encode(payload: .double(1.5))
        #expect(Array(bytes.suffix(9)) == [1, 0, 0, 0, 0, 0, 0, 0xF8, 0x3F])
        #expect(try RenderCodec.decode(payload: bytes) == .double(1.5))
    }

    @Test func aNodeIDIsLowByteFirst() throws {
        #expect(RenderCodec.encode(id: 0x0102_0304_0506_0708) == [8, 7, 6, 5, 4, 3, 2, 1])
        #expect(try RenderCodec.decode(id: [8, 7, 6, 5, 4, 3, 2, 1]) == 0x0102_0304_0506_0708)
    }

    @Test func anIntIsAZigzagVarint() {
        // -2 is zigzag 3; 300 is zigzag 600, 0xD8 0x04.
        #expect(Array(RenderCodec.encode(payload: .int(-2)).suffix(2)) == [3, 3])
        #expect(Array(RenderCodec.encode(payload: .int(300)).suffix(3)) == [3, 0xD8, 0x04])
    }
}
