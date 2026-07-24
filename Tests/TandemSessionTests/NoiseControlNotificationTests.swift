import Foundation
import TandemCore
import Testing

@testable import TandemSession

// A device double that answers the noise-control reads and lets a test push an
// unsolicited change the way a headset does when its touch panel is used. Nothing here
// is model-specific: inquiry 0x19 is the protocol's mode-select type, and the verifier
// is stubbed, so no real device is being imitated.
private actor NoiseControlDevice: TandemChannel {
  private let inbound: AsyncStream<Data>.Continuation
  private var decoder = TandemStreamDecoder()
  private let inquiry: UInt8

  /// The seven value bytes past command and inquiry: changeStatus, effectOn, mode
  /// (0 = noise cancelling, 1 = ambient), ambientMode, level, adaptationOn, sensitivity.
  /// Starts on noise cancelling so a switch to ambient is a visible change.
  private var value: [UInt8] = [0x01, 0x01, 0x00, 0x00, 0x0A, 0x00, 0x00]

  init(inbound: AsyncStream<Data>.Continuation, inquiry: UInt8) {
    self.inbound = inbound
    self.inquiry = inquiry
  }

  func write(_ data: Data) async throws {
    guard let frames = try? decoder.append(data) else { return }
    for frame in frames where frame.dataType == TandemFrame.table1DataType {
      let bytes = [UInt8](frame.payload)
      guard bytes.count >= 2 else { continue }
      switch bytes[0] {
      case 0x60:  // capability: two ambient modes, level range 1...20
        try reply([0x61, bytes[1], 0x02, 0x00, 0x01, 0x14, 0x01, 0x01, 0x01, 0x14, 0x01])
      case 0x66:  // parameter
        try reply([0x67, bytes[1]] + value)
      default:
        break
      }
    }
  }

  func close() async { inbound.finish() }

  /// Pushes an unsolicited change, as a headset does when the wearer taps to switch
  /// noise control. `command` is the return (0x67) or notify (0x69) the device uses.
  /// The stored value is updated too, so a later poll agrees with the notification.
  func announce(command: UInt8, value newValue: [UInt8]) throws {
    value = newValue
    try reply([command, inquiry] + newValue)
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

private struct NCOpener: TandemChannelOpening {
  let make: @Sendable () async throws -> OpenedChannel
  func open(_ device: DeviceIdentity) async throws -> OpenedChannel { try await make() }
}

private struct NCStubVerifier: DeviceVerifying {
  let outcome: VerificationOutcome
  func verify(over requests: SessionRequesting) async throws -> VerificationOutcome { outcome }
}

private func makeNoiseControlCoordinator() throws -> (SessionCoordinator, NoiseControlDevice) {
  // 0x6D is the mode-select-with-adaptation function; it resolves to inquiry 0x19.
  let inquiry = try #require(TandemNoiseControlType.inquiry(forDeclared: [0x6D]))
  let profile = try #require(TandemVerifiedDeviceRegistry.profiles.first)
  let fingerprint = TandemDeviceFingerprint(
    protocolIdentifier: 0x0102_0304,
    protocolFirstFlag: 0,
    protocolSecondFlag: 0,
    capabilityCode: 6,
    capabilityIdentifierLength: 17,
    modelName: "TEST-DEVICE",
    firmwareVersion: "1.0.0",
    table1Functions: [TandemSupportFunction(code: 0x6D, version: 1)],
    table2Functions: [],
    dialect: .current
  )
  let (stream, continuation) = AsyncStream<Data>.makeStream()
  let device = NoiseControlDevice(inbound: continuation, inquiry: inquiry)
  let opener = NCOpener { [device] in
    OpenedChannel(channel: device, inbound: stream, maximumTransmissionUnit: 512)
  }
  let coordinator = SessionCoordinator(
    opener: opener,
    verifier: NCStubVerifier(outcome: .verified(profile, fingerprint)),
    timeouts: SessionCoordinator.Timeouts(response: .seconds(60), backoffUnit: .seconds(60))
  )
  return (coordinator, device)
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

@Test func aNoiseControlNotifyIsReflectedWithoutWaitingForThePoll() async throws {
  let (coordinator, device) = try makeNoiseControlCoordinator()
  await coordinator.handle(.defaultOutputChanged(DeviceIdentity("test-target")))

  // The first read populates the reading on noise cancelling.
  #expect(await eventually { await coordinator.readings.noiseControl?.state.isNoiseCancelling == true })

  // The wearer taps to switch to ambient sound: the headset announces it with a notify
  // (0x69), unprompted. Value: active, ambient (mode 1), ambient mode 1, level 20.
  try await device.announce(command: 0x69, value: [0x01, 0x01, 0x01, 0x01, 0x14, 0x00, 0x00])

  // It shows at once — long before the ~20s poll would have caught it.
  #expect(
    await eventually {
      let state = await coordinator.readings.noiseControl?.state
      return state?.isNoiseCancelling == false && state?.ambientLevel == 20
    }
  )
  await coordinator.handle(.manualRelease)
}

@Test func aNoiseControlReturnFrameIsAlsoReflected() async throws {
  let (coordinator, device) = try makeNoiseControlCoordinator()
  await coordinator.handle(.defaultOutputChanged(DeviceIdentity("test-target")))
  #expect(await eventually { await coordinator.readings.noiseControl?.state.isNoiseCancelling == true })

  // Some firmware announces the change with the return command (0x67) instead.
  try await device.announce(command: 0x67, value: [0x01, 0x01, 0x01, 0x00, 0x0F, 0x00, 0x00])

  #expect(
    await eventually {
      let state = await coordinator.readings.noiseControl?.state
      return state?.isNoiseCancelling == false && state?.ambientLevel == 15
    }
  )
  await coordinator.handle(.manualRelease)
}

@Test func anUnrelatedNotificationLeavesTheReadingAlone() async throws {
  let (coordinator, device) = try makeNoiseControlCoordinator()
  await coordinator.handle(.defaultOutputChanged(DeviceIdentity("test-target")))
  #expect(await eventually { await coordinator.readings.noiseControl?.state.isNoiseCancelling == true })

  // A gesture action-log frame (0xC9) is not a noise-control parameter: it must not be
  // mistaken for one and must leave the reading untouched.
  try await device.announce(command: 0xC9, value: [0x01, 0x6F, 0x70, 0x50, 0x6C, 0x61, 0x79])
  try? await Task.sleep(for: .milliseconds(100))
  #expect(await coordinator.readings.noiseControl?.state.isNoiseCancelling == true)
  await coordinator.handle(.manualRelease)
}
