import Foundation
import Testing

@testable import TandemCore

@Test func generalSettingRequestsDoNotHardcodeSidetoneSlot() throws {
  #expect(
    try TandemGeneralSettingProtocol.capabilityRequest(sequence: 0, slot: .one).payload
      == Data([0xD0, 0xD1, 0x0B])
  )
  #expect(
    try TandemGeneralSettingProtocol.capabilityRequest(sequence: 1, slot: .four).payload
      == Data([0xD0, 0xD4, 0x0B])
  )
  #expect(
    try TandemGeneralSettingProtocol.setParameterRequest(
      sequence: 0,
      slot: .two,
      value: .boolean(true)
    ).payload == Data([0xD8, 0xD2, 0x00, 0x00])
  )
}

@Test func sidetoneIsIdentifiedByCapabilityTitleNotSlotNumber() throws {
  let title = Array("SIDETONE_SETTING".utf8)
  let frame = try TandemFrame(
    dataType: TandemFrame.table1DataType,
    sequence: 0,
    payload: Data(
      [0xD1, 0xD4, 0x00, 0x01, UInt8(title.count)]
        + title
        + [0x00]
    )
  )
  let capability = try TandemGeneralSettingProtocol.parseCapabilityResponse(frame)
  #expect(capability.slot == .four)
  #expect(capability.type == .boolean)
  #expect(capability.label.title == "SIDETONE_SETTING")
  #expect(capability.isSidetone)

  let statusFrame = try TandemFrame(
    dataType: TandemFrame.table1DataType,
    sequence: 1,
    payload: Data([0xD3, 0xD4, 0x00])
  )
  #expect(
    try TandemGeneralSettingProtocol.parseStatusResponse(statusFrame, slot: .four)
  )

  let parameterFrame = try TandemFrame(
    dataType: TandemFrame.table1DataType,
    sequence: 0,
    payload: Data([0xD7, 0xD4, 0x00, 0x01])
  )
  #expect(
    try TandemGeneralSettingProtocol.parseParameterResponse(
      parameterFrame,
      capability: capability
    ) == .boolean(false)
  )
}

@Test func aBooleanSetRoundTripsThroughTheParameterResponse() throws {
  // The wire meaning of on/off is 0x00/0x01. A set built for a value, echoed back by
  // the device as its parameter answer, must land on the same value — this is the
  // exchange the write read-back rests on.
  let capability = TandemGeneralSettingCapability(
    slot: .three,
    type: .boolean,
    label: TandemGeneralString(format: .enumName, title: "SIDETONE_SETTING", summary: ""),
    listValues: []
  )
  for enabled in [true, false] {
    let set = try TandemGeneralSettingProtocol.setParameterRequest(
      sequence: 0,
      slot: .three,
      value: .boolean(enabled)
    )
    let bytes = [UInt8](set.payload)
    #expect(bytes == [0xD8, 0xD3, 0x00, enabled ? 0x00 : 0x01])

    let echo = try TandemFrame(
      dataType: TandemFrame.table1DataType,
      sequence: 1,
      payload: Data([0xD7, 0xD3, bytes[2], bytes[3]])
    )
    #expect(
      try TandemGeneralSettingProtocol.parseParameterResponse(echo, capability: capability)
        == .boolean(enabled)
    )
  }
}

@Test func aListSetRoundTripsAndAnUndeclaredIndexIsRefused() throws {
  let capability = TandemGeneralSettingCapability(
    slot: .one,
    type: .list,
    label: TandemGeneralString(format: .enumName, title: "MODE", summary: ""),
    listValues: [
      TandemGeneralString(format: .enumName, title: "A", summary: ""),
      TandemGeneralString(format: .enumName, title: "B", summary: ""),
      TandemGeneralString(format: .enumName, title: "C", summary: ""),
    ]
  )
  let set = try TandemGeneralSettingProtocol.setParameterRequest(
    sequence: 0,
    slot: .one,
    value: .list(2)
  )
  let bytes = [UInt8](set.payload)
  #expect(bytes == [0xD8, 0xD1, 0x01, 0x02])

  let echo = try TandemFrame(
    dataType: TandemFrame.table1DataType,
    sequence: 1,
    payload: Data([0xD7, 0xD1, bytes[2], bytes[3]])
  )
  #expect(
    try TandemGeneralSettingProtocol.parseParameterResponse(echo, capability: capability)
      == .list(2)
  )

  // A set outside the encodable range never leaves the app; an answer naming a
  // choice the device did not declare is refused rather than shown.
  #expect(throws: TandemGeneralSettingError.self) {
    try TandemGeneralSettingProtocol.setParameterRequest(sequence: 0, slot: .one, value: .list(64))
  }
  let undeclared = try TandemFrame(
    dataType: TandemFrame.table1DataType,
    sequence: 1,
    payload: Data([0xD7, 0xD1, 0x01, 0x03])
  )
  #expect(throws: TandemGeneralSettingError.self) {
    try TandemGeneralSettingProtocol.parseParameterResponse(undeclared, capability: capability)
  }
}

