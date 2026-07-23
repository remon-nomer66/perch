import Foundation
import Testing

@testable import TandemCore

@Test func equalizerRequestsMatchSonyV2Commands() throws {
  #expect(
    try TandemReadOnlyEqualizer.capabilityRequest(sequence: 0).payload
      == Data([0x50, 0x04, 0x0B])
  )
  #expect(
    try TandemReadOnlyEqualizer.statusRequest(sequence: 1).payload
      == Data([0x52, 0x04])
  )
  #expect(
    try TandemReadOnlyEqualizer.parameterRequest(sequence: 0).payload
      == Data([0x56, 0x04])
  )
  #expect(
    try TandemReadOnlyEqualizer.extendedInfoRequest(sequence: 1).payload
      == Data([0x5A, 0x04])
  )
  #expect(
    try TandemReadOnlyEqualizer.setParameterRequest(
      sequence: 0,
      presetIdentifier: 0xA0,
      bandSteps: Array(repeating: 6, count: 10)
    ).payload
      == Data([0x58, 0x04, 0xA0, 0x0A] + Array(repeating: 6, count: 10))
  )
}

@Test func capturedTenBandEqualizerResponsesAreParsed() throws {
  let capabilityFrame = try TandemFrame(
    dataType: TandemFrame.table1DataType,
    sequence: 1,
    payload: Data([
      0x51, 0x04, 0x0A, 0x0D, 0x02,
      0x00, 0x03, 0x4F, 0x46, 0x46,
      0xA0, 0x06, 0x43, 0x55, 0x53, 0x54, 0x4F, 0x4D,
    ])
  )
  let capability = try TandemReadOnlyEqualizer.parseCapabilityResponse(capabilityFrame)
  #expect(capability.bandCount == 10)
  #expect(capability.levelStepCount == 13)
  #expect(capability.presets.map(\.identifier) == [0x00, 0xA0])
  #expect(capability.presets.map(\.name) == ["OFF", "CUSTOM"])

  let statusFrame = try TandemFrame(
    dataType: TandemFrame.table1DataType,
    sequence: 0,
    payload: Data([0x53, 0x04, 0x00, 0x00])
  )
  let status = try TandemReadOnlyEqualizer.parseStatusResponse(statusFrame)
  #expect(status.isEnabled)
  #expect(status.errorCodes.isEmpty)

  let parameterFrame = try TandemFrame(
    dataType: TandemFrame.table1DataType,
    sequence: 0,
    payload: Data([0x57, 0x04, 0x00, 0x0A] + Array(repeating: 0x06, count: 10))
  )
  let parameters = try TandemReadOnlyEqualizer.parseParameterResponse(
    parameterFrame,
    capability: capability
  )
  #expect(parameters.presetIdentifier == 0)
  #expect(parameters.bandSteps == Array(repeating: 6, count: 10))

  let notificationFrame = try TandemFrame(
    dataType: TandemFrame.table1DataType,
    sequence: 1,
    payload: Data([0x59, 0x04, 0xA0, 0x0A] + Array(repeating: 6, count: 10))
  )
  let notification = try TandemReadOnlyEqualizer.parseParameterNotification(
    notificationFrame,
    capability: capability
  )
  #expect(notification.presetIdentifier == 0xA0)
  #expect(notification.bandSteps == Array(repeating: 6, count: 10))

  let presetNotificationFrame = try TandemFrame(
    dataType: TandemFrame.table1DataType,
    sequence: 0,
    payload: Data([0x59, 0x04, 0x00, 0x00])
  )
  let presetNotification = try TandemReadOnlyEqualizer.parseParameterNotification(
    presetNotificationFrame,
    capability: capability
  )
  #expect(presetNotification.presetIdentifier == 0x00)
  #expect(presetNotification.bandSteps.isEmpty)

  let extendedFrame = try TandemFrame(
    dataType: TandemFrame.table1DataType,
    sequence: 1,
    payload: Data([
      0x5B, 0x04, 0x0A,
      0x01, 0x00, 0x1F,
      0x01, 0x00, 0x3F,
      0x01, 0x00, 0x7D,
      0x01, 0x00, 0xFA,
      0x01, 0x01, 0xF4,
      0x01, 0x03, 0xE8,
      0x01, 0x07, 0xD0,
      0x01, 0x0F, 0xA0,
      0x01, 0x1F, 0x40,
      0x01, 0x3E, 0x80,
    ])
  )
  let bands = try TandemReadOnlyEqualizer.parseExtendedInfoResponse(
    extendedFrame,
    capability: capability
  )
  #expect(bands.map(\.value) == [31, 63, 125, 250, 500, 1_000, 2_000, 4_000, 8_000, 16_000])

  let snapshot = TandemEqualizerSnapshot(
    capability: capability,
    status: status,
    parameters: parameters,
    bands: bands
  )
  #expect(snapshot.presetName == "OFF")
  #expect(snapshot.gainValues == Array(repeating: 0, count: 10))
}

@Test func equalizerRejectsBandCountMismatch() throws {
  let capability = TandemEqualizerCapability(
    bandCount: 10,
    levelStepCount: 13,
    presets: []
  )
  let frame = try TandemFrame(
    dataType: TandemFrame.table1DataType,
    sequence: 0,
    payload: Data([0x57, 0x04, 0x00, 0x02, 0x06, 0x06])
  )
  #expect(throws: TandemEqualizerError.self) {
    _ = try TandemReadOnlyEqualizer.parseParameterResponse(frame, capability: capability)
  }
}

