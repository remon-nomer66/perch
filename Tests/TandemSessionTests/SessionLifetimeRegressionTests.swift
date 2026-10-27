import Foundation
import TandemCore
import Testing

@testable import TandemSession

private actor Gate {
  private var released = false
  private var waiting: [CheckedContinuation<Void, Never>] = []
  func wait() async {
    guard !released else { return }
    await withCheckedContinuation { waiting.append($0) }
  }
  func release() {
    released = true
    let pending = waiting
    waiting = []
    pending.forEach { $0.resume() }
  }
}

/// No hardware: requests and lifecycle completions are controlled by each test.
private actor LifetimeChannel: TandemChannel {
  let inbound: AsyncStream<Data>.Continuation
  private var decoder = TandemStreamDecoder()
  private(set) var frames: [TandemFrame] = []
  private(set) var closeCount = 0
  private(set) var acknowledgementCount = 0
  private var writeGate: (UInt8, Gate)?
  private var closeGate: Gate?
  private var ackGate: Gate?
  private var failingCommand: UInt8?
  private var malformedListening = false
  private var preset: UInt8 = 0
  private var bands: [UInt8]

  init(_ inbound: AsyncStream<Data>.Continuation, bands: [UInt8]) {
    self.inbound = inbound
    self.bands = bands
  }
  func holdWrite(_ command: UInt8, on gate: Gate) { writeGate = (command, gate) }
  func holdClose(on gate: Gate) { closeGate = gate }
  func holdAcknowledgement(on gate: Gate) { ackGate = gate }
  func failWrite(_ command: UInt8) { failingCommand = command }
  func malformedListeningReadback() { malformedListening = true }
  func count(_ command: UInt8) -> Int { frames.filter { $0.payload.first == command }.count }
  func commands() -> [UInt8] { frames.compactMap { $0.payload.first } }
  func write(_ data: Data) async throws {
    for frame in try decoder.append(data) {
      guard frame.dataType == TandemFrame.table1DataType else {
        acknowledgementCount += 1
        if let ackGate { await ackGate.wait() }
        continue
      }
      frames.append(frame)
      let bytes = [UInt8](frame.payload)
      guard let command = bytes.first else { continue }
      if let (held, gate) = writeGate, held == command { await gate.wait() }
      if failingCommand == command { throw ChannelFailure.writeRejected(-1) }
      guard bytes.count >= 2 else { continue }
      let inquiry = bytes[1]
      switch command {
      case 0x50: try reply([0x51, inquiry, UInt8(bands.count), 11, 2, 0, 0, 0xA0, 0])
      case 0x56: try reply([0x57, inquiry, preset, UInt8(bands.count)] + bands)
      case 0x5A: try reply([0x5B, inquiry])
      case 0xE6: try reply(malformedListening ? [0xE7, inquiry] : [0xE7, inquiry, 1])
      case 0x58:
        if bytes[2] != 0xFF { preset = bytes[2] }
        if bytes[3] > 0 { bands = Array(bytes.dropFirst(4)) }
      default: break
      }
    }
  }
  func close() async {
    closeCount += 1
    if let closeGate { await closeGate.wait() }
    inbound.finish()
  }
  func finishInbound() { inbound.finish() }
  func reply(_ payload: [UInt8]) throws {
    inbound.yield(try TandemFrame(
      dataType: TandemFrame.table1DataType, sequence: 0, payload: Data(payload)
    ).encoded())
  }
}

private actor DelayedOpener: TandemChannelOpening {
  private var waiting: [DeviceIdentity: CheckedContinuation<OpenedChannel, Error>] = [:]
  private(set) var calls: [DeviceIdentity] = []
  func open(_ device: DeviceIdentity) async throws -> OpenedChannel {
    calls.append(device)
    return try await withCheckedThrowingContinuation { waiting[device] = $0 }
  }
  func isWaiting(_ device: DeviceIdentity) -> Bool { waiting[device] != nil }
  func finish(_ device: DeviceIdentity, with opened: OpenedChannel) {
    waiting.removeValue(forKey: device)?.resume(returning: opened)
  }
}