@Test func generalListCapabilityParsesAllDescriptions() throws {
  func text(_ value: String) -> [UInt8] {
    let bytes = Array(value.utf8)
    return [0x01, UInt8(bytes.count)] + bytes + [0x00]
  }
  let frame = try TandemFrame(
    dataType: TandemFrame.table1DataType,
    sequence: 0,
    payload: Data([0xD1, 0xD1, 0x01] + text("MODE") + [0x02] + text("A") + text("B"))
  )
  let capability = try TandemGeneralSettingProtocol.parseCapabilityResponse(frame)
  #expect(capability.listValues.map(\.title) == ["A", "B"])
}

@Test func aListCapabilityWhoseCountDisagreesIsRefused() throws {
  func text(_ value: String) -> [UInt8] {
    let bytes = Array(value.utf8)
    return [0x01, UInt8(bytes.count)] + bytes + [0x00]
  }
  // Two entries declared, one present.
  let frame = try TandemFrame(
    dataType: TandemFrame.table1DataType,
    sequence: 0,
    payload: Data([0xD1, 0xD1, 0x01] + text("MODE") + [0x02] + text("A"))
  )
  #expect(throws: TandemGeneralSettingError.listCountMismatch(expected: 2, actual: 1)) {
    _ = try TandemGeneralSettingProtocol.parseCapabilityResponse(frame)
  }
}

@Test func aSetIsCheckedAgainstTheDeclaredCapabilityBeforeTheWire() throws {
  let capability = TandemGeneralSettingCapability(
    slot: .one,
    type: .list,
    label: TandemGeneralString(format: .enumName, title: "MODE", summary: ""),
    listValues: [
      TandemGeneralString(format: .enumName, title: "A", summary: ""),
      TandemGeneralString(format: .enumName, title: "B", summary: ""),
      TandemGeneralString(format: .enumName, title: "C", summary: ""),
    ]
  )

  // An index the device declared passes and encodes exactly as before.
  let set = try TandemGeneralSettingProtocol.setParameterRequest(
    sequence: 0, slot: .one, value: .list(2), capability: capability
  )
  #expect([UInt8](set.payload) == [0xD8, 0xD1, 0x01, 0x02])

  // An index past the declared list is refused even though the wire could
  // encode it: the device never named a fourth choice.
  #expect(throws: TandemGeneralSettingError.invalidValue(3)) {
    _ = try TandemGeneralSettingProtocol.setParameterRequest(
      sequence: 0, slot: .one, value: .list(3), capability: capability
    )
  }
  // A value of the wrong type for the declared setting.
  #expect(throws: TandemGeneralSettingError.typeMismatch) {
    _ = try TandemGeneralSettingProtocol.setParameterRequest(
      sequence: 0, slot: .one, value: .boolean(true), capability: capability
    )
  }
  // A capability paired with another slot's write is a caller bug, refused
  // rather than sent for the device to sort out.
  #expect(throws: TandemGeneralSettingError.invalidSlot(TandemGeneralSettingSlot.two.rawValue)) {
    _ = try TandemGeneralSettingProtocol.setParameterRequest(
      sequence: 0, slot: .two, value: .list(0), capability: capability
    )
  }
  // Without a capability the single-byte wire cap remains the last line of
  // defence.
  #expect(throws: TandemGeneralSettingError.self) {
    _ = try TandemGeneralSettingProtocol.setParameterRequest(
      sequence: 0, slot: .one, value: .list(64)
    )
  }
}
