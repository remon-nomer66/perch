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

// MARK: - Reassembly boundaries
//
// Cutting frames out of coalesced/split RFCOMM chunks is the core of the transport, and
// it had no systematic boundary coverage. These walk the cases the delegate can actually
// hand over: a chunk that ends anywhere inside a frame, several frames in one chunk with
// a partial tail, the largest frame the length byte can describe, and empty payloads.

/// A chunk boundary at *every* offset of a two-frame run: the split must never lose,
/// duplicate, or reorder a frame, wherever it lands.
@Test func parserSurvivesASplitAtEveryOffset() throws {
  let a = try BmapFrame(fblock: 2, function: 2, op: .status, payload: Data([0x50, 0xff, 0xff, 0x01]))
  let b = try BmapFrame(fblock: 31, function: 6, op: .status, payload: Data(repeating: 0x0a, count: 48))
  let wire = [UInt8](a.encoded() + b.encoded())

  for cut in 0...wire.count {
    var parser = BmapStreamParser()
    var decoded = try parser.append(Data(wire[0..<cut]))
    decoded += try parser.append(Data(wire[cut...]))
    #expect(decoded == [a, b], "split at \(cut)")
  }
}

/// Several frames coalesced into one chunk with the last one cut short: the whole ones
/// come back now, the partial one only once its tail arrives.
@Test func parserReturnsWholeFramesAndHoldsThePartialTail() throws {
  let a = try BmapFrame(fblock: 2, function: 2, op: .status, payload: Data([0x50]))
  let b = try BmapFrame(fblock: 1, function: 5, op: .status, payload: Data([0x0b, 0x00, 0x03]))
  let c = try BmapFrame(fblock: 1, function: 7, op: .status, payload: Data([0xf6, 0x0a, 0x00, 0x00]))
  let tail = [UInt8](c.encoded())

  var parser = BmapStreamParser()
  let first = try parser.append(a.encoded() + b.encoded() + Data(tail[0..<2]))
  #expect(first == [a, b])
  let second = try parser.append(Data(tail[2...]))
  #expect(second == [c])
}

/// The largest frame the length byte can describe (255 payload bytes), delivered in
/// chunks that align with nothing in particular.
@Test func parserReassemblesAMaximumLengthFrame() throws {
  let frame = try BmapFrame(
    fblock: 31, function: 6, op: .status, payload: Data(repeating: 0xAB, count: 255)
  )
  let wire = [UInt8](frame.encoded())
  #expect(wire.count == 259)

  var parser = BmapStreamParser()
  var decoded: [BmapFrame] = []
  for chunk in stride(from: 0, to: wire.count, by: 7) {
    decoded += try parser.append(Data(wire[chunk..<min(chunk + 7, wire.count)]))
  }
  #expect(decoded == [frame])
}

/// A run of empty-payload frames — four bytes each, so every frame boundary is also a
/// header boundary, the case a length-driven parser is most likely to slip on.
@Test func parserSplitsBackToBackEmptyPayloadFrames() throws {
  let frames = try (0..<5).map { index in
    try BmapFrame(fblock: 31, function: UInt8(index), op: .status)
  }
  var wire = Data()
  for frame in frames { wire.append(frame.encoded()) }

  var parser = BmapStreamParser()
  #expect(try parser.append(wire) == frames)
}

/// A damaged header whose declared tail has not arrived yet must be held, not skipped on
/// the spot: the rest of the frame it describes may still be in flight.
@Test func parserWaitsForACorruptedFramesTailBeforeSkippingIt() throws {
  // Operator nibble 0x0F is invalid; the length byte claims 4 payload bytes.
  let corruptedHead: [UInt8] = [0x01, 0x05, 0x0F, 0x04, 0xAA, 0xBB]
  let valid = try BmapFrame(fblock: 2, function: 2, op: .status, payload: Data([0x50]))

  var parser = BmapStreamParser()
  // Only 2 of the 4 payload bytes are here, so nothing is reported yet.
  #expect(try parser.append(Data(corruptedHead)).isEmpty)
  // The tail completes the damaged frame; it is skipped and the good frame locks on.
  #expect(throws: BmapStreamError.corruptedFrame(operatorNibble: 0x0F)) {
    _ = try parser.append(Data([0xCC, 0xDD]) + valid.encoded())
  }
  #expect(try parser.append(Data()) == [valid])
}

/// After an overflow drops the wedged buffer, the parser must lock onto the next clean
/// frame rather than stay poisoned.
@Test func parserRecoversAfterAnOverflowDrop() throws {
  var parser = BmapStreamParser(maximumBufferedBytes: 8)
  let partial = Data([0x01, 0x07, 0x03, 0xC8] + Array(repeating: UInt8(0), count: 8))
  #expect(throws: BmapStreamError.bufferOverflow(8)) {
    _ = try parser.append(partial)
  }
  let valid = try BmapFrame(fblock: 2, function: 2, op: .status, payload: Data([0x50]))
  #expect(try parser.append(valid.encoded()) == [valid])
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