private struct LifetimeVerifier: DeviceVerifying {
  var codes: [UInt8] = []
  var requestsDuringVerification = false
  var dialect: TandemDialect = .current
  func verify(over requests: SessionRequesting) async throws -> VerificationOutcome {
    if requestsDuringVerification {
      _ = try await requests.request(lifetimeFrame(0x0A), matching: lifetimeReply)
    }
    return .verified(TandemVerifiedDeviceRegistry.profiles[0], TandemDeviceFingerprint(
      protocolIdentifier: 1, protocolFirstFlag: 0, protocolSecondFlag: 0,
      capabilityCode: 6, capabilityIdentifierLength: 17, modelName: "SYNTHETIC",
      firmwareVersion: "1.0", table1Functions: codes.map { .init(code: $0, version: 1) },
      table2Functions: [], dialect: dialect
    ))
  }
}

private func lifetimeChannel(bands: [UInt8] = [5, 5]) -> (LifetimeChannel, OpenedChannel) {
  let (stream, continuation) = AsyncStream<Data>.makeStream()
  let channel = LifetimeChannel(continuation, bands: bands)
  return (channel, OpenedChannel(channel: channel, inbound: stream, maximumTransmissionUnit: 512))
}
private func lifetimeFrame(_ command: UInt8) -> @Sendable (UInt8) throws -> TandemFrame {
  { try TandemFrame(dataType: TandemFrame.table1DataType, sequence: $0, payload: Data([command, 0])) }
}
private let lifetimeReply: @Sendable (TandemFrame) -> Bool = { $0.payload.first == 0x0B }
private let targetA = DeviceIdentity("lifetime-a")
private let targetB = DeviceIdentity("lifetime-b")
private func lifetimeCoordinator(
  _ opener: DelayedOpener, verifier: LifetimeVerifier = .init()
) -> SessionCoordinator {
  SessionCoordinator(opener: opener, verifier: verifier,
    timeouts: .init(response: .seconds(60), grace: .seconds(60), backoffUnit: .seconds(60)))
}
private func lifetimeEventually(_ condition: @Sendable () async -> Bool) async -> Bool {
  let deadline = ContinuousClock.now.advanced(by: .seconds(5))
  while ContinuousClock.now < deadline {
    if await condition() { return true }
    await Task.yield()
  }
  return await condition()
}
private func lifetimeReady(
  verifier: LifetimeVerifier = .init(), bands: [UInt8] = [5, 5]
) async throws -> (SessionCoordinator, DelayedOpener, LifetimeChannel) {
  let opener = DelayedOpener()
  let coordinator = lifetimeCoordinator(opener, verifier: verifier)
  let (channel, opened) = lifetimeChannel(bands: bands)
  await coordinator.handle(.defaultOutputChanged(targetA))
  try #require(await lifetimeEventually { await opener.isWaiting(targetA) })
  await opener.finish(targetA, with: opened)
  try #require(await lifetimeEventually { await coordinator.phase == .ready })
  if verifier.codes.contains(0x57) || verifier.codes.contains(0x56) {
    try #require(await lifetimeEventually { await coordinator.readings.equalizer != nil })
  }
  if verifier.codes.contains(0xE5) {
    try #require(await lifetimeEventually { await coordinator.readings.listeningMode != nil })
  }
  return (coordinator, opener, channel)
}

@Test(arguments: [false, true]) func staleOpenCannotReplaceAnAlreadyVerifyingChannel(
  releaseBetweenTargets: Bool
) async throws {
  let opener = DelayedOpener()
  let coordinator = lifetimeCoordinator(opener, verifier: .init(requestsDuringVerification: true))
  let (old, oldOpened) = lifetimeChannel()
  let (current, currentOpened) = lifetimeChannel()
  await coordinator.handle(.defaultOutputChanged(targetA))
  try #require(await lifetimeEventually { await opener.isWaiting(targetA) })
  if releaseBetweenTargets { await coordinator.handle(.defaultOutputChanged(nil)) }
  await coordinator.handle(.defaultOutputChanged(targetB))
  try #require(await lifetimeEventually { await opener.isWaiting(targetB) })
  await opener.finish(targetB, with: currentOpened)
  try #require(await lifetimeEventually { await current.count(0x0A) == 1 })
  await opener.finish(targetA, with: oldOpened)
  try #require(await lifetimeEventually { await old.closeCount == 1 })
  try await current.reply([0x0B, 0])
  #expect(await lifetimeEventually { await coordinator.phase == .ready })
  #expect(await current.closeCount == 0)
  await coordinator.shutdown()
}