@Test func legacyParameterNotificationParsesWithItsOwnInquiry() throws {
  // The older generation notifies with its own inquiry byte just as it answers
  // with one; the notification parser has to accept that dialect too.
  let capability = TandemEqualizerCapability(bandCount: 6, levelStepCount: 21, presets: [])
  let notification = try TandemFrame(
    dataType: TandemFrame.table1DataType,
    sequence: 0,
    payload: Data([0x59, 0x01, 0xA1, 0x06, 10, 12, 10, 8, 10, 10])
  )
  let params = try TandemReadOnlyEqualizer.parseParameterNotification(
    notification,
    capability: capability,
    inquiry: TandemReadOnlyEqualizer.legacyInquiry
  )
  #expect(params.presetIdentifier == 0xA1)
  #expect(params.bandSteps == [10, 12, 10, 8, 10, 10])

  // The same frame keyed to the current inquiry is refused, so the dialects
  // cannot cross silently.
  #expect(throws: TandemEqualizerError.self) {
    _ = try TandemReadOnlyEqualizer.parseParameterNotification(
      notification,
      capability: capability
    )
  }
}

@Test func aSetOutsideTheDeclaredCapabilityNeverReachesTheWire() throws {
  let capability = TandemEqualizerCapability(bandCount: 10, levelStepCount: 13, presets: [])

  // A band count the device never declared.
  #expect(throws: TandemEqualizerError.bandCountMismatch(expected: 10, actual: 6)) {
    _ = try TandemReadOnlyEqualizer.setParameterRequest(
      sequence: 0,
      presetIdentifier: 0xA0,
      bandSteps: Array(repeating: 6, count: 6),
      capability: capability
    )
  }
  // A step past the declared range.
  #expect(throws: TandemEqualizerError.bandStepOutOfRange(step: 13, levelStepCount: 13)) {
    _ = try TandemReadOnlyEqualizer.setParameterRequest(
      sequence: 0,
      presetIdentifier: 0xA0,
      bandSteps: Array(repeating: 6, count: 9) + [13],
      capability: capability
    )
  }
  // A preset-only selection carries no bands and stays valid.
  let preset = try TandemReadOnlyEqualizer.setParameterRequest(
    sequence: 0,
    presetIdentifier: 0xA0,
    bandSteps: [],
    capability: capability
  )
  #expect([UInt8](preset.payload) == [0x58, 0x04, 0xA0, 0x00])
  // A conforming band write is unchanged by the validation.
  let bands = try TandemReadOnlyEqualizer.setParameterRequest(
    sequence: 0,
    presetIdentifier: 0xA0,
    bandSteps: Array(repeating: 6, count: 10),
    capability: capability
  )
  #expect([UInt8](bands.payload) == [0x58, 0x04, 0xA0, 0x0A] + Array(repeating: 6, count: 10))
}

@Test func gainValuesRequireAnOddStepCountToHaveANeutralMiddle() {
  // An even (or empty) step count has no exact neutral step; inventing one would
  // display wrong gains, so the conversion declines instead.
  let parameters = TandemEqualizerParameters(presetIdentifier: 0, bandSteps: [0, 6, 12])
  func snapshot(levelStepCount: Int) -> TandemEqualizerSnapshot {
    TandemEqualizerSnapshot(
      capability: TandemEqualizerCapability(
        bandCount: 3, levelStepCount: levelStepCount, presets: []
      ),
      status: TandemEqualizerStatus(isEnabled: true, errorCodes: []),
      parameters: parameters,
      bands: []
    )
  }
  #expect(snapshot(levelStepCount: 13).gainValues == [-6, 0, 6])
  #expect(snapshot(levelStepCount: 12).gainValues == nil)
  #expect(snapshot(levelStepCount: 0).gainValues == nil)
}

@Test func malformedCapabilityAnswersAreRefused() throws {
  func capabilityFrame(_ payload: [UInt8]) throws -> TandemFrame {
    try TandemFrame(
      dataType: TandemFrame.table1DataType,
      sequence: 0,
      payload: Data(payload)
    )
  }
  // A preset entry whose name runs past the payload.
  #expect(throws: TandemEqualizerError.invalidPresetEntry(5)) {
    _ = try TandemReadOnlyEqualizer.parseCapabilityResponse(
      try capabilityFrame([0x51, 0x04, 0x0A, 0x0D, 0x01, 0x00, 0x05, 0x41])
    )
  }
  // A declared preset count the entries do not add up to.
  #expect(throws: TandemEqualizerError.presetCountMismatch(expected: 2, actual: 1)) {
    _ = try TandemReadOnlyEqualizer.parseCapabilityResponse(
      try capabilityFrame([0x51, 0x04, 0x0A, 0x0D, 0x02, 0x00, 0x00])
    )
  }
  // A preset name that is not UTF-8.
  #expect(throws: TandemEqualizerError.invalidPresetName(0x10)) {
    _ = try TandemReadOnlyEqualizer.parseCapabilityResponse(
      try capabilityFrame([0x51, 0x04, 0x0A, 0x0D, 0x01, 0x10, 0x02, 0xFF, 0xFE])
    )
  }
}
