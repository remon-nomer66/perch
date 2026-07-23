import Foundation
import TandemCore
import Testing

@testable import TandemSession

// MARK: - Doubles

/// A device double that answers the speak-to-chat and equaliser conversations from
/// its own state. `honoursSets` scripts whether a set request takes effect, which is
/// exactly what the read-back verification has to distinguish.
private actor ScriptedDevice: TandemChannel {
  private let inbound: AsyncStream<Data>.Continuation
  private var decoder = TandemStreamDecoder()
  private let honoursSets: Bool

  private var speakToChatEnabled = false
  private var sensitivity: UInt8 = 0
  private var timeout: UInt8 = 0

  private var selectedPreset: UInt8 = 0xA0
  private var bandSteps: [UInt8] = [5, 5]

  init(inbound: AsyncStream<Data>.Continuation, honoursSets: Bool) {
    self.inbound = inbound
    self.honoursSets = honoursSets
  }

  func write(_ data: Data) async throws {
    guard let frames = try? decoder.append(data) else { return }
    for frame in frames where frame.dataType == TandemFrame.table1DataType {
      let bytes = [UInt8](frame.payload)
      guard bytes.count >= 2 else { continue }
      let inquiry = bytes[1]
      switch bytes[0] {
      // Speak-to-chat: capability, parameter, extended parameter, and the two sets.
      case 0xF0:
        try reply([0xF1, inquiry, 0, 10, 20, 30])
      case 0xF6:
        try reply([0xF7, inquiry, speakToChatEnabled ? 0 : 1, 1])
      case 0xFA:
        try reply([0xFB, inquiry, sensitivity, timeout])
      case 0xF8:
        if honoursSets, bytes.count >= 4 { speakToChatEnabled = bytes[2] == 0 }
      case 0xFC:
        if honoursSets, bytes.count >= 4 {
          sensitivity = bytes[2]
          timeout = bytes[3]
        }

      // Equaliser: capability, parameter, extended info, and the set. The extended
      // info answer is deliberately truncated; the reader falls back to unlabelled
      // bands, which is all these tests need.
      case 0x50:
        try reply([0x51, inquiry, 2, 11, 2, 0x00, 0, 0xA0, 0])
      case 0x56:
        try reply([0x57, inquiry, selectedPreset, 2] + bandSteps)
      case 0x5A:
        try reply([0x5B, inquiry])
      case 0x58:
        guard honoursSets, bytes.count >= 4 else { break }
        selectedPreset = bytes[2]
        let count = Int(bytes[3])
        if count > 0, bytes.count >= 4 + count {
          bandSteps = Array(bytes[4..<4 + count])
        }

      default:
        break
      }
    }
  }

  func close() async {
    inbound.finish()
  }

  private func reply(_ payload: [UInt8]) throws {
    let frame = try TandemFrame(
      dataType: TandemFrame.table1DataType,
      sequence: 0,
      payload: Data(payload)
    )
    inbound.yield(frame.encoded())
  }
}

private struct ScriptedOpener: TandemChannelOpening {
  let make: @Sendable () async throws -> OpenedChannel

  func open(_ device: DeviceIdentity) async throws -> OpenedChannel {
    try await make()
  }
}

private struct StubVerifier: DeviceVerifying {
  let outcome: VerificationOutcome

  func verify(over requests: SessionRequesting) async throws -> VerificationOutcome {
    outcome
  }
}

// MARK: - Helpers

/// Entirely synthetic: no field matches a real device, and the verifier stub never
/// validates it, so nothing model-specific is being baked in.
private func syntheticFingerprint(declaring codes: [UInt8]) -> TandemDeviceFingerprint {
  TandemDeviceFingerprint(
    protocolIdentifier: 0x0102_0304,
    protocolFirstFlag: 0,
    protocolSecondFlag: 0,
    capabilityCode: 6,
    capabilityIdentifierLength: 17,
    modelName: "TEST-DEVICE",
    firmwareVersion: "1.0.0",
    table1Functions: codes.map { TandemSupportFunction(code: $0, version: 1) },
    table2Functions: [],
    dialect: .current
  )
}