@Test(arguments: [false, true]) func closeBarrierPreventsReentrantTeardownAndObsoleteOpen(
  releaseDuringClose: Bool
) async throws {
  let (coordinator, opener, channel) = try await lifetimeReady()
  let gate = Gate()
  await channel.holdClose(on: gate)
  let switching = Task { await coordinator.handle(.defaultOutputChanged(targetB)) }
  try #require(await lifetimeEventually { await channel.closeCount == 1 })
  #expect(await opener.calls == [targetA])
  let release = releaseDuringClose ? Task { await coordinator.handle(.manualRelease) } : nil
  if releaseDuringClose {
    try #require(await lifetimeEventually { await coordinator.phase == .released })
  }
  await gate.release()
  await switching.value
  await release?.value
  if releaseDuringClose {
    #expect(await opener.calls == [targetA])
    #expect(await coordinator.phase == .released)
  } else {
    try #require(await lifetimeEventually { await opener.isWaiting(targetB) })
    let (next, opened) = lifetimeChannel()
    await opener.finish(targetB, with: opened)
    try #require(await lifetimeEventually { await coordinator.phase == .ready })
    let request = Task { try await coordinator.send(lifetimeFrame(0x0A), matching: lifetimeReply) }
    try #require(await lifetimeEventually { await next.count(0x0A) == 1 })
    try await next.reply([0x0B, 0])
    _ = try await request.value
    #expect(await next.closeCount == 0)
  }
  await coordinator.shutdown()
}

@Test func noReplyWritesUseTheRequestFIFOAndAllowAcknowledgements() async throws {
  let (coordinator, _, channel) = try await lifetimeReady()
  let first = Task { try await coordinator.send(lifetimeFrame(0x0A), matching: lifetimeReply) }
  try #require(await lifetimeEventually { await channel.count(0x0A) == 1 })
  let setting = Task { try await coordinator.writeWithoutReply(lifetimeFrame(0x0C)) }
  try #require(await lifetimeEventually { await coordinator.queuedSendCount == 1 })
  let last = Task { try await coordinator.send(lifetimeFrame(0x0D), matching: lifetimeReply) }
  try #require(await lifetimeEventually { await coordinator.queuedSendCount == 2 })
  #expect(await channel.commands() == [0x0A])
  try await channel.reply([0x0B, 0])
  _ = try await first.value
  try await setting.value
  try #require(await lifetimeEventually { await channel.count(0x0D) == 1 })
  #expect(await channel.commands() == [0x0A, 0x0C, 0x0D])
  #expect(await channel.acknowledgementCount >= 1)
  try await channel.reply([0x0B, 0])
  _ = try await last.value
  await coordinator.shutdown()
}

@Test func cancelledQueuedWriteSendsNothingAndReleasesItsTurn() async throws {
  let (coordinator, _, channel) = try await lifetimeReady()
  let first = Task { try await coordinator.send(lifetimeFrame(0x0A), matching: lifetimeReply) }
  try #require(await lifetimeEventually { await channel.count(0x0A) == 1 })
  let cancelled = Task { try await coordinator.writeWithoutReply(lifetimeFrame(0x0C)) }
  try #require(await lifetimeEventually { await coordinator.queuedSendCount == 1 })
  cancelled.cancel()
  let next = Task { try await coordinator.writeWithoutReply(lifetimeFrame(0x0D)) }
  try #require(await lifetimeEventually { await coordinator.queuedSendCount == 2 })
  try await channel.reply([0x0B, 0])
  _ = try await first.value
  await #expect(throws: CancellationError.self) { try await cancelled.value }
  try await next.value
  #expect(await channel.commands() == [0x0A, 0x0D])
  await coordinator.shutdown()
}

