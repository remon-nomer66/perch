import Foundation
import TandemCore
import Testing

@testable import TandemSession

// MARK: - Doubles

/// Records every table-1 frame the coordinator writes and lets the test answer by
/// hand, so the order of writes and the attribution of answers can be asserted.
private actor RecordingChannel: TandemChannel {
  private let inbound: AsyncStream<Data>.Continuation
  private var decoder = TandemStreamDecoder()
  private var payloads: [[UInt8]] = []

  init(inbound: AsyncStream<Data>.Continuation) {
    self.inbound = inbound
  }

  func write(_ data: Data) async throws {
    guard let frames = try? decoder.append(data) else { return }
    for frame in frames where frame.dataType == TandemFrame.table1DataType {
      payloads.append([UInt8](frame.payload))
    }
  }

  func close() async {
    inbound.finish()
  }

  func writes(withPrefix prefix: [UInt8]) -> Int {
    payloads.filter { Array($0.prefix(prefix.count)) == prefix }.count
  }

  func reply(_ payload: [UInt8]) throws {
    let frame = try TandemFrame(
      dataType: TandemFrame.table1DataType,
      sequence: 0,
      payload: Data(payload)
    )
    inbound.yield(frame.encoded())
  }

  func acknowledge() throws {
    let frame = try TandemFrame.acknowledgement(for: 0)
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

/// A ready coordinator whose device declared nothing, so the readings poll issues no
/// requests and every write on the channel belongs to the test.
private func makeReadyCoordinator() async throws -> (SessionCoordinator, RecordingChannel) {
  let (stream, continuation) = AsyncStream<Data>.makeStream()
  let channel = RecordingChannel(inbound: continuation)
  let opener = ScriptedOpener { [channel] in
    OpenedChannel(channel: channel, inbound: stream, maximumTransmissionUnit: 512)
  }
  let profile = try #require(TandemVerifiedDeviceRegistry.profiles.first)
  let coordinator = SessionCoordinator(
    opener: opener,
    verifier: StubVerifier(outcome: .verified(profile, fingerprint(declaring: []))),
    // Long enough that neither a response timeout nor a reconnect can fire during
    // the test; the interleavings under test are driven entirely by the frames.
    timeouts: SessionCoordinator.Timeouts(
      response: .seconds(60),
      backoffUnit: .seconds(60)
    )
  )
  await coordinator.handle(.defaultOutputChanged(DeviceIdentity("test-target")))
  #expect(await eventually { await coordinator.phase == .ready })
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

/// Synthetic request/answer bytes: the channel is a double, so no device vocabulary
/// is involved. The marker distinguishes the two requests on the wire and in the
/// answers.
private func requestFrame(_ marker: UInt8) -> @Sendable (UInt8) throws -> TandemFrame {
  { sequence in
    try TandemFrame(
      dataType: TandemFrame.table1DataType,
      sequence: sequence,
      payload: Data([0x0A, marker])
    )
  }
}

/// Deliberately accepts every answer, whichever request it was meant for: attribution
/// must come from the serialization, not from the matcher happening to disambiguate.
private let answersAnyReply: @Sendable (TandemFrame) -> Bool = { frame in
  [UInt8](frame.payload).first == 0x0B
}

// MARK: - Tests

@Test func requestsAreSerializedAndAnswersBelongToTheOneInFlight() async throws {
  let (coordinator, channel) = try await makeReadyCoordinator()

  let first = Task { try await coordinator.send(requestFrame(0x01), matching: answersAnyReply) }
  #expect(await eventually { await channel.writes(withPrefix: [0x0A, 0x01]) == 1 })

  let second = Task { try await coordinator.send(requestFrame(0x02), matching: answersAnyReply) }
  // Give the second request room to run: it must queue, never reach the wire.
  try await Task.sleep(for: .milliseconds(150))
  #expect(
    await channel.writes(withPrefix: [0x0A]) == 1,
    "a second request was written while one was in flight"
  )

  // Both matchers accept this answer; only the request in flight may take it.
  try await channel.reply([0x0B, 0x01])
  let firstAnswer = try await first.value
  #expect([UInt8](firstAnswer.payload) == [0x0B, 0x01])

  // The wire passes to the queued request only now.
  #expect(await eventually { await channel.writes(withPrefix: [0x0A, 0x02]) == 1 })
  try await channel.reply([0x0B, 0x02])
  let secondAnswer = try await second.value
  #expect([UInt8](secondAnswer.payload) == [0x0B, 0x02])

  await coordinator.handle(.manualRelease)
}

@Test func anAcknowledgementBelongsToTheRequestInFlight() async throws {
  let (coordinator, channel) = try await makeReadyCoordinator()

  let first = Task { try await coordinator.send(requestFrame(0x01), matching: answersAnyReply) }
  #expect(await eventually { await channel.writes(withPrefix: [0x0A, 0x01]) == 1 })
  let second = Task { try await coordinator.send(requestFrame(0x02), matching: answersAnyReply) }
  try await Task.sleep(for: .milliseconds(150))

  try await channel.acknowledge()
  #expect(
    await eventually { await coordinator.inFlightAcknowledged == true },
    "the acknowledgement did not reach the request in flight"
  )

  try await channel.reply([0x0B, 0x01])
  _ = try await first.value

  // The queued request becomes the new in-flight without inheriting the mark.
  #expect(await eventually { await channel.writes(withPrefix: [0x0A, 0x02]) == 1 })
  #expect(await coordinator.inFlightAcknowledged == false)

  try await channel.reply([0x0B, 0x02])
  _ = try await second.value
  await coordinator.handle(.manualRelease)
}

@Test func teardownFailsTheRequestInFlightAndTheQueuedOnes() async throws {
  let (coordinator, channel) = try await makeReadyCoordinator()

  let first = Task { try await coordinator.send(requestFrame(0x01), matching: answersAnyReply) }
  #expect(await eventually { await channel.writes(withPrefix: [0x0A, 0x01]) == 1 })
  let second = Task { try await coordinator.send(requestFrame(0x02), matching: answersAnyReply) }
  try await Task.sleep(for: .milliseconds(150))

  await coordinator.handle(.bluetoothDisconnected)
  #expect(await coordinator.phase == .released)

  do {
    _ = try await first.value
    Issue.record("the request in flight survived the teardown")
  } catch let failure as SessionRequestFailure {
    #expect(failure == .failed(.sessionInvalidated))
  }
  do {
    _ = try await second.value
    Issue.record("a queued request survived the teardown")
  } catch let failure as SessionRequestFailure {
    // The queued request was admitted against the old session, so the epoch
    // re-check on its turn must fail it rather than write into a successor.
    #expect(failure == .failed(.sessionInvalidated))
  }
  #expect(
    await channel.writes(withPrefix: [0x0A, 0x02]) == 0,
    "a request admitted against the dead session reached the wire"
  )
}
