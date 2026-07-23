import Foundation
import TandemCore
import Testing

@testable import TandemSession

// MARK: - Observer doubles

private final class ScriptedAudioObserver: AudioOutputObserving, @unchecked Sendable {
  let changes: AsyncStream<AudioOutput>
  private let continuation: AsyncStream<AudioOutput>.Continuation
  private let lock = NSLock()
  private var now: AudioOutput = .other

  init() {
    (changes, continuation) = AsyncStream<AudioOutput>.makeStream()
  }

  /// Publishes a change and keeps it as the answer to `current()`.
  func emit(_ output: AudioOutput) {
    lock.withLock { now = output }
    continuation.yield(output)
  }

  /// Changes what `current()` answers without publishing — what happens while the
  /// machine is asleep and nobody is listening to the stream.
  func set(current output: AudioOutput) {
    lock.withLock { now = output }
  }

  func start() {}
  func stop() {}
  func current() -> AudioOutput { lock.withLock { now } }
}

private final class ScriptedBluetoothObserver: BluetoothConnectionObserving, @unchecked Sendable {
  let changes: AsyncStream<BluetoothConnectionObserver.Change>
  private let continuation: AsyncStream<BluetoothConnectionObserver.Change>.Continuation

  init() {
    (changes, continuation) = AsyncStream<BluetoothConnectionObserver.Change>.makeStream()
  }

  func emit(_ change: BluetoothConnectionObserver.Change) {
    continuation.yield(change)
  }

  func start() {}
  func stop() {}
}

private final class ScriptedPowerObserver: PowerObserving, @unchecked Sendable {
  let changes: AsyncStream<PowerObserver.Change>
  private let continuation: AsyncStream<PowerObserver.Change>.Continuation

  init() {
    (changes, continuation) = AsyncStream<PowerObserver.Change>.makeStream()
  }

  func emit(_ change: PowerObserver.Change) {
    continuation.yield(change)
  }

  func start() {}
  func stop() {}
}

/// Never completes an open, so the session stays observably `connecting`. Honours
/// cancellation so released opens do not linger past the test.
private struct HangingOpener: TandemChannelOpening {
  func open(_ device: DeviceIdentity) async throws -> OpenedChannel {
    try await Task.sleep(for: .seconds(300))
    throw ChannelFailure.openTimedOut
  }
}

private struct StubVerifier: DeviceVerifying {
  func verify(over requests: SessionRequesting) async throws -> VerificationOutcome {
    throw ChannelFailure.closed
  }
}

// MARK: - Helpers

private func makeService() -> (
  SessionService, SessionCoordinator, ScriptedAudioObserver, ScriptedBluetoothObserver,
  ScriptedPowerObserver
) {
  let coordinator = SessionCoordinator(
    opener: HangingOpener(),
    verifier: StubVerifier(),
    timeouts: SessionCoordinator.Timeouts(response: .seconds(60), backoffUnit: .seconds(60))
  )
  let audio = ScriptedAudioObserver()
  let bluetooth = ScriptedBluetoothObserver()
  let power = ScriptedPowerObserver()
  let service = SessionService(
    coordinator: coordinator, audio: audio, bluetooth: bluetooth, power: power
  )
  return (service, coordinator, audio, bluetooth, power)
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

private let deviceA = DeviceIdentity("device-a")
private let deviceB = DeviceIdentity("device-b")

// MARK: - Translation

@Test func anIdentifiedOutputStartsASessionForThatDevice() async {
  let (service, coordinator, audio, _, _) = makeService()
  await service.start()

  audio.emit(.identified(deviceA))
  #expect(await eventually { await coordinator.phase == .connecting })

  await service.stop()
  await coordinator.handle(.manualRelease)
}

@Test func anUnidentifiableOutputIsTreatedAsNoTarget() async {
  // An output that cannot be pinned to a paired device must end the session, not
  // keep it: guessing would risk driving the wrong headphones.
  let (service, coordinator, audio, _, _) = makeService()
  await service.start()

  audio.emit(.identified(deviceA))
  #expect(await eventually { await coordinator.phase == .connecting })

  audio.emit(.unidentifiedBluetooth(uid: "test-uid"))
  #expect(await eventually { await coordinator.phase == .released })

  await service.stop()
}

@Test func onlyTheCurrentTargetsDisconnectEndsTheSession() async {
  let (service, coordinator, audio, bluetooth, _) = makeService()
  await service.start()

  audio.emit(.identified(deviceA))
  #expect(await eventually { await coordinator.phase == .connecting })

  // Some other headset disconnecting is not ours to act on.
  bluetooth.emit(.disconnected(deviceB))
  try? await Task.sleep(for: .milliseconds(150))
  #expect(await coordinator.phase == .connecting)

  bluetooth.emit(.disconnected(deviceA))
  #expect(await eventually { await coordinator.phase == .released })

  await service.stop()
}

@Test func wakingAsksTheAudioSystemInsteadOfTrustingTheStoredTarget() async {
  let (service, coordinator, audio, _, power) = makeService()
  await service.start()

  audio.emit(.identified(deviceA))
  #expect(await eventually { await coordinator.phase == .connecting })

  power.emit(.willSleep)
  #expect(await eventually { await coordinator.phase == .sleeping(resume: .reconnect) })

  // While asleep the output moved to the speakers; what was true before sleeping
  // must not reconnect the headphones.
  audio.set(current: .other)
  power.emit(.didWake)
  #expect(await eventually { await coordinator.phase == .released })

  await service.stop()
}

@Test func wakingWithADifferentOutputConnectsToTheDeviceActuallyPlaying() async {
  let (service, coordinator, audio, _, power) = makeService()
  await service.start()

  audio.emit(.identified(deviceA))
  #expect(await eventually { await coordinator.phase == .connecting })

  power.emit(.willSleep)
  #expect(await eventually { await coordinator.phase == .sleeping(resume: .reconnect) })

  audio.set(current: .identified(deviceB))
  power.emit(.didWake)
  #expect(await eventually { await coordinator.phase == .connecting })

  await service.stop()
  await coordinator.handle(.manualRelease)
}