@Test func noReplyTransportFailureDoesNotStrandTheQueue() async throws {
  let (coordinator, _, channel) = try await lifetimeReady()
  await channel.failWrite(0x0C)
  await #expect(throws: SessionRequestFailure.channel(.writeRejected(-1))) {
    try await coordinator.writeWithoutReply(lifetimeFrame(0x0C))
  }
  try await coordinator.writeWithoutReply(lifetimeFrame(0x0D))
  #expect(await channel.commands() == [0x0C, 0x0D])
  await coordinator.shutdown()
}

@Test func invalidationReleasesBlockedNoReplyWithoutGivingAwayTheSuccessorsTurn() async throws {
  let (coordinator, opener, old) = try await lifetimeReady()
  let gate = Gate()
  await old.holdWrite(0x0C, on: gate)
  let blocked = Task { try await coordinator.writeWithoutReply(lifetimeFrame(0x0C)) }
  try #require(await lifetimeEventually { await old.count(0x0C) == 1 })
  let queuedOld = Task { try await coordinator.writeWithoutReply(lifetimeFrame(0x0E)) }
  try #require(await lifetimeEventually { await coordinator.queuedSendCount == 1 })
  await coordinator.handle(.defaultOutputChanged(targetB))
  await #expect(throws: SessionRequestFailure.failed(.sessionInvalidated)) { try await queuedOld.value }
  try #require(await lifetimeEventually { await opener.isWaiting(targetB) })
  let (next, nextOpened) = lifetimeChannel()
  await opener.finish(targetB, with: nextOpened)
  try #require(await lifetimeEventually { await coordinator.phase == .ready })
  let live = Task { try await coordinator.send(lifetimeFrame(0x0A), matching: lifetimeReply) }
  try #require(await lifetimeEventually { await next.count(0x0A) == 1 })
  let queued = Task { try await coordinator.writeWithoutReply(lifetimeFrame(0x0D)) }
  try #require(await lifetimeEventually { await coordinator.queuedSendCount == 1 })
  await gate.release()
  await #expect(throws: SessionRequestFailure.failed(.sessionInvalidated)) { try await blocked.value }
  #expect(await coordinator.queuedSendCount == 1)
  #expect(await next.commands() == [0x0A])
  try await next.reply([0x0B, 0])
  _ = try await live.value
  try await queued.value
  #expect(await old.count(0x0E) == 0)
  await coordinator.shutdown()
}

@Test func anOldAcknowledgementCannotHoldUpASuccessorSession() async throws {
  let (coordinator, opener, old) = try await lifetimeReady()
  let gate = Gate()
  await old.holdAcknowledgement(on: gate)
  try await old.reply([0x0B, 0])
  try #require(await lifetimeEventually { await old.acknowledgementCount == 1 })
  await coordinator.handle(.defaultOutputChanged(targetB))
  try #require(await lifetimeEventually { await opener.isWaiting(targetB) })
  let (next, nextOpened) = lifetimeChannel()
  await opener.finish(targetB, with: nextOpened)
  try #require(await lifetimeEventually { await coordinator.phase == .ready })
  let request = Task { try await coordinator.send(lifetimeFrame(0x0A), matching: lifetimeReply) }
  try #require(await lifetimeEventually { await next.count(0x0A) == 1 })
  // The old ACK remains blocked. The successor's request and ACK use a fresh
  // transport chain, so they must finish before that old write is released.
  try await next.reply([0x0B, 1])
  let response = try await request.value
  #expect([UInt8](response.payload) == [0x0B, 1])
  await gate.release()
  await coordinator.shutdown()
}

@Test func suspendedRemoteCloseDetachesTheChannelExactlyOnce() async throws {
  let (coordinator, _, channel) = try await lifetimeReady()
  await coordinator.handle(.defaultOutputChanged(nil))
  await channel.finishInbound()
  try #require(await lifetimeEventually { await coordinator.phase == .released })
  await coordinator.shutdown()
  #expect(await channel.closeCount == 1)
}

