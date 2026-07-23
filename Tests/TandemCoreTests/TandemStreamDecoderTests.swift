import Foundation
import Testing

@testable import TandemCore

// The decoder faces a live RFCOMM stream: one corrupted frame, or a stretch of
// garbage with no terminator, must never cost the frames around it or wedge the
// decoder's state.

@Test func aBadFrameCostsOnlyItselfNotItsNeighbours() throws {
  let first = try TandemFrame(
    dataType: TandemFrame.table1DataType, sequence: 0, payload: Data([0x01])
  )
  let second = try TandemFrame(
    dataType: TandemFrame.table1DataType, sequence: 1, payload: Data([0x02])
  )
  // A frame whose checksum byte was corrupted in transit.
  var bad = [UInt8](
    try TandemFrame(
      dataType: TandemFrame.table1DataType, sequence: 1, payload: Data([0x05])
    ).encoded()
  )
  bad[bad.count - 2] ^= 0x01

  var decoder = TandemStreamDecoder()
  var chunk = Data()
  chunk.append(first.encoded())
  chunk.append(Data(bad))
  chunk.append(second.encoded())

  // The error is still reported...
  #expect(throws: TandemFrameError.self) {
    _ = try decoder.append(chunk)
  }
  // ...but every good frame around it — before and after — is delivered by the
  // next call instead of being lost with the bad one.
  #expect(try decoder.append(Data()) == [first, second])
  // And the internal state is clean for further input.
  #expect(try decoder.append(first.encoded()) == [first])
}

@Test func anInvalidEscapeDoesNotPoisonSubsequentFrames() throws {
  var decoder = TandemStreamDecoder()
  #expect(throws: TandemFrameError.invalidEscape(0x00)) {
    _ = try decoder.append(
      Data([TandemFrame.startByte, TandemFrame.escapeByte, 0x00])
    )
  }
  // The decoder resynchronises on the next start byte.
  let frame = try TandemFrame(
    dataType: TandemFrame.table1DataType, sequence: 0, payload: Data([0x07])
  )
  #expect(try decoder.append(frame.encoded()) == [frame])
}

@Test func aStreamWithoutATerminatorIsBoundedByTheConfiguredMaximum() throws {
  // 8 payload bytes plus 7 framing bytes: anything longer cannot be a frame, so
  // buffering must stop instead of growing without bound on a hostile stream.
  var decoder = TandemStreamDecoder(maximumPayloadLength: 8)
  var stream = Data([TandemFrame.startByte])
  stream.append(Data(repeating: 0x00, count: 16))
  #expect(throws: TandemFrameError.frameTooLong(maximum: 15)) {
    _ = try decoder.append(stream)
  }
  // After the oversized garbage the decoder picks up the next frame.
  let frame = try TandemFrame(
    dataType: TandemFrame.table1DataType, sequence: 0, payload: Data([0x01])
  )
  #expect(try decoder.append(frame.encoded()) == [frame])
}

@Test func escapedBytesRespectTheSameBodyBound() throws {
  // The bound must hold whether bytes arrive plain or escaped.
  var decoder = TandemStreamDecoder(maximumPayloadLength: 0)
  var stream = Data([TandemFrame.startByte])
  for _ in 0..<8 {
    stream.append(TandemFrame.escapeByte)
    stream.append(0x2C)
  }
  #expect(throws: TandemFrameError.frameTooLong(maximum: 7)) {
    _ = try decoder.append(stream)
  }
}

@Test func shotDataTypesDoNotRequireAcknowledgement() throws {
  // The shot values keep their pairing with the two-way data types.
  #expect(TandemFrame.shotTable1DataType == TandemFrame.table1DataType | 0x10)
  #expect(TandemFrame.shotTable2DataType == TandemFrame.table2DataType | 0x10)

  for dataType in TandemFrame.shotDataTypes {
    let frame = try TandemFrame(dataType: dataType, sequence: 0, payload: Data())
    #expect(!frame.requiresAcknowledgement, "shot type 0x\(String(dataType, radix: 16)) must not be ACKed")
  }
  #expect(
    !(try TandemFrame(
      dataType: TandemFrame.ackDataType, sequence: 0, payload: Data()
    )).requiresAcknowledgement
  )
  #expect(
    (try TandemFrame(
      dataType: TandemFrame.table1DataType, sequence: 0, payload: Data()
    )).requiresAcknowledgement
  )
  #expect(
    (try TandemFrame(
      dataType: TandemFrame.table2DataType, sequence: 0, payload: Data()
    )).requiresAcknowledgement
  )
}
