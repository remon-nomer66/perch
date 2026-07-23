import Foundation
import TandemCore
import Testing

@testable import TandemSession

private func frame(_ dataType: UInt8, _ sequence: UInt8, _ payload: [UInt8]) throws -> TandemFrame {
  try TandemFrame(dataType: dataType, sequence: sequence, payload: Data(payload))
}

@Test func splitFrameAcrossReadsIsDecoded() throws {
  let wire = try frame(TandemFrame.table1DataType, 0, [0x01, 0x02, 0x03]).encoded()
  var parser = FrameStreamParser()

  var output = FrameStreamParser.Output()
  for byte in wire {
    let chunk = parser.append(Data([byte]))
    output.frames.append(contentsOf: chunk.frames)
    output.discards.append(contentsOf: chunk.discards)
  }

  #expect(output.frames.count == 1)
  #expect(output.frames.first?.payload == Data([0x01, 0x02, 0x03]))
  #expect(output.discards.isEmpty)
}

@Test func multipleFramesInOneReadAreDecoded() throws {
  var wire = try frame(TandemFrame.table1DataType, 0, [0xAA]).encoded()
  wire.append(try frame(TandemFrame.table2DataType, 1, [0xBB, 0xCC]).encoded())
  var parser = FrameStreamParser()

  let output = parser.append(wire)

  #expect(output.frames.count == 2)
  #expect(output.frames[0].payload == Data([0xAA]))
  #expect(output.frames[1].payload == Data([0xBB, 0xCC]))
}

@Test func reservedBytesSurviveEscaping() throws {
  let payload: [UInt8] = [TandemFrame.startByte, TandemFrame.endByte, TandemFrame.escapeByte]
  let wire = try frame(TandemFrame.table1DataType, 0, payload).encoded()
  var parser = FrameStreamParser()

  let output = parser.append(wire)

  #expect(output.frames.first?.payload == Data(payload))
  #expect(output.discards.isEmpty)
}

@Test func checksumFailureIsDiscardedAndTheNextFrameStillArrives() throws {
  var wire = try frame(TandemFrame.table1DataType, 0, [0x01]).encoded()
  // Corrupt the checksum, which sits immediately before the end byte.
  wire[wire.count - 2] = wire[wire.count - 2] &+ 1
  let good = try frame(TandemFrame.table2DataType, 1, [0x02]).encoded()
  var parser = FrameStreamParser()

  let output = parser.append(wire + good)

  #expect(output.frames.count == 1)
  #expect(output.frames.first?.payload == Data([0x02]))
  #expect(output.discards.count == 1)
  if case .malformed(let error) = output.discards[0] {
    guard case .checksumMismatch = error else {
      Issue.record("expected a checksum mismatch, got \(error)")
      return
    }
  } else {
    Issue.record("expected a malformed discard, got \(output.discards[0])")
  }
}

@Test func startByteInsideABodyResynchronises() throws {
  let good = try frame(TandemFrame.table1DataType, 0, [0x42]).encoded()
  // A truncated body followed by a fresh start byte.
  let truncated = Data([TandemFrame.startByte, 0x0C, 0x00, 0x00])
  var parser = FrameStreamParser()

  let output = parser.append(truncated + good)

  #expect(output.frames.count == 1)
  #expect(output.frames.first?.payload == Data([0x42]))
  #expect(output.discards == [.truncated(droppedBytes: 3)])
}

@Test func invalidEscapeIsDiscardedAndTheNextFrameStillArrives() throws {
  let bad = Data([TandemFrame.startByte, 0x0C, TandemFrame.escapeByte, 0xFF])
  let good = try frame(TandemFrame.table1DataType, 0, [0x07]).encoded()
  var parser = FrameStreamParser()

  let output = parser.append(bad + good)

  #expect(output.frames.count == 1)
  #expect(output.discards == [.malformed(.invalidEscape(0xFF))])
}

@Test func anInvalidEscapeOnAStartByteResynchronisesOnThatByte() throws {
  // The byte that invalidates the escape is itself the start of the next frame.
  // Consuming it would swallow an otherwise perfectly good frame.
  let good = try frame(TandemFrame.table1DataType, 0, [0x33]).encoded()
  let bad = Data([TandemFrame.startByte, 0x0C, TandemFrame.escapeByte])
  var parser = FrameStreamParser()

  let output = parser.append(bad + good)

  #expect(output.frames.count == 1)
  #expect(output.frames.first?.payload == Data([0x33]))
  #expect(output.discards == [.malformed(.invalidEscape(TandemFrame.startByte))])
}

@Test func retainedBytesNeverExceedTheConfiguredBound() throws {
  var parser = FrameStreamParser(maximumPayloadLength: 32)
  let bound = 32 + 7

  var flood = Data([TandemFrame.startByte])
  flood.append(contentsOf: Data(repeating: 0x01, count: 512))
  for byte in flood {
    _ = parser.append(Data([byte]))
    #expect(parser.retainedByteCount <= bound)
  }
  #expect(parser.retainedByteCount == bound)
}

@Test func payloadLengthIsClampedToARepresentableRange() {
  // `maximumPayloadLength + overhead` must not be able to overflow.
  #expect(FrameStreamParser(maximumPayloadLength: .max).maximumPayloadLength
    == FrameStreamParser.payloadLengthRange.upperBound)
  #expect(FrameStreamParser(maximumPayloadLength: -1).maximumPayloadLength
    == FrameStreamParser.payloadLengthRange.lowerBound)
}

@Test func bodyWithoutAnEndByteIsBoundedAndResynchronises() throws {
  var parser = FrameStreamParser(maximumPayloadLength: 16)
  var flood = Data([TandemFrame.startByte])
  flood.append(contentsOf: Data(repeating: 0x00, count: 4096))

  let floodOutput = parser.append(flood)
  #expect(floodOutput.isEmpty)

  let good = try frame(TandemFrame.table1DataType, 0, [0x09]).encoded()
  let output = parser.append(good)

  #expect(output.frames.count == 1)
  #expect(output.frames.first?.payload == Data([0x09]))
  #expect(output.discards.count == 1)
  guard case .oversized(let dropped) = output.discards[0] else {
    Issue.record("expected an oversized discard, got \(output.discards[0])")
    return
  }
  #expect(dropped == 4096)
}

@Test func bufferEndingOnAnEscapeResumesOnTheNextRead() throws {
  let payload: [UInt8] = [TandemFrame.endByte]
  let wire = try frame(TandemFrame.table1DataType, 0, payload).encoded()
  guard let escapeIndex = wire.firstIndex(of: TandemFrame.escapeByte) else {
    Issue.record("the encoder did not escape a reserved byte")
    return
  }
  var parser = FrameStreamParser()

  let first = parser.append(wire[..<(escapeIndex + 1)])
  #expect(first.isEmpty)

  let second = parser.append(wire[(escapeIndex + 1)...])
  #expect(second.frames.first?.payload == Data(payload))
  #expect(second.discards.isEmpty)
}

@Test func bytesBeforeTheFirstStartByteAreIgnored() throws {
  let good = try frame(TandemFrame.table1DataType, 0, [0x11]).encoded()
  var parser = FrameStreamParser()

  let output = parser.append(Data([0x00, 0xFF, 0x7E]) + good)

  #expect(output.frames.count == 1)
  #expect(output.discards.isEmpty)
}