@Test(arguments: [false, true]) func equalizerRejectsInvalidCapabilityValuesBeforeQueueing(
  isFinal: Bool
) async throws {
  let (coordinator, _, channel) = try await lifetimeReady(verifier: .init(codes: [0x57]))
  let busy = Task { try await coordinator.send(lifetimeFrame(0x0A), matching: lifetimeReply) }
  try #require(await lifetimeEventually { await channel.count(0x0A) == 1 })
  await #expect(throws: SessionCoordinator.WriteFailure.invalidEqualizer(.bandCountMismatch(expected: 2, actual: 3))) {
    try await coordinator.apply(equalizerPreset: 0xA0, bandSteps: [5, 5, 5], isFinal: isFinal)
  }
  await #expect(throws: SessionCoordinator.WriteFailure.invalidEqualizer(.bandStepOutOfRange(step: 11, levelStepCount: 11))) {
    try await coordinator.apply(equalizerPreset: 0xA0, bandSteps: [5, 11], isFinal: isFinal)
  }
  await #expect(throws: SessionCoordinator.WriteFailure.undeclaredEqualizerPreset(0x42)) {
    try await coordinator.apply(equalizerPreset: 0x42, bandSteps: [], isFinal: isFinal)
  }
  #expect(await coordinator.queuedSendCount == 0)
  #expect(await channel.count(0x58) == 0)
  try await channel.reply([0x0B, 0])
  _ = try await busy.value
  await coordinator.shutdown()
}

@Test func equalizerWithoutAReadingIsUnsupportedAndSendsNothing() async throws {
  let (coordinator, _, channel) = try await lifetimeReady()
  await #expect(throws: SessionCoordinator.WriteFailure.unsupported) {
    try await coordinator.apply(equalizerPreset: 0, bandSteps: [])
  }
  #expect(await channel.count(0x58) == 0)
  await coordinator.shutdown()
}

@Test func legacyEqualizerPreservesCurrentPresetAddressingForBandWrites() async throws {
  let (coordinator, _, channel) = try await lifetimeReady(
    verifier: .init(codes: [0x56], dialect: .legacy), bands: Array(repeating: 5, count: 6))
  let reading = try #require(await coordinator.readings.equalizer)
  let preset = try #require(reading.presets.first?.identifier)
  let levels = Array(repeating: UInt8(reading.flatStep), count: reading.bandCount)
  try await coordinator.apply(equalizerPreset: preset, bandSteps: levels, isFinal: false)
  try await coordinator.apply(equalizerPreset: preset, bandSteps: levels)
  try await coordinator.apply(equalizerPreset: preset, bandSteps: [])
  let sets = await channel.frames.filter { $0.payload.first == 0x58 }
  #expect(sets.count == 3)
  #expect(sets[0].payload[2] == 0xFF)
  #expect(sets[1].payload[2] == 0xFF)
  #expect(sets[2].payload[2] == preset)
  await coordinator.shutdown()
}

@Test func anEpochCapturedWhileConnectingCannotWriteIntoTheAdoptedSession() async throws {
  let opener = DelayedOpener()
  let coordinator = lifetimeCoordinator(opener, verifier: .init(codes: [0x57]))
  await coordinator.handle(.defaultOutputChanged(targetA))
  let connectingEpoch = await coordinator.snapshot.epoch
  try #require(await lifetimeEventually { await opener.isWaiting(targetA) })
  let (channel, opened) = lifetimeChannel()
  await opener.finish(targetA, with: opened)
  try #require(await lifetimeEventually { await coordinator.readings.equalizer != nil })
  #expect(await coordinator.snapshot.epoch != connectingEpoch)
  await #expect(throws: SessionCoordinator.WriteFailure.failed(.failed(.sessionInvalidated))) {
    try await coordinator.apply(equalizerPreset: 0, bandSteps: [], expectedEpoch: connectingEpoch)
  }
  #expect(await channel.count(0x58) == 0)
  await coordinator.shutdown()
}

