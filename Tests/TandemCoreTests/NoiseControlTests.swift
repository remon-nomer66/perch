import Foundation
import Testing

@testable import TandemCore

private func frame(_ bytes: [UInt8]) throws -> TandemFrame {
  try TandemFrame(dataType: TandemFrame.table1DataType, sequence: 0, payload: Data(bytes))
}

// The byte vectors below were captured from WF-1000XM6, so they anchor the layout to
// real hardware rather than to one reading of the documentation.

@Test func functionCodeSelectsTheInquiryByte() {
  // A device advertising the noise-adaptation family is driven by that variant.
  #expect(TandemNoiseControlType.inquiry(forDeclared: [0x6D]) == 0x19)
  #expect(TandemNoiseControlType.inquiry(forDeclared: [0x6B]) == 0x17)
  #expect(TandemNoiseControlType.inquiry(forDeclared: [0x61]) == 0x01)
  // The richest advertised variant wins when several are present.
  #expect(TandemNoiseControlType.inquiry(forDeclared: [0x61, 0x6D]) == 0x19)
  #expect(TandemNoiseControlType.inquiry(forDeclared: [0x99]) == nil)
}

@Test func modeByteZeroMeansNoiseCancelling() throws {
  // The subtle one: [4] == 0 is noise cancelling, not ambient sound. Reading it as a
  // plain boolean would invert it, and the inversion would sit in both read and write
  // so the read-back check could never catch it.
  let state = try TandemNoiseControlProtocol.parseParameterResponse(
    try frame([0x67, 0x19, 0x01, 0x01, 0x00, 0x00, 0x14, 0x00, 0x00]),
    inquiry: 0x19
  )
  #expect(state.isActive)
  #expect(state.isNoiseCancelling, "byte 4 == 0 was not read as noise cancelling")
  #expect(state.ambientLevel == 20)
  #expect(state.noiseAdaptation == .init(isOn: false, sensitivity: 0))
}

@Test func ambientSoundRoundTripsThroughSetAndParse() throws {
  let requested = TandemNoiseControlState(
    isActive: true,
    isNoiseCancelling: false,
    ambientMode: 1,
    ambientLevel: 12,
    noiseAdaptation: .init(isOn: false, sensitivity: 0)
  )
  let set = try TandemNoiseControlProtocol.setParameterRequest(
    sequence: 0,
    inquiry: 0x19,
    state: requested
  )
  #expect([UInt8](set.payload) == [0x68, 0x19, 0x01, 0x01, 0x01, 0x01, 0x0C, 0x00, 0x00])

  // What we send, parsed back as if the device echoed it, must equal what we asked.
  let echoed = try TandemNoiseControlProtocol.parseParameterResponse(
    try frame([0x67] + [UInt8](set.payload).dropFirst()),
    inquiry: 0x19
  )
  #expect(echoed.isNoiseCancelling == requested.isNoiseCancelling)
  #expect(echoed.ambientMode == requested.ambientMode)
  #expect(echoed.ambientLevel == requested.ambientLevel)
}

@Test func noiseCancellingSetKeepsTheEffectOnWithModeByteZero() throws {
  // Noise cancelling is the effect being ON with mode byte 0. This is where the
  // inversion mistake would show: mode 0 with the effect on, not the effect off.
  let set = try TandemNoiseControlProtocol.setParameterRequest(
    sequence: 0,
    inquiry: 0x19,
    state: TandemNoiseControlState(
      isActive: true,
      isNoiseCancelling: true,
      ambientMode: 0,
      ambientLevel: 20,
      noiseAdaptation: .init(isOn: false, sensitivity: 0)
    )
  )
  #expect([UInt8](set.payload) == [0x68, 0x19, 0x01, 0x01, 0x00, 0x00, 0x14, 0x00, 0x00])
}

