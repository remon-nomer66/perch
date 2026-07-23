import Foundation
import Testing

@testable import TandemCore

// The older service generation — the WF-1000XM3 era — speaks the same command
// families with shorter payloads and its own inquiry bytes. The layouts here are
// taken from the Gadgetbridge v1 implementation and validated against a live
// WF-1000XM3; see the probe captures.

private func frame(_ payload: [UInt8]) throws -> TandemFrame {
  try TandemFrame(
    dataType: TandemFrame.table1DataType,
    sequence: 1,
    payload: Data(payload)
  )
}

// MARK: - Dialect marking

@Test func theShortHandshakeMarksTheLegacyDialect() throws {
  let short = try frame([0x01, 0x00, 0x02, 0x01])
  #expect(try TandemReadOnlyHandshake.parseProtocolResponse(short).dialect == .legacy)

  let full = try frame([0x01, 0x00, 0x03, 0x00, 0x30, 0x02, 0x00, 0x00])
  #expect(try TandemReadOnlyHandshake.parseProtocolResponse(full).dialect == .current)
}

// MARK: - Battery

@Test func legacyBatteryRequestUsesTheOldCommand() throws {
  let request = try TandemReadOnlyStatus.batteryRequest(
    query: .leftRight, sequence: 0, dialect: .legacy
  )
  #expect([UInt8](request.payload) == [0x10, 0x01])
}

@Test func legacyEarbudBatteryIsParsed() throws {
  let reply = try frame([0x11, 0x01, 0x50, 0x00, 0x46, 0x01])
  let status = try TandemReadOnlyStatus.parseBatteryResponse(
    reply, query: .leftRight, dialect: .legacy
  )
  #expect(status.units.map(\.percent) == [0x50, 0x46])
  #expect(status.units.map(\.chargingStatus) == [.notCharging, .charging])
}

@Test func legacyCaseBatteryIsParsed() throws {
  let reply = try frame([0x11, 0x02, 0x64, 0x00])
  let status = try TandemReadOnlyStatus.parseBatteryResponse(
    reply, query: .chargingCase, dialect: .legacy
  )
  #expect(status.units.map(\.percent) == [0x64])
}

// MARK: - Codec

@Test func legacyCodecRequestAndResponseUseTheOldCommand() throws {
  let request = try TandemReadOnlyStatus.audioCodecRequest(sequence: 0, dialect: .legacy)
  #expect([UInt8](request.payload) == [0x18, 0x00])

  let reply = try frame([0x19, 0x00, 0x02])
  #expect(try TandemReadOnlyStatus.parseAudioCodecResponse(reply, dialect: .legacy) == .aac)
}

// MARK: - Noise control

@Test func legacyNoiseParameterIsParsed() throws {
  // Noise cancelling on, wind-capable layout — captured from a WF-1000XM3, whose
  // submode for noise cancelling is 2.
  let noiseCancelling = try TandemNoiseControlProtocol.parseParameterResponse(
    try frame([0x67, 0x02, 0x01, 0x02, 0x02, 0x01, 0x01, 0x00]),
    inquiry: TandemNoiseControlProtocol.legacyInquiry
  )
  #expect(noiseCancelling.isActive)
  #expect(noiseCancelling.isNoiseCancelling)

  // Ambient sound with voice focus at level 20, captured from the same device.
  let ambient = try TandemNoiseControlProtocol.parseParameterResponse(
    try frame([0x67, 0x02, 0x01, 0x02, 0x00, 0x01, 0x01, 0x14]),
    inquiry: TandemNoiseControlProtocol.legacyInquiry
  )
  #expect(ambient.isActive)
  #expect(!ambient.isNoiseCancelling)
  #expect(ambient.ambientMode == 1)
  #expect(ambient.ambientLevel == 20)

  // The plain layout marks noise cancelling with submode 1.
  let plainNoiseCancelling = try TandemNoiseControlProtocol.parseParameterResponse(
    try frame([0x67, 0x02, 0x01, 0x00, 0x01, 0x01, 0x00, 0x00]),
    inquiry: TandemNoiseControlProtocol.legacyInquiry
  )
  #expect(plainNoiseCancelling.isNoiseCancelling)

  // Everything off.
  let off = try TandemNoiseControlProtocol.parseParameterResponse(
    try frame([0x67, 0x02, 0x00, 0x02, 0x00, 0x01, 0x00, 0x0A]),
    inquiry: TandemNoiseControlProtocol.legacyInquiry
  )
  #expect(!off.isActive)
}

