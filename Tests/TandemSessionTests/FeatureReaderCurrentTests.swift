import Foundation
import TandemCore
import Testing

@testable import TandemSession

// MARK: - Doubles

/// Answers the current-dialect conversations from a script keyed on the first two
/// payload bytes, and records which path — probe or request — each message took.
/// Everything unscripted is silence, thrown as a timeout the way a device that does
/// not implement the function behaves.
private final class CurrentDeviceRequester: SessionRequesting, @unchecked Sendable {
  private let lock = NSLock()
  private var probed: [[UInt8]] = []
  private var requested: [[UInt8]] = []
  private let script: [[UInt8]: [UInt8]]

  init(script: [[UInt8]: [UInt8]]) {
    self.script = script
  }

  var probedPayloads: [[UInt8]] { lock.withLock { probed } }
  var requestedPayloads: [[UInt8]] { lock.withLock { requested } }

  func request(
    _ build: @Sendable (UInt8) throws -> TandemFrame,
    matching: @Sendable @escaping (TandemFrame) -> Bool
  ) async throws -> TandemFrame {
    let payload = [UInt8](try build(0).payload)
    lock.withLock { requested.append(payload) }
    return try answer(payload)
  }

  func probe(
    _ build: @Sendable (UInt8) throws -> TandemFrame,
    matching: @Sendable @escaping (TandemFrame) -> Bool
  ) async throws -> TandemFrame {
    let payload = [UInt8](try build(0).payload)
    lock.withLock { probed.append(payload) }
    return try answer(payload)
  }

  private func answer(_ payload: [UInt8]) throws -> TandemFrame {
    guard let reply = script[Array(payload.prefix(2))] else {
      throw ChannelFailure.openTimedOut
    }
    return try TandemFrame(
      dataType: TandemFrame.table1DataType,
      sequence: 1,
      payload: Data(reply)
    )
  }
}

private func declared(_ codes: [UInt8]) -> [TandemSupportFunction] {
  codes.map { TandemSupportFunction(code: $0, version: 1) }
}

/// The conversations of a synthetic earbuds-style device: dual battery with
/// thresholds, a charging case, LDAC, a two-band equaliser, mode-select noise
/// control with adaptation, both listening features, and speak-to-chat. All values
/// are the test's own; nothing matches a real model.
private let fullScript: [[UInt8]: [UInt8]] = [
  [0x22, 0x09]: [0x23, 0x09, 0x50, 0x00, 0x46, 0x01, 0x0A, 0x0A],
  [0x22, 0x0A]: [0x23, 0x0A, 0x64, 0x00, 0x0A],
  [0x12, 0x02]: [0x13, 0x02, 0x10],
  // Equaliser: two bands, eleven steps, presets 0x00 and 0xA0 without names.
  [0x50, 0x04]: [0x51, 0x04, 2, 11, 2, 0x00, 0, 0xA0, 0],
  [0x56, 0x04]: [0x57, 0x04, 0xA0, 2, 5, 7],
  // Extended info labels the two bands 400 Hz and 1000 Hz.
  [0x5A, 0x04]: [0x5B, 0x04, 2, 0, 0x01, 0x90, 0, 0x03, 0xE8],
  // Noise control on the adaptation-capable inquiry: ambient (0) and voice focus
  // (1) modes, level 0...20 step 1.
  [0x60, 0x19]: [0x61, 0x19, 2, 0, 1, 20, 1, 1, 1, 20, 1],
  [0x66, 0x19]: [0x67, 0x19, 0x01, 0x01, 0x00, 0x00, 0x0A, 0x01, 0x02],
  // Listening: background music off in a middle room, cinema off.
  [0xE6, 0x09]: [0xE7, 0x09, 0x01, 0x01],
  [0xE6, 0x04]: [0xE7, 0x04, 0x01],
  // Speak-to-chat on inquiry 0x0C: preview supported, enabled, secondary off.
  [0xF0, 0x0C]: [0xF1, 0x0C, 1, 10, 20, 30],
  [0xF6, 0x0C]: [0xF7, 0x0C, 0x00, 0x01],
  [0xFA, 0x0C]: [0xFB, 0x0C, 0x01, 0x02],
]

