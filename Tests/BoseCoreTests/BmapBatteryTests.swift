import Foundation
import Testing

@testable import BoseCore

@Test func ultraBatteryParsesCapturedBytes() throws {
  // Ultra 2 capture 50 ff ff 00 -> 80%, remaining unknown, component 0.
  let frame = try BmapFrame(
    fblock: 2, function: 2, op: .status, payload: Data([0x50, 0xff, 0xff, 0x00])
  )
  let components = try BmapBattery.parse(frame, layout: .componentGroups)
  #expect(components == [
    BmapBatteryComponent(percent: 80, minutesRemaining: nil, componentId: 0)
  ])
}

@Test func qc35BatteryParsesSingleByte() throws {
  let frame = try BmapFrame(fblock: 2, function: 2, op: .status, payload: Data([0x50]))
  let components = try BmapBattery.parse(frame, layout: .singleByte)
  #expect(components == [
    BmapBatteryComponent(percent: 80, minutesRemaining: nil, componentId: nil)
  ])
}

@Test func ultraBatteryParsesMultipleComponents() throws {
  // Synthetic two-component payload (multi-component data is unverified per the frozen
  // spec, so these bytes exercise the loop rather than reproduce a capture):
  // 90% / 120 min / component 1, then 55% / unknown / component 2.
  let payload = Data([0x5A, 0x00, 0x78, 0x01, 0x37, 0xff, 0xff, 0x02])
  let frame = try BmapFrame(fblock: 2, function: 2, op: .status, payload: payload)
  let components = try BmapBattery.parse(frame, layout: .componentGroups)
  #expect(components == [
    BmapBatteryComponent(percent: 90, minutesRemaining: 120, componentId: 1),
    BmapBatteryComponent(percent: 55, minutesRemaining: nil, componentId: 2),
  ])
}

@Test func batteryRejectsMalformedGroups() throws {
  let frame = try BmapFrame(
    fblock: 2, function: 2, op: .status, payload: Data([0x50, 0xff, 0xff])
  )
  #expect(throws: BmapBatteryError.malformedComponentGroups(3)) {
    _ = try BmapBattery.parse(frame, layout: .componentGroups)
  }
}

@Test func batteryRejectsOutOfRangePercent() throws {
  let frame = try BmapFrame(fblock: 2, function: 2, op: .status, payload: Data([0x65]))  // 101
  #expect(throws: BmapBatteryError.percentOutOfRange(101)) {
    _ = try BmapBattery.parse(frame, layout: .singleByte)
  }
}

@Test func batteryRejectsEmptyPayload() throws {
  let frame = try BmapFrame(fblock: 2, function: 2, op: .status, payload: Data())
  #expect(throws: BmapBatteryError.emptyPayload) {
    _ = try BmapBattery.parse(frame, layout: .componentGroups)
  }
}

@Test func batteryRejectsWrongAddress() throws {
  let frame = try BmapFrame(fblock: 1, function: 5, op: .status, payload: Data([0x50]))
  #expect(throws: BmapBatteryError.unexpectedAddress(fblock: 1, function: 5)) {
    _ = try BmapBattery.parse(frame, layout: .singleByte)
  }
}