@Test func legacyNoiseSetRequestSpeaksTheOldLayout() throws {
  func payload(_ state: TandemNoiseControlState, wind: UInt8) throws -> [UInt8] {
    let request = try TandemNoiseControlProtocol.setParameterRequest(
      sequence: 0,
      inquiry: TandemNoiseControlProtocol.legacyInquiry,
      state: state,
      legacyWindKind: wind
    )
    return [UInt8](request.payload)
  }

  // Under the wind-capable layout noise cancelling is submode 2, and its level is
  // zeroed the way the device itself reports it.
  let noiseCancelling = TandemNoiseControlState(
    isActive: true, isNoiseCancelling: true, ambientMode: 0, ambientLevel: 10
  )
  #expect(try payload(noiseCancelling, wind: 2) == [0x68, 0x02, 0x11, 0x02, 0x02, 0x01, 0x00, 0x00])
  // Under the plain layout it is submode 1.
  #expect(try payload(noiseCancelling, wind: 0) == [0x68, 0x02, 0x11, 0x00, 0x01, 0x01, 0x00, 0x00])

  let ambientVoice = TandemNoiseControlState(
    isActive: true, isNoiseCancelling: false, ambientMode: 1, ambientLevel: 20
  )
  #expect(try payload(ambientVoice, wind: 2) == [0x68, 0x02, 0x11, 0x02, 0x00, 0x01, 0x01, 0x14])

  let off = TandemNoiseControlState(
    isActive: false, isNoiseCancelling: false, ambientMode: 0, ambientLevel: 10
  )
  #expect(try payload(off, wind: 2) == [0x68, 0x02, 0x00, 0x02, 0x00, 0x01, 0x00, 0x0A])
}

// MARK: - Equaliser

@Test func legacyEqualizerParameterUsesItsOwnInquiry() throws {
  let request = try TandemReadOnlyEqualizer.parameterRequest(sequence: 0, inquiry: 0x01)
  #expect([UInt8](request.payload) == [0x56, 0x01])

  let capability = TandemEqualizerCapability(bandCount: 6, levelStepCount: 21, presets: [])
  let params = try TandemReadOnlyEqualizer.parseParameterResponse(
    try frame([0x57, 0x01, 0xA1, 0x06, 0x0A, 0x0C, 0x0A, 0x08, 0x0A, 0x0A]),
    capability: capability,
    inquiry: 0x01
  )
  #expect(params.presetIdentifier == 0xA1)
  #expect(params.bandSteps == [0x0A, 0x0C, 0x0A, 0x08, 0x0A, 0x0A])
}

@Test func legacyEqualizerSetRequestUsesItsOwnInquiry() throws {
  let preset = try TandemReadOnlyEqualizer.setParameterRequest(
    sequence: 0, presetIdentifier: 0x16, bandSteps: [], inquiry: 0x01
  )
  #expect([UInt8](preset.payload) == [0x58, 0x01, 0x16, 0x00])

  let bands = try TandemReadOnlyEqualizer.setParameterRequest(
    sequence: 0, presetIdentifier: 0xFF, bandSteps: [10, 12, 10, 8, 10, 10], inquiry: 0x01
  )
  #expect([UInt8](bands.payload) == [0x58, 0x01, 0xFF, 0x06, 10, 12, 10, 8, 10, 10])
}