private let fullDeclaration: [UInt8] = [0x29, 0x2A, 0x12, 0x57, 0x6D, 0xEB, 0xE5, 0xFC]

// MARK: - The current dialect

@Test func theCurrentDialectReadsEverythingTheDeviceDeclared() async throws {
  let requester = CurrentDeviceRequester(script: fullScript)
  let readings = await FeatureReader().read(
    declaring: declared(fullDeclaration),
    over: requester
  )

  #expect(readings.leftBattery == 80)
  #expect(readings.rightBattery == 70)
  #expect(readings.caseBattery == 100)
  #expect(readings.codec == .ldac)

  let equalizer = try #require(readings.equalizer)
  #expect(equalizer.selectedPreset == 0xA0)
  #expect(equalizer.bandSteps == [5, 7])
  #expect(equalizer.bandFrequencies == [400, 1000])
  #expect(equalizer.stepRange == 0...10)
  #expect(equalizer.flatStep == 5)
  #expect(equalizer.presets.map(\.identifier) == [0x00, 0xA0])

  let noise = try #require(readings.noiseControl)
  #expect(noise.inquiry == 0x19)
  #expect(noise.state.isActive)
  #expect(noise.state.isNoiseCancelling)
  #expect(noise.state.noiseAdaptation == .init(isOn: true, sensitivity: 2))
  #expect(noise.modes.map(\.mode) == [0, 1])
  #expect(noise.supportsVoiceFocus)
  #expect(noise.hasAdjustableLevel)
  // The write trim comes from the response the device itself gave.
  #expect(noise.valueFieldCount == 7)

  let listening = try #require(readings.listeningMode)
  #expect(listening.selection == .standard)
  #expect(listening.hasBackgroundMusic)
  #expect(listening.hasCinema)
  #expect(listening.savedRoom == .middle)

  let speakToChat = try #require(readings.speakToChat)
  #expect(speakToChat.inquiry == TandemSpeakToChatProtocol.inquiryType2)
  #expect(speakToChat.isEnabled)
  #expect(!speakToChat.secondarySettingEnabled)
  #expect(speakToChat.sensitivity == .high)
  #expect(speakToChat.timeout == .slow)
  #expect(speakToChat.capability.supportsPreview)
  #expect(speakToChat.capability.seconds(for: .medium) == 20)
}

@Test func theCurrentDialectAsksNothingOfADeviceThatDeclaredNothing() async {
  let requester = CurrentDeviceRequester(script: fullScript)
  let readings = await FeatureReader().read(declaring: [], over: requester)
  #expect(readings == DeviceReadings())
  #expect(requester.probedPayloads.isEmpty)
  #expect(requester.requestedPayloads.isEmpty)
}

// MARK: - Equaliser extended info

@Test func equalizerBandFrequenciesRideTheProbePath() async throws {
  // The extended query is optional by design: silence falls back to unlabelled
  // bands. It therefore has to be a probe — a request's timeout would tear down
  // the whole connection on the way to that fallback.
  let requester = CurrentDeviceRequester(script: fullScript)
  _ = await FeatureReader().read(declaring: declared([0x57]), over: requester)

  #expect(requester.probedPayloads.contains { $0.first == 0x5A })
  #expect(
    !requester.requestedPayloads.contains { $0.first == 0x5A },
    "the optional extended-info query went out as a faulting request"
  )
}

@Test func silenceOnTheExtendedInfoFallsBackToUnlabelledBands() async throws {
  // The device declares the equaliser but never answers the extended query. The
  // reading must still arrive, with zero frequencies standing in for the labels.
  var script = fullScript
  script[[0x5A, 0x04]] = nil
  let requester = CurrentDeviceRequester(script: script)
  let readings = await FeatureReader().read(declaring: declared([0x57]), over: requester)

  let equalizer = try #require(readings.equalizer)
  #expect(equalizer.bandFrequencies == [0, 0])
  #expect(equalizer.bandSteps == [5, 7])
}

// MARK: - Level quantisation

