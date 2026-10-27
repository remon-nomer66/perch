import Foundation
import Testing

@testable import BoseCore

// MARK: - CNC read [1.5]

@Test func cncReadParsesCapturedBytes() throws {
  // Capture 0b 00 03 -> current 0, max 10 (numSteps 0x0b - 1), enabled.
  let frame = try BmapFrame(
    fblock: 1, function: 5, op: .status, payload: Data([0x0b, 0x00, 0x03])
  )
  let reading = try BmapNoiseCancellationReader.parse(frame)
  #expect(reading.currentStep == 0)
  #expect(reading.maximumStep == 10)
  #expect(reading.isEnabled)
  #expect(reading.rawFlags == 0x03)
}

@Test func cncReadRequestIsGetTo15() throws {
  #expect(try BmapNoiseCancellationReader.readRequest().encoded() == Data([0x01, 0x05, 0x01, 0x00]))
}

@Test func cncReadRejectsTruncated() throws {
  let frame = try BmapFrame(fblock: 1, function: 5, op: .status, payload: Data([0x0b, 0x00]))
  #expect(throws: BmapNoiseCancellationError.truncated(expected: 3, actual: 2)) {
    _ = try BmapNoiseCancellationReader.parse(frame)
  }
}

// MARK: - Live write [31.10]

@Test func liveWriteBuildsFiveBytePayload() throws {
  let setting = BmapNoiseControlSetting(cnc: 5, spatial: .off, windBlock: false, ancEnabled: true)
  let frame = try BmapNoiseControlLiveWrite.writeRequest(setting)
  #expect(frame.address == .noiseControlLiveWrite)
  #expect(frame.op == .setGet)
  // autoCNC (byte 1) is forced to 0.
  #expect([UInt8](frame.payload) == [0x05, 0x00, 0x00, 0x00, 0x01])
  // fblock 31 = 0x1F, func 10 = 0x0A, flags SETGET = 0x02, len 5.
  #expect(frame.encoded() == Data([0x1F, 0x0A, 0x02, 0x05, 0x05, 0x00, 0x00, 0x00, 0x01]))
}

@Test func liveWriteRoundTrips() throws {
  let setting = BmapNoiseControlSetting(cnc: 3, spatial: .head, windBlock: true, ancEnabled: false)
  let frame = try BmapNoiseControlLiveWrite.writeRequest(setting)
  #expect(try BmapNoiseControlLiveWrite.parse(frame) == setting)
}

@Test func liveWriteRejectsCncOutOfRange() {
  #expect(throws: BmapNoiseControlLiveWriteError.cncOutOfRange(11)) {
    _ = try BmapNoiseControlLiveWrite.writeRequest(
      BmapNoiseControlSetting(cnc: 11, spatial: .off, windBlock: false, ancEnabled: true)
    )
  }
}

@Test func liveWriteParseRejectsInvalidSpatial() throws {
  let frame = try BmapFrame(
    fblock: 31, function: 10, op: .setGet, payload: Data([0x05, 0x00, 0x03, 0x00, 0x01])
  )
  #expect(throws: BmapNoiseControlLiveWriteError.invalidSpatial(3)) {
    _ = try BmapNoiseControlLiveWrite.parse(frame)
  }
}

@Test func liveWriteParseRejectsTruncated() throws {
  let frame = try BmapFrame(
    fblock: 31, function: 10, op: .setGet, payload: Data([0x05, 0x00, 0x00, 0x00])
  )
  #expect(throws: BmapNoiseControlLiveWriteError.truncated(expected: 5, actual: 4)) {
    _ = try BmapNoiseControlLiveWrite.parse(frame)
  }
}

@Test func liveWriteParseRejectsCncOutOfRange() throws {
  // A misbehaving device returning cnc past 0...10 must fail on the way in, symmetric
  // with writeRequest — a read-back is fed straight back into a write.
  let frame = try BmapFrame(
    fblock: 31, function: 10, op: .setGet, payload: Data([0x0B, 0x00, 0x00, 0x00, 0x01])
  )
  #expect(throws: BmapNoiseControlLiveWriteError.cncOutOfRange(11)) {
    _ = try BmapNoiseControlLiveWrite.parse(frame)
  }
}