@Test func equalizerInvalidatedAfterSetDoesNotReadOrStoreIntoTheSuccessor() async throws {
  let (coordinator, opener, old) = try await lifetimeReady(verifier: .init(codes: [0x57]))
  let gate = Gate()
  await old.holdWrite(0x58, on: gate)
  let oldEpoch = await coordinator.snapshot.epoch
  let apply = Task { try await coordinator.apply(equalizerPreset: 0xA0, bandSteps: [7, 3], expectedEpoch: oldEpoch) }
  try #require(await lifetimeEventually { await old.count(0x58) == 1 })
  await coordinator.handle(.defaultOutputChanged(targetB))
  try #require(await lifetimeEventually { await opener.isWaiting(targetB) })
  let (next, nextOpened) = lifetimeChannel()
  await opener.finish(targetB, with: nextOpened)
  try #require(await lifetimeEventually { await coordinator.readings.equalizer != nil })
  let reads = await next.count(0x56)
  await gate.release()
  await #expect(throws: SessionCoordinator.WriteFailure.failed(.failed(.sessionInvalidated))) { try await apply.value }
  #expect(await next.count(0x56) == reads)
  #expect(await next.count(0x58) == 0)
  #expect(await coordinator.readings.equalizer?.bandSteps == [5, 5])
  await coordinator.shutdown()
}

@Test func malformedListeningReadbackCannotConfirmStandard() async throws {
  let (coordinator, _, channel) = try await lifetimeReady(verifier: .init(codes: [0xE5]))
  await channel.malformedListeningReadback()
  await #expect(throws: (any Error).self) {
    try await coordinator.apply(listeningSelection: .standard)
  }
  await coordinator.shutdown()
}

@Test func everyReleaseRetainsTheAttemptAndRejectsAllOldCompletionKinds() {
  let policy = SessionPolicy()
  let phases: [SessionState.Phase] = [
    .connecting, .verifying, .ready, .recovering, .unverified, .contended,
    .suspended(resume: .ready), .retryWaiting, .retryExhausted,
    .sleeping(resume: .reconnect), .sleeping(resume: .blocked(.unverified)),
  ]
  let endings: [SessionEvent] = [
    .manualRelease, .bluetoothDisconnected, .defaultOutputChanged(nil), .graceExpired, .didWake(nil),
  ]
  let attempt = ConnectionAttempt(73)
  for phase in phases {
    let initial = SessionState(phase: phase, target: targetA, failureCount: 2,
      attempt: attempt, isTargetDefaultOutput: true)
    for ending in endings {
      let (released, _) = policy.reduce(initial, ending)
      guard released.phase == .released else { continue }
      #expect(released.attempt == attempt)
      #expect(released.target == nil)
      #expect(released.failureCount == 0)
      for device in [targetA, targetB] {
        let (reconnected, _) = policy.reduce(released, .defaultOutputChanged(device))
        #expect(reconnected.attempt == attempt.next)
        for late: SessionEvent in [
          .channelFailed(attempt), .controlContended(attempt), .channelClosedUnexpectedly(attempt),
        ] {
          let (unchanged, effects) = policy.reduce(reconnected, late)
          #expect(unchanged == reconnected)
          #expect(effects.isEmpty)
        }
        let (unchanged, effects) = policy.reduce(reconnected, .channelOpened(attempt))
        #expect(unchanged == reconnected)
        #expect(effects == [.closeChannel])
      }
    }
  }
}

private final class LifetimeAudio: AudioOutputObserving, @unchecked Sendable {
  let changes: AsyncStream<AudioOutput>
  private let continuation: AsyncStream<AudioOutput>.Continuation
  private let lock = NSLock()
  private var starts = 0
  private var stops = 0
  init() { (changes, continuation) = AsyncStream<AudioOutput>.makeStream() }
  func start() { lock.withLock { starts += 1 } }
  func stop() { lock.withLock { stops += 1 } }
  func current() -> AudioOutput { .other }
  func emit(_ output: AudioOutput) { continuation.yield(output) }
  var counts: (Int, Int) { lock.withLock { (starts, stops) } }
}
private struct LifetimeBluetooth: BluetoothConnectionObserving {
  let changes = AsyncStream<BluetoothConnectionObserver.Change> { _ in }
  func start() {}
  func stop() {}
}
private struct LifetimePower: PowerObserving {
  let changes = AsyncStream<PowerObserver.Change> { _ in }
  func start() {}
  func stop() {}
}
private actor CompletionFlag {
  private(set) var finished = false
  func finish() { finished = true }
}
private func lifetimeService(_ coordinator: SessionCoordinator, audio: LifetimeAudio) -> SessionService {
  SessionService(coordinator: coordinator, audio: audio,
    bluetooth: LifetimeBluetooth(), power: LifetimePower())
}

