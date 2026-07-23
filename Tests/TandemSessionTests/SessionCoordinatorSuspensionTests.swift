import Foundation
import TandemCore
import Testing

@testable import TandemSession

// MARK: - Doubles

/// Answers the single-battery query and counts every table-1 request, so the tests
/// can see exactly when the readings poll is talking and when it has stopped.
private actor CountingChannel: TandemChannel {
  private let inbound: AsyncStream<Data>.Continuation
  private var decoder = TandemStreamDecoder()
  private var prefixes: [[UInt8]] = []

  init(inbound: AsyncStream<Data>.Continuation) {
    self.inbound = inbound
  }

  func write(_ data: Data) async throws {
    guard let frames = try? decoder.append(data) else { return }
    for frame in frames where frame.dataType == TandemFrame.table1DataType {
      let bytes = [UInt8](frame.payload)
      guard bytes.count >= 2 else { continue }
      prefixes.append(Array(bytes.prefix(2)))
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

  func requests(withPrefix prefix: [UInt8]) -> Int {
    prefixes.filter { $0 == prefix }.count
  }

  func inject(_ payload: [UInt8]) throws {
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

/// Times out the first `timeouts` opens the way a contended device does — the open
/// hangs until the caller's deadline — and succeeds afterwards.
private final class ContendedThenFreeOpener: TandemChannelOpening, @unchecked Sendable {
  private let lock = NSLock()
  private var remainingTimeouts: Int
  private let make: @Sendable () async throws -> OpenedChannel

  init(timeouts: Int, make: @Sendable @escaping () async throws -> OpenedChannel) {
    remainingTimeouts = timeouts
    self.make = make
  }

  func open(_ device: DeviceIdentity) async throws -> OpenedChannel {
    let timesOut = lock.withLock { () -> Bool in
      guard remainingTimeouts > 0 else { return false }
      remainingTimeouts -= 1
      return true
    }
    guard !timesOut else { throw ChannelFailure.openTimedOut }
    return try await make()
  }
}

private struct StubVerifier: DeviceVerifying {
  let outcome: VerificationOutcome

  func verify(over requests: SessionRequesting) async throws -> VerificationOutcome {
    outcome
  }
}

/// Completes only when the test says so, standing in for a verifier that does not
/// notice it was cancelled and finishes long after the session moved on.
private final class GatedVerifier: DeviceVerifying, @unchecked Sendable {
  private let outcome: VerificationOutcome
  private let gate: AsyncStream<Void>
  private let opening: AsyncStream<Void>.Continuation

  init(outcome: VerificationOutcome) {
    self.outcome = outcome
    (gate, opening) = AsyncStream<Void>.makeStream()
  }

  func release() {
    opening.yield()
  }

  func verify(over requests: SessionRequesting) async throws -> VerificationOutcome {
    for await _ in gate { break }
    return outcome
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

private func quickPollTimeouts() -> SessionCoordinator.Timeouts {
  // Long enough that neither a response timeout nor a reconnect can fire during
  // the test; the poll cadence alone is compressed so its stopping and restarting
  // is observable.
  var timeouts = SessionCoordinator.Timeouts(
    response: .seconds(60),
    backoffUnit: .seconds(60)
  )
  timeouts.readingIntervalOverride = .milliseconds(50)
  return timeouts
}

private func makeCoordinator(
  declaring codes: [UInt8],
  verifier: (any DeviceVerifying)? = nil,
  opener openerOverride: (any TandemChannelOpening)? = nil
) throws -> (SessionCoordinator, CountingChannel) {
  let (stream, continuation) = AsyncStream<Data>.makeStream()
  let channel = CountingChannel(inbound: continuation)
  let opener = ScriptedOpener { [channel] in
    OpenedChannel(channel: channel, inbound: stream, maximumTransmissionUnit: 512)
  }
  let profile = try #require(TandemVerifiedDeviceRegistry.profiles.first)
  let coordinator = SessionCoordinator(
    opener: openerOverride ?? opener,
    verifier: verifier
      ?? StubVerifier(outcome: .verified(profile, fingerprint(declaring: codes))),
    timeouts: quickPollTimeouts()
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

private let target = DeviceIdentity("test-target")
private let batteryPrefix: [UInt8] = [0x22, TandemBatteryQuery.single.rawValue]

// MARK: - The suspended grace

@Test func suspendingPausesThePollAndResumingRestartsIt() async throws {
  let (coordinator, channel) = try makeCoordinator(declaring: [0x20])
  await coordinator.handle(.defaultOutputChanged(target))
  // The poll is demonstrably cycling before the suspension.
  #expect(await eventually { await channel.requests(withPrefix: batteryPrefix) >= 2 })

  await coordinator.handle(.defaultOutputChanged(nil))
  #expect(await coordinator.phase == .suspended(resume: .ready))
  // Let any cycle in flight drain, then measure over several would-be intervals.
  try await Task.sleep(for: .milliseconds(100))
  let during = await channel.requests(withPrefix: batteryPrefix)
  try await Task.sleep(for: .milliseconds(300))
  #expect(
    await channel.requests(withPrefix: batteryPrefix) == during,
    "the readings poll kept talking through the suspended grace"
  )

  // The readings survive the pause: the channel was held, nothing invalidated.
  #expect(await coordinator.readings.singleBattery == 50)

  await coordinator.handle(.defaultOutputChanged(target))
  #expect(await coordinator.phase == .ready)
  #expect(
    await eventually { await channel.requests(withPrefix: batteryPrefix) > during },
    "the poll never resumed after the device became the output again"
  )
  await coordinator.handle(.manualRelease)
}

@Test func writesDuringTheSuspendedGraceAreRefusedTyped() async throws {
  let (coordinator, _) = try makeCoordinator(declaring: [])
  await coordinator.handle(.defaultOutputChanged(target))
  #expect(await eventually { await coordinator.phase == .ready })
  await coordinator.handle(.defaultOutputChanged(nil))
  #expect(await coordinator.phase == .suspended(resume: .ready))

  // The public write path refuses with its typed error before anything is sent.
  #expect(await coordinator.acceptsWrites == false)
  await #expect(throws: SessionCoordinator.WriteFailure.notPermitted) {
    try await coordinator.apply(speakToChatEnabled: true)
  }

  // The raw request path refuses too, so nothing else can talk into the grace.
  do {
    _ = try await coordinator.send(
      { try TandemFrame(dataType: TandemFrame.table1DataType, sequence: $0, payload: Data([0x0A])) },
      matching: { _ in true }
    )
    Issue.record("a request was admitted during the suspended grace")
  } catch let failure as SessionRequestFailure {
    #expect(failure == .notReady)
  }
  await coordinator.handle(.manualRelease)
}

// MARK: - Gesture log lifetime

@Test func invalidationClearsTheGestureLog() async throws {
  let (coordinator, channel) = try makeCoordinator(declaring: [])
  await coordinator.handle(.defaultOutputChanged(target))
  #expect(await eventually { await coordinator.phase == .ready })

  // A touch gesture announced by the device lands in the log.
  try await channel.inject([0xC9, 0x01, 0x00, 0x06] + Array("opPlay".utf8) + [0x00])
  #expect(await eventually { await coordinator.gestureCaptures().isEmpty == false })

  // The next device's support report must not carry this device's touches.
  await coordinator.handle(.bluetoothDisconnected)
  #expect(await coordinator.gestureCaptures().isEmpty)
}

// MARK: - Stale verification results

@Test func aVerificationOutlivingItsSessionCannotStampTheNextOne() async throws {
  let profile = try #require(TandemVerifiedDeviceRegistry.profiles.first)
  let verifier = GatedVerifier(outcome: .verified(profile, fingerprint(declaring: [])))
  let (coordinator, _) = try makeCoordinator(declaring: [], verifier: verifier)

  await coordinator.handle(.defaultOutputChanged(target))
  #expect(await eventually { await coordinator.phase == .verifying })

  // The session dies while the verifier is still out. Its eventual result belongs
  // to the dead session and must be dropped, not stamped onto whatever follows.
  await coordinator.handle(.bluetoothDisconnected)
  #expect(await coordinator.phase == .released)

  verifier.release()
  try await Task.sleep(for: .milliseconds(200))
  #expect(await coordinator.phase == .released, "a stale verification advanced the session")
  #expect(await coordinator.deviceFingerprint == nil, "a stale fingerprint was adopted")
  #expect(await coordinator.verifiedProfile == nil)
}

// MARK: - Contention detection

@Test func anOpenThatTimesOutBecomesContendedAndManualRetryRecovers() async throws {
  // First open times out the way a device held by another host does; the session
  // must say `contended` — not burn retry budget hanging — and the reconnect
  // button's manual retry must actually reconnect once the channel is free.
  let (stream, continuation) = AsyncStream<Data>.makeStream()
  let channel = CountingChannel(inbound: continuation)
  let opener = ContendedThenFreeOpener(timeouts: 1) { [channel] in
    OpenedChannel(channel: channel, inbound: stream, maximumTransmissionUnit: 512)
  }
  let (coordinator, _) = try makeCoordinator(declaring: [], opener: opener)

  await coordinator.handle(.defaultOutputChanged(target))
  #expect(await eventually { await coordinator.phase == .contended })

  await coordinator.handle(.manualRetry)
  #expect(await eventually { await coordinator.phase == .ready })
  await coordinator.handle(.manualRelease)
}
