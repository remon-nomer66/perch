import Foundation
import Testing

@testable import BoseCore

@Test func frameRoundTripsThroughEncodeAndDecode() throws {
  // Battery [2.2] STATUS carrying the captured 50 ff ff 00.
  let frame = try BmapFrame(
    fblock: 2, function: 2, op: .status, payload: Data([0x50, 0xff, 0xff, 0x00])
  )
  let wire = frame.encoded()
  #expect(wire == Data([0x02, 0x02, 0x03, 0x04, 0x50, 0xff, 0xff, 0x00]))
  #expect(try BmapFrame.decode(wire) == frame)
}

@Test func flagsComposeDeviceIdPortAndOperator() throws {
  let frame = try BmapFrame(fblock: 0, function: 0, op: .get, deviceId: 1, port: 2)
  // (1 << 6) | (2 << 4) | 1 == 0x61.
  #expect(frame.flags == 0x61)
  let decoded = try BmapFrame.decode(frame.encoded())
  #expect(decoded.deviceId == 1)
  #expect(decoded.port == 2)
  #expect(decoded.op == .get)
}

@Test func addressReflectsBlockAndFunction() throws {
  let frame = try BmapFrame(fblock: 1, function: 7, op: .get)
  #expect(frame.address == .equalizer)
}

@Test func decodeRejectsInvalidOperatorNibble() {
  // Nibble 8 is beyond the defined 0...7 operators.
  #expect(throws: BmapFrameError.invalidOperator(0x08)) {
    _ = try BmapFrame.decode([0x00, 0x00, 0x08, 0x00])
  }
}

@Test func decodeRejectsLengthMismatch() {
  #expect(throws: BmapFrameError.lengthMismatch(declared: 2, actual: 1)) {
    _ = try BmapFrame.decode([0x02, 0x02, 0x03, 0x02, 0x50])
  }
}

@Test func decodeRejectsTooShort() {
  #expect(throws: BmapFrameError.tooShort(3)) {
    _ = try BmapFrame.decode([0x00, 0x00, 0x01])
  }
}

@Test func initRejectsOutOfRangeFields() {
  #expect(throws: BmapFrameError.deviceIdOutOfRange(4)) {
    _ = try BmapFrame(fblock: 0, function: 0, op: .get, deviceId: 4)
  }
  #expect(throws: BmapFrameError.portOutOfRange(4)) {
    _ = try BmapFrame(fblock: 0, function: 0, op: .get, port: 4)
  }
  #expect(throws: BmapFrameError.payloadTooLarge(256)) {
    _ = try BmapFrame(
      fblock: 0, function: 0, op: .get, payload: Data(repeating: 0, count: 256)
    )
  }
}