private func makeCoordinator(
  outcome: @Sendable (TandemDeviceFingerprint) -> VerificationOutcome,
  declaring codes: [UInt8],
  honoursSets: Bool
) -> (SessionCoordinator, ScriptedDevice) {
  let (stream, continuation) = AsyncStream<Data>.makeStream()
  let channel = ScriptedDevice(inbound: continuation, honoursSets: honoursSets)
  let opener = ScriptedOpener { [channel] in
    OpenedChannel(channel: channel, inbound: stream, maximumTransmissionUnit: 512)
  }
  let coordinator = SessionCoordinator(
    opener: opener,
    verifier: StubVerifier(outcome: outcome(syntheticFingerprint(declaring: codes))),
    timeouts: SessionCoordinator.Timeouts(
      response: .seconds(60),
      backoffUnit: .seconds(60)
    )
  )
  return (coordinator, channel)
}

private func makeVerifiedCoordinator(
  declaring codes: [UInt8],
  honoursSets: Bool
) throws -> (SessionCoordinator, ScriptedDevice) {
  let profile = try #require(TandemVerifiedDeviceRegistry.profiles.first)
  return makeCoordinator(
    outcome: { .verified(profile, $0) },
    declaring: codes,
    honoursSets: honoursSets
  )
}

private func eventually(
  within timeout: Duration = .seconds(10),
  _ condition: @Sendable () async -> Bool
) async -> Bool {
  let deadline = ContinuousClock.now.advanced(by: timeout)
  while ContinuousClock.now < deadline {
    if await condition() { return true }
    try? await Task.sleep(for: .milliseconds(10))
  }
  return await condition()
}

// MARK: - Speak-to-chat read-back

@Test func aSpeakToChatWriteTheDeviceIgnoresIsReportedNotSwallowed() async throws {
  let (coordinator, _) = try makeVerifiedCoordinator(
    declaring: [TandemSpeakToChatProtocol.functionCodeType2],
    honoursSets: false
  )
  await coordinator.handle(.defaultOutputChanged(DeviceIdentity("test-target")))
  #expect(await eventually { await coordinator.readings.speakToChat != nil })

  do {
    try await coordinator.apply(speakToChatEnabled: true)
    Issue.record("a write the device ignored was reported as success")
  } catch let failure as SessionCoordinator.WriteFailure {
    guard case .notAppliedSpeakToChat(let held) = failure else {
      Issue.record("unexpected failure \(failure)")
      return
    }
    // The failure carries what the device actually holds.
    #expect(!held.isEnabled)
  }
  await coordinator.handle(.manualRelease)
}

@Test func aSpeakToChatDetailTheDeviceIgnoresIsReported() async throws {
  let (coordinator, _) = try makeVerifiedCoordinator(
    declaring: [TandemSpeakToChatProtocol.functionCodeType2],
    honoursSets: false
  )
  await coordinator.handle(.defaultOutputChanged(DeviceIdentity("test-target")))
  #expect(await eventually { await coordinator.readings.speakToChat != nil })

  await #expect(throws: SessionCoordinator.WriteFailure.self) {
    try await coordinator.apply(speakToChatSensitivity: .high, timeout: .slow)
  }
  await coordinator.handle(.manualRelease)
}

@Test func aSpeakToChatWriteTheDeviceHonoursSucceedsAndUpdatesTheReadings() async throws {
  let (coordinator, _) = try makeVerifiedCoordinator(
    declaring: [TandemSpeakToChatProtocol.functionCodeType2],
    honoursSets: true
  )
  await coordinator.handle(.defaultOutputChanged(DeviceIdentity("test-target")))
  #expect(await eventually { await coordinator.readings.speakToChat != nil })

  try await coordinator.apply(speakToChatEnabled: true)
  #expect(await coordinator.readings.speakToChat?.isEnabled == true)

  try await coordinator.apply(speakToChatSensitivity: .high, timeout: .slow)
  #expect(await coordinator.readings.speakToChat?.sensitivity == .high)
  #expect(await coordinator.readings.speakToChat?.timeout == .slow)
  await coordinator.handle(.manualRelease)
}

// MARK: - Equaliser read-back

