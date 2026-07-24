import Foundation
import Testing

@testable import BoseCore

@Test func parserSplitsConcatenatedFrames() throws {
  let a = try BmapFrame(fblock: 2, function: 2, op: .status, payload: Data([0x50]))
  let b = try BmapFrame(fblock: 1, function: 5, op: .status, payload: Data([0x0b, 0x00, 0x03]))
  var parser = BmapStreamParser()
  let frames = try parser.append(a.encoded() + b.encoded())
  #expect(frames == [a, b])
}

@Test func parserCarriesPartialFrameAcrossAppends() throws {
  let frame = try BmapFrame(
    fblock: 1, function: 7, op: .status, payload: Data([0xf6, 0x0a, 0x00, 0x00])
  )
  let wire = [UInt8](frame.encoded())
  var parser = BmapStreamParser()
  let first = try parser.append(Data(wire[0..<3]))
  #expect(first.isEmpty)
  let second = try parser.append(Data(wire[3...]))
  #expect(second == [frame])
}

@Test func parserDecodesByteByByte() throws {
  let frame = try BmapFrame(
    fblock: 2, function: 2, op: .status, payload: Data([0x50, 0xff, 0xff, 0x00])
  )
  var parser = BmapStreamParser()
  var decoded: [BmapFrame] = []
  for byte in frame.encoded() {
    decoded += try parser.append(Data([byte]))
  }
  #expect(decoded == [frame])
}

@Test func parserResyncsPastCorruptedFrame() throws {
  // A frame whose operator nibble is 0x0F (invalid) but whose length byte (2) is
  // intact, so the parser skips its 4 + 2 bytes and locks onto the valid frame after.
  let corrupted: [UInt8] = [0x01, 0x05, 0x0F, 0x02, 0xAA, 0xBB]
  let valid = try BmapFrame(fblock: 2, function: 2, op: .status, payload: Data([0x50]))
  var parser = BmapStreamParser()
  #expect(throws: BmapStreamError.corruptedFrame(operatorNibble: 0x0F)) {
    _ = try parser.append(Data(corrupted) + valid.encoded())
  }
  // The frame recovered alongside the fault is handed back on the next call.
  let recovered = try parser.append(Data())
  #expect(recovered == [valid])
}

@Test func parserReportsOverflowWhenBufferExceedsCap() {
  // A partial frame larger than a tiny cap can never complete, so it must error
  // rather than buffer without bound.
  var parser = BmapStreamParser(maximumBufferedBytes: 8)
  // Header claims length 200 (0xC8) but only a short partial follows.
  let partial = Data([0x01, 0x07, 0x03, 0xC8] + Array(repeating: UInt8(0), count: 8))
  #expect(throws: BmapStreamError.bufferOverflow(8)) {
    _ = try parser.append(partial)
  }
}