private func reading(range: ClosedRange<Int>, step: Int) -> NoiseControlReading {
  NoiseControlReading(
    inquiry: 0x19,
    modes: [
      TandemAmbientModeCapability(
        mode: 0,
        minimumLevel: range.lowerBound,
        maximumLevel: range.upperBound,
        step: step
      )
    ],
    state: TandemNoiseControlState(
      isActive: true, isNoiseCancelling: false, ambientMode: 0, ambientLevel: 0
    )
  )
}

@Test func quantizedLevelClampsToTheDeclaredRange() {
  let declared = reading(range: 1...20, step: 1)
  #expect(declared.quantizedLevel(-5, mode: 0) == 1)
  #expect(declared.quantizedLevel(0, mode: 0) == 1)
  #expect(declared.quantizedLevel(20, mode: 0) == 20)
  #expect(declared.quantizedLevel(99, mode: 0) == 20)
}

@Test func quantizedLevelAlignsToTheDeclaredStepFromTheMinimum() {
  // Steps count from the declared minimum, not from zero, so 3 with step 2 from
  // minimum 1 is already aligned and 4 rounds to the nearest step.
  let stepped = reading(range: 1...9, step: 2)
  #expect(stepped.quantizedLevel(3, mode: 0) == 3)
  #expect(stepped.quantizedLevel(4, mode: 0) == 5, "half a step rounds up")
  #expect(stepped.quantizedLevel(2, mode: 0) == 3)
  #expect(stepped.quantizedLevel(9, mode: 0) == 9)
}

@Test func quantizedLevelForAnUndeclaredModeCollapsesToZero() {
  // The mode was never declared, so its range is the empty 0...0: whatever the
  // caller asks for, nothing the device did not advertise may be sent.
  let declared = reading(range: 1...20, step: 1)
  #expect(declared.quantizedLevel(15, mode: 9) == 0)
}

// MARK: - Editable preset and band edits

private func equalizer(
  presets: [UInt8],
  selected: UInt8?,
  steps: [Int] = [5, 5],
  range: ClosedRange<Int> = 0...10
) -> EqualizerReading {
  EqualizerReading(
    presets: presets.map { EqualizerReading.Preset(identifier: $0, name: nil) },
    selectedPreset: selected,
    bandFrequencies: Array(repeating: 0, count: steps.count),
    bandSteps: steps,
    stepRange: range,
    flatStep: 5
  )
}

@Test func bandEditsLandOnTheDeclaredCustomPreset() {
  // A band edit is a custom-preset action: with a named preset selected it targets
  // the device's first custom slot, and with a custom slot already selected it
  // stays there.
  let onNamed = equalizer(presets: [0x00, 0xA0, 0xA1], selected: 0x00)
  #expect(onNamed.editablePresetIdentifier == 0xA0)
  #expect(onNamed.canEditBands)

  let onCustom = equalizer(presets: [0x00, 0xA0, 0xA1], selected: 0xA1)
  #expect(onCustom.editablePresetIdentifier == 0xA1, "an edit jumped to a different custom slot")
}

@Test func aDeviceWithoutACustomPresetCannotEditBands() {
  let fixed = equalizer(presets: [0x00, 0x10], selected: 0x00)
  #expect(fixed.editablePresetIdentifier == nil)
  #expect(!fixed.canEditBands)
}

@Test func settingBandMovesOneBandAndClampsToTheDeclaredRange() {
  let reading = equalizer(presets: [0xA0], selected: 0xA0, steps: [5, 5], range: 0...10)
  #expect(reading.settingBand(1, toStep: 7) == [5, 7])
  #expect(reading.settingBand(0, toStep: 99) == [10, 5], "a step beyond the range was sent")
  #expect(reading.settingBand(0, toStep: -3) == [0, 5])
  // An index the device never declared changes nothing.
  #expect(reading.settingBand(5, toStep: 7) == [5, 5])
}

@Test func decibelsAreReadAgainstTheFlatStep() {
  let reading = equalizer(presets: [0xA0], selected: 0xA0, steps: [5, 8], range: 0...10)
  #expect(reading.decibels(atBand: 0) == 0)
  #expect(reading.decibels(atBand: 1) == 3)
  #expect(reading.decibels(atBand: 9) == 0, "an undeclared band invented a level")
}