@Test func turningEverythingOffSendsTheEffectOffBit() throws {
  // Distinct from noise cancelling: the effect bit is 0. The mode byte is retained so
  // the device knows which mode to return to.
  let set = try TandemNoiseControlProtocol.setParameterRequest(
    sequence: 0,
    inquiry: 0x19,
    state: TandemNoiseControlState(
      isActive: false,
      isNoiseCancelling: true,
      ambientMode: 0,
      ambientLevel: 20,
      noiseAdaptation: .init(isOn: false, sensitivity: 0)
    )
  )
  #expect([UInt8](set.payload) == [0x68, 0x19, 0x01, 0x00, 0x00, 0x00, 0x14, 0x00, 0x00])
}

@Test func aShorterVariantOmitsTheFieldsItDoesNotHave() throws {
  // Type 0x17 stops after the ambient level: no noise adaptation. The parser must not
  // invent one.
  let state = try TandemNoiseControlProtocol.parseParameterResponse(
    try frame([0x67, 0x17, 0x01, 0x01, 0x01, 0x00, 0x08]),
    inquiry: 0x17
  )
  #expect(state.isActive)
  #expect(!state.isNoiseCancelling)
  #expect(state.ambientLevel == 8)
  #expect(state.noiseAdaptation == nil)
}

@Test func capabilityListsEveryModeTheDeviceOffers() throws {
  // Captured from WF: two modes, level 1..20, step 1.
  let modes = try TandemNoiseControlProtocol.parseCapabilityResponse(
    try frame([0x61, 0x19, 0x02, 0x00, 0x01, 0x14, 0x01, 0x01, 0x01, 0x14, 0x01]),
    inquiry: 0x19
  )
  #expect(modes.count == 2)
  #expect(modes[0].mode == 0)
  #expect(modes[0].range == 1...20)
  #expect(modes[1].mode == 1)
}

@Test func simpleDialectsAreNotSentFieldsTheyDoNotDefine() throws {
  // A device whose parameter response stops after the on/off flag (2 value bytes) must
  // receive a SET of the same shape, not the full mode/ambient/level payload.
  let onOffOnly = try TandemNoiseControlProtocol.setParameterRequest(
    sequence: 0,
    inquiry: 0x01,
    state: TandemNoiseControlState(
      isActive: true,
      isNoiseCancelling: true,
      ambientMode: 0,
      ambientLevel: 20
    ),
    valueFieldCount: 2
  )
  #expect([UInt8](onOffOnly.payload) == [0x68, 0x01, 0x01, 0x01])

  // A level dialect with no noise adaptation (5 value bytes) keeps through the level.
  let level = try TandemNoiseControlProtocol.setParameterRequest(
    sequence: 0,
    inquiry: 0x17,
    state: TandemNoiseControlState(
      isActive: true,
      isNoiseCancelling: false,
      ambientMode: 1,
      ambientLevel: 8
    ),
    valueFieldCount: 5
  )
  #expect([UInt8](level.payload) == [0x68, 0x17, 0x01, 0x01, 0x01, 0x01, 0x08])
}

@Test func dialectCapabilitiesFollowTheInquiry() {
  // On/off only: noise cancelling and off, but no ambient.
  #expect(TandemNoiseControlType.hasNoiseCancelling(0x01))
  #expect(!TandemNoiseControlType.hasAmbient(0x01))
  // Ambient only: ambient and off, but no noise cancelling.
  #expect(!TandemNoiseControlType.hasNoiseCancelling(0x22))
  #expect(TandemNoiseControlType.hasAmbient(0x22))
  // A full mode-select dialect has both.
  #expect(TandemNoiseControlType.hasNoiseCancelling(0x19))
  #expect(TandemNoiseControlType.hasAmbient(0x19))
}

@Test func aMismatchedInquiryIsRejected() {
  #expect(throws: TandemNoiseControlError.unexpectedInquiry(0x17)) {
    _ = try TandemNoiseControlProtocol.parseParameterResponse(
      try frame([0x67, 0x17, 0x01, 0x01, 0x00, 0x00, 0x14]),
      inquiry: 0x19
    )
  }
}
