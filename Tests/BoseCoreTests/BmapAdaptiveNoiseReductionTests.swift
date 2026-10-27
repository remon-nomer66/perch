import Foundation
import Testing

@testable import BoseCore

@Test func anrSetRequestMatchesCaptureFormat() throws {
  // SETGET 01 06 02 01 <level>. Wire levels: 0 off, 1 high, 3 low.
  #expect(
    try BmapAdaptiveNoiseReduction.setRequest(level: BmapAdaptiveNoiseReduction.levelOff).encoded()
      == Data([0x01, 0x06, 0x02, 0x01, 0x00])
  )
  #expect(
    try BmapAdaptiveNoiseReduction.setRequest(level: BmapAdaptiveNoiseReduction.levelHigh).encoded()
      == Data([0x01, 0x06, 0x02, 0x01, 0x01])
  )
  #expect(
    try BmapAdaptiveNoiseReduction.setRequest(level: BmapAdaptiveNoiseReduction.levelLow).encoded()
      == Data([0x01, 0x06, 0x02, 0x01, 0x03])
  )
}

@Test func anrStatusParsesCaptureFormat() throws {
  // STATUS 01 06 03 02 <level> 0b -> payload [level, capabilities].
  let frame = try BmapFrame(fblock: 1, function: 6, op: .status, payload: Data([0x03, 0x0b]))
  let status = try BmapAdaptiveNoiseReduction.parseStatus(frame)
  #expect(status.level == 0x03)
  #expect(status.capabilities == 0x0b)
}

@Test func anrStatusRejectsTruncated() throws {
  let frame = try BmapFrame(fblock: 1, function: 6, op: .status, payload: Data([0x03]))
  #expect(throws: BmapAdaptiveNoiseReductionError.truncated(expected: 2, actual: 1)) {
    _ = try BmapAdaptiveNoiseReduction.parseStatus(frame)
  }
}

@Test func anrStatusRejectsWrongAddress() throws {
  let frame = try BmapFrame(fblock: 1, function: 5, op: .status, payload: Data([0x03, 0x0b]))
  #expect(throws: BmapAdaptiveNoiseReductionError.unexpectedAddress(fblock: 1, function: 5)) {
    _ = try BmapAdaptiveNoiseReduction.parseStatus(frame)
  }
}