@Test func anEqualizerPresetTheDeviceIgnoresIsReported() async throws {
  let (coordinator, _) = try makeVerifiedCoordinator(declaring: [0x57], honoursSets: false)
  await coordinator.handle(.defaultOutputChanged(DeviceIdentity("test-target")))
  #expect(await eventually { await coordinator.readings.equalizer != nil })

  do {
    try await coordinator.apply(equalizerPreset: 0x00, bandSteps: [])
    Issue.record("a preset the device ignored was reported as selected")
  } catch let failure as SessionCoordinator.WriteFailure {
    guard case .notAppliedEqualizer(let held, _) = failure else {
      Issue.record("unexpected failure \(failure)")
      return
    }
    #expect(held == 0xA0, "the failure does not carry what the device holds")
  }
  await coordinator.handle(.manualRelease)
}

@Test func anEqualizerWriteTheDeviceHonoursSucceedsAndUpdatesTheReadings() async throws {
  let (coordinator, _) = try makeVerifiedCoordinator(declaring: [0x57], honoursSets: true)
  await coordinator.handle(.defaultOutputChanged(DeviceIdentity("test-target")))
  #expect(await eventually { await coordinator.readings.equalizer != nil })

  try await coordinator.apply(equalizerPreset: 0xA0, bandSteps: [7, 3])
  #expect(await coordinator.readings.equalizer?.bandSteps == [7, 3])

  try await coordinator.apply(equalizerPreset: 0x00, bandSteps: [])
  #expect(await coordinator.readings.equalizer?.selectedPreset == 0x00)
  await coordinator.handle(.manualRelease)
}

// MARK: - The write gate for devices that failed verification

@Test func aStructurallyRefusedDeviceKeepsItsReadsButNeverWrites() async throws {
  // The verifier explicitly refused the device: the shape it reported does not
  // match anything verified. Reads must continue; writes must never open.
  let (coordinator, _) = makeCoordinator(
    outcome: { .unsupported($0, reason: .functionCountMismatch(table: 1, expected: 2, actual: 1)) },
    declaring: [TandemSpeakToChatProtocol.functionCodeType2],
    honoursSets: true
  )
  await coordinator.handle(.defaultOutputChanged(DeviceIdentity("test-target")))
  #expect(await eventually { await coordinator.phase == .unverified })

  // Reads keep flowing for the refused device.
  #expect(await eventually { await coordinator.readings.speakToChat != nil })

  #expect(await coordinator.acceptsWrites == false)
  await #expect(throws: SessionCoordinator.WriteFailure.notPermitted) {
    try await coordinator.apply(speakToChatEnabled: true)
  }
  await coordinator.handle(.manualRelease)
}

@Test func anUnknownModelTheGateRecognizesKeepsCaveatedWrites() async throws {
  // The conversation shape comes from a registry profile — the test must not
  // invent one — under a model name the registry has never seen.
  let reference = try #require(TandemVerifiedDeviceRegistry.profiles.first)
  let controllable = try #require(
    TandemVerifiedDeviceRegistry.experimentallyControllableTable1Codes.sorted().first
  )
  let unknownDevice = TandemDeviceFingerprint(
    protocolIdentifier: reference.protocolIdentifier,
    protocolFirstFlag: reference.protocolFirstFlag,
    protocolSecondFlag: reference.protocolSecondFlag,
    capabilityCode: reference.capabilityCode,
    capabilityIdentifierLength: reference.capabilityIdentifierLength,
    modelName: "TEST-DEVICE",
    firmwareVersion: "1.0.0",
    table1Functions: [TandemSupportFunction(code: controllable, version: 1)],
    table2Functions: [],
    dialect: .current
  )

  let (stream, continuation) = AsyncStream<Data>.makeStream()
  let channel = ScriptedDevice(inbound: continuation, honoursSets: true)
  let opener = ScriptedOpener { [channel] in
    OpenedChannel(channel: channel, inbound: stream, maximumTransmissionUnit: 512)
  }
  let coordinator = SessionCoordinator(
    opener: opener,
    verifier: StubVerifier(
      outcome: .unsupported(unknownDevice, reason: .unverifiedModel("TEST-DEVICE"))
    ),
    timeouts: SessionCoordinator.Timeouts(response: .seconds(60), backoffUnit: .seconds(60))
  )
  await coordinator.handle(.defaultOutputChanged(DeviceIdentity("test-target")))
  #expect(await eventually { await coordinator.phase == .unverified })
  #expect(await coordinator.acceptsWrites, "the experimental caveat path was closed")
  await coordinator.handle(.manualRelease)
}
