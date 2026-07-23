import Foundation
import Testing

@testable import TandemCore

@Test func speakToChatInquiryFollowsTheDeclaredFunction() {
  #expect(TandemSpeakToChatProtocol.inquiry(forDeclared: [0xFC]) == 0x0C)
  #expect(TandemSpeakToChatProtocol.inquiry(forDeclared: [0xF2]) == 0x02)
  // Type 2 wins when both are declared; nothing when neither is.
  #expect(TandemSpeakToChatProtocol.inquiry(forDeclared: [0xF2, 0xFC]) == 0x0C)
  #expect(TandemSpeakToChatProtocol.inquiry(forDeclared: [0x10]) == nil)
}

@Test func speakToChatType2RequestsMatchSonyCommands() throws {
  let inquiry = TandemSpeakToChatProtocol.inquiryType2
  #expect(
    try TandemSpeakToChatProtocol.capabilityRequest(sequence: 0, inquiry: inquiry).payload
      == Data([0xF0, 0x0C])
  )
  #expect(
    try TandemSpeakToChatProtocol.statusRequest(sequence: 1, inquiry: inquiry).payload
      == Data([0xF2, 0x0C])
  )
  #expect(
    try TandemSpeakToChatProtocol.parameterRequest(sequence: 0, inquiry: inquiry).payload
      == Data([0xF6, 0x0C])
  )
  #expect(
    try TandemSpeakToChatProtocol.extendedParameterRequest(sequence: 1, inquiry: inquiry).payload
      == Data([0xFA, 0x0C])
  )
  #expect(
    try TandemSpeakToChatProtocol.setEnabledRequest(
      sequence: 0,
      inquiry: inquiry,
      isEnabled: true,
      secondarySettingEnabled: false
    ).payload == Data([0xF8, 0x0C, 0x00, 0x01])
  )
  #expect(
    try TandemSpeakToChatProtocol.setDetailRequest(
      sequence: 1,
      inquiry: inquiry,
      sensitivity: .low,
      timeout: .none
    ).payload == Data([0xFC, 0x0C, 0x02, 0x03])
  )
}

@Test func type1RequestsUseTheOtherInquiry() throws {
  #expect(
    try TandemSpeakToChatProtocol.capabilityRequest(
      sequence: 0,
      inquiry: TandemSpeakToChatProtocol.inquiryType1
    ).payload == Data([0xF0, 0x02])
  )
}

@Test func capturedSpeakToChatValuesAreParsedAndSecondaryFieldIsPreserved() throws {
  let inquiry = TandemSpeakToChatProtocol.inquiryType2
  let capabilityFrame = try TandemFrame(
    dataType: TandemFrame.table1DataType,
    sequence: 0,
    payload: Data([0xF1, 0x0C, 0x01, 0x05, 0x0F, 0x1E])
  )
  let capability = try TandemSpeakToChatProtocol.parseCapabilityResponse(capabilityFrame, inquiry: inquiry)
  #expect(capability.supportsPreview)
  #expect(capability.seconds(for: .fast) == 5)
  #expect(capability.seconds(for: .medium) == 15)
  #expect(capability.seconds(for: .slow) == 30)
  #expect(capability.seconds(for: .none) == nil)

  let statusFrame = try TandemFrame(
    dataType: TandemFrame.table1DataType,
    sequence: 1,
    payload: Data([0xF3, 0x0C, 0x00, 0x00])
  )
  let status = try TandemSpeakToChatProtocol.parseStatusResponse(statusFrame, inquiry: inquiry)
  #expect(status.isControlEnabled)
  #expect(status.effectStatus == .notActive)

  let parameterFrame = try TandemFrame(
    dataType: TandemFrame.table1DataType,
    sequence: 0,
    payload: Data([0xF7, 0x0C, 0x01, 0x00])
  )
  let parameter = try TandemSpeakToChatProtocol.parseParameterResponse(parameterFrame, inquiry: inquiry)
  #expect(!parameter.isEnabled)
  #expect(parameter.secondarySettingEnabled)

  let detailFrame = try TandemFrame(
    dataType: TandemFrame.table1DataType,
    sequence: 1,
    payload: Data([0xFB, 0x0C, 0x00, 0x01])
  )
  let detail = try TandemSpeakToChatProtocol.parseExtendedParameterResponse(detailFrame, inquiry: inquiry)
  #expect(detail.sensitivity == .automatic)
  #expect(detail.timeout == .medium)
}

private func speakToChatFrame(_ payload: [UInt8]) throws -> TandemFrame {
  try TandemFrame(
    dataType: TandemFrame.table1DataType,
    sequence: 0,
    payload: Data(payload)
  )
}

@Test func speakToChatAnswersOutsideTheDeclaredShapeAreRefused() throws {
  let inquiry = TandemSpeakToChatProtocol.inquiryType2

  // A sensitivity byte outside the defined values.
  #expect(throws: TandemSpeakToChatError.invalidSensitivity(0x07)) {
    _ = try TandemSpeakToChatProtocol.parseExtendedParameterResponse(
      try speakToChatFrame([0xFB, 0x0C, 0x07, 0x01]), inquiry: inquiry
    )
  }
  // A timeout byte outside the defined values.
  #expect(throws: TandemSpeakToChatError.invalidTimeout(0x09)) {
    _ = try TandemSpeakToChatProtocol.parseExtendedParameterResponse(
      try speakToChatFrame([0xFB, 0x0C, 0x00, 0x09]), inquiry: inquiry
    )
  }
  // A capability answer one byte short.
  #expect(throws: TandemSpeakToChatError.invalidLength(5)) {
    _ = try TandemSpeakToChatProtocol.parseCapabilityResponse(
      try speakToChatFrame([0xF1, 0x0C, 0x01, 0x05, 0x0F]), inquiry: inquiry
    )
  }
  // A preview flag that is neither yes nor no.
  #expect(throws: TandemSpeakToChatError.invalidPreview(2)) {
    _ = try TandemSpeakToChatProtocol.parseCapabilityResponse(
      try speakToChatFrame([0xF1, 0x0C, 0x02, 0x05, 0x0F, 0x1E]), inquiry: inquiry
    )
  }
  // An effect status outside the defined values.
  #expect(throws: TandemSpeakToChatError.invalidEffectStatus(5)) {
    _ = try TandemSpeakToChatProtocol.parseStatusResponse(
      try speakToChatFrame([0xF3, 0x0C, 0x00, 0x05]), inquiry: inquiry
    )
  }
  // An on/off byte outside the defined values.
  #expect(throws: TandemSpeakToChatError.invalidOnOff(2)) {
    _ = try TandemSpeakToChatProtocol.parseParameterResponse(
      try speakToChatFrame([0xF7, 0x0C, 0x02, 0x00]), inquiry: inquiry
    )
  }
  // An answer keyed to the type-1 inquiry is refused when type 2 was asked, so
  // the two dialects cannot cross.
  #expect(
    throws: TandemSpeakToChatError.unexpectedPayload(
      expected: [0xF7, 0x0C], actual: [0xF7, 0x02]
    )
  ) {
    _ = try TandemSpeakToChatProtocol.parseParameterResponse(
      try speakToChatFrame([0xF7, 0x02, 0x00, 0x00]), inquiry: inquiry
    )
  }
}
