import Foundation
import TandemCore
import Testing

@testable import TandemSession

// MARK: - Doubles

/// A channel the test answers by hand. A single-battery request gets its reply so a
/// read can make progress; a codec request is left unanswered so the read can be
/// caught mid-flight; everything else is recorded and ignored.
private actor ScriptedChannel: TandemChannel {
  private let inbound: AsyncStream<Data>.Continuation
  private var decoder = TandemStreamDecoder()
  private var requestPrefixes: [[UInt8]] = []

  init(inbound: AsyncStream<Data>.Continuation) {
    self.inbound = inbound
  }

  func write(_ data: Data) async throws {
    guard let frames = try? decoder.append(data) else { return }
    for frame in frames where frame.dataType == TandemFrame.table1DataType {
      let bytes = [UInt8](frame.payload)
      guard bytes.count >= 2 else { continue }
      requestPrefixes.append(Array(bytes.prefix(2)))
      if bytes[0] == 0x22, bytes[1] == TandemBatteryQuery.single.rawValue {
        let reply = try TandemFrame(
          dataType: TandemFrame.table1DataType,
          sequence: frame.sequence,
          payload: Data([0x23, TandemBatteryQuery.single.rawValue, 50, 0])
        )
        inbound.yield(reply.encoded())
      }
    }
  }

  func close() async {
    inbound.finish()
  }

  func sawRequest(_ prefix: [UInt8]) -> Bool {
    requestPrefixes.contains(prefix)
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
private func fingerprint(declaring codes: [UInt8]) -> TandemDeviceFingerprint {
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
  declaring codes: [UInt8]
) throws -> (SessionCoordinator, ScriptedChannel) {
  let (stream, continuation) = AsyncStream<Data>.makeStream()
  let channel = ScriptedChannel(inbound: continuation)
  let opener = ScriptedOpener { [channel] in
    OpenedChannel(channel: channel, inbound: stream, maximumTransmissionUnit: 512)
  }
  let profile = try #require(TandemVerifiedDeviceRegistry.profiles.first)
  let coordinator = SessionCoordinator(
    opener: opener,
    verifier: StubVerifier(outcome: .verified(profile, fingerprint(declaring: codes))),
    // Long enough that neither a response timeout nor a reconnect can fire during
    // the test; the interleavings under test are driven entirely by events.
    timeouts: SessionCoordinator.Timeouts(
      response: .seconds(60),
      backoffUnit: .seconds(60)
    )
  )
  return (coordinator, channel)
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

private let batteryRequestPrefix: [UInt8] = [0x22, TandemBatteryQuery.single.rawValue]
private let codecRequestPrefix: [UInt8] = [0x12, 0x02]

// MARK: - Tests

@Test func aCompletedReadIsStoredForTheSessionItWasStartedFor() async throws {
  // Declaring only the battery lets the first read cycle finish, so the store path
  // for a live session stays covered while the stale-read guard exists.
  let (coordinator, _) = try makeCoordinator(declaring: [0x20])

  await coordinator.handle(.defaultOutputChanged(DeviceIdentity("test-target")))
  #expect(
    await eventually { await coordinator.readings.singleBattery == 50 },
    "a read finished within the session never reached the readings"
  )

  await coordinator.handle(.manualRelease)
}

@Test func aReadOutlivingItsSessionDoesNotResurrectTheOldReadings() async throws {
  // The codec function is declared but its request is never answered, so the read
  // cycle is parked mid-flight with the battery value already in hand. The
  // disconnect then invalidates the session *before* the pending request is failed,
  // which is the exact ordering under test: the read resumes only after the epoch
  // has moved on, returns its partial result, and that result must be discarded —
  // storing it put the old device's values (and its write-guard parameters) back
  // after the session was gone.
  let (coordinator, channel) = try makeCoordinator(declaring: [0x20, 0x12])

  await coordinator.handle(.defaultOutputChanged(DeviceIdentity("test-target")))
  #expect(
    await eventually { await channel.sawRequest(codecRequestPrefix) },
    "the read never reached the unanswered codec request"
  )
  #expect(await channel.sawRequest(batteryRequestPrefix))

  await coordinator.handle(.bluetoothDisconnected)
  #expect(await coordinator.phase == .released)
  #expect(await coordinator.readings == DeviceReadings())

  // The interrupted read finishes shortly after `failPendingRequests` releases it.
  // Give it room to run its store, then confirm nothing came back.
  try await Task.sleep(for: .milliseconds(300))
  #expect(
    await coordinator.readings == DeviceReadings(),
    "a read from the closed session was stored after invalidation"
  )
}