@Test func serviceStopWaitsForCloseAndIsTerminalAndIdempotent() async throws {
  let (coordinator, opener, channel) = try await lifetimeReady()
  let audio = LifetimeAudio()
  let service = lifetimeService(coordinator, audio: audio)
  await service.start()
  await service.start()
  #expect(audio.counts.0 == 1)
  let gate = Gate()
  await channel.holdClose(on: gate)
  let finished = CompletionFlag()
  let first = Task { await service.stop(); await finished.finish() }
  try #require(await lifetimeEventually { await channel.closeCount == 1 })
  let second = Task { await service.stop() }
  #expect(await finished.finished == false)
  await coordinator.handle(.defaultOutputChanged(targetB))
  #expect(await opener.calls == [targetA])
  await gate.release()
  await first.value
  await second.value
  #expect(await coordinator.phase == .released)
  #expect(await channel.closeCount == 1)
  #expect(audio.counts.1 == 1)
  await service.start()
  audio.emit(.identified(targetB))
  await coordinator.handle(.manualRetry)
  #expect(audio.counts.0 == 1)
  #expect(await opener.calls == [targetA])
}

@Test func stoppingBeforeStartingCannotStartObserversOrReopenTheCoordinator() async {
  let opener = DelayedOpener()
  let coordinator = lifetimeCoordinator(opener)
  let audio = LifetimeAudio()
  let service = lifetimeService(coordinator, audio: audio)
  await service.stop()
  await service.stop()
  await service.start()
  audio.emit(.identified(targetA))
  await coordinator.handle(.defaultOutputChanged(targetA))
  #expect(audio.counts.0 == 0)
  #expect(audio.counts.1 == 1)
  #expect(await opener.calls.isEmpty)
}

@Test func stoppingWhileConnectingClosesAnUncooperativeLateOpen() async throws {
  let opener = DelayedOpener()
  let coordinator = lifetimeCoordinator(opener)
  let audio = LifetimeAudio()
  let service = lifetimeService(coordinator, audio: audio)
  await service.start()
  audio.emit(.identified(targetA))
  try #require(await lifetimeEventually { await opener.isWaiting(targetA) })
  await service.stop()
  let (late, opened) = lifetimeChannel()
  await opener.finish(targetA, with: opened)
  try #require(await lifetimeEventually { await late.closeCount == 1 })
  #expect(await coordinator.phase == .released)
  #expect(await late.frames.isEmpty)
}

@Test func serviceStopDrainsAPumpAlreadyAwaitingCloseBeforeShutdown() async throws {
  let (coordinator, opener, old) = try await lifetimeReady()
  let audio = LifetimeAudio()
  let service = lifetimeService(coordinator, audio: audio)
  await service.start()
  let gate = Gate()
  await old.holdClose(on: gate)
  audio.emit(.identified(targetB))
  try #require(await lifetimeEventually { await old.closeCount == 1 })
  let finished = CompletionFlag()
  let stop = Task { await service.stop(); await finished.finish() }
  audio.emit(.identified(DeviceIdentity("buffered-output")))
  #expect(await finished.finished == false)
  await gate.release()
  await stop.value
  #expect(await coordinator.phase == .released)
  let stoppedCalls = await opener.calls
  await coordinator.handle(.defaultOutputChanged(targetA))
  #expect(await opener.calls == stoppedCalls)
  // The pending event was allowed to finish before the terminal latch. If its
  // opener began before shutdown, a late result still has to be closed.
  if await opener.isWaiting(targetB) {
    let (late, opened) = lifetimeChannel()
    await opener.finish(targetB, with: opened)
    try #require(await lifetimeEventually { await late.closeCount == 1 })
  }
}
