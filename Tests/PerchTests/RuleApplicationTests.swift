import Foundation
import Testing
import TandemCore
@testable import TandemSession
@testable import Perch

/// Synthetic capability-driven device. Delayed replies gate the actual write
/// chain, so ordering assertions do not depend on sleeping for writes to finish.
private actor RuleChannel: TandemChannel {
  let inbound: AsyncStream<Data>.Continuation
  var decoder = TandemStreamDecoder()
  var writes: [[UInt8]] = []
  var preset: UInt8 = 0
  var bands: [UInt8] = [5, 5]
  var cinema = false
  var background = false
  var room: UInt8 = 1
  var noise: [UInt8] = [1, 1, 0, 0, 5]
  var rejectsListening = false
  var rejectsNoise = false
  var delayNoiseReply = false
  var delayEqualizerReadback = false
  var delayedNoiseReply: [UInt8]?
  var delayedEqualizerReply: [UInt8]?

  init(_ inbound: AsyncStream<Data>.Continuation) { self.inbound = inbound }

  func configure(cinema: Bool = false, rejectListening: Bool = false, rejectNoise: Bool = false) {
    self.cinema = cinema
    rejectsListening = rejectListening
    rejectsNoise = rejectNoise
  }

  func holdNoiseReply() { delayNoiseReply = true }
  func holdEqualizerReadback() { delayEqualizerReadback = true }
  func count(_ command: UInt8) -> Int { writes.filter { $0.first == command }.count }
  var hasDelayedNoise: Bool { delayedNoiseReply != nil }
  var hasDelayedEqualizer: Bool { delayedEqualizerReply != nil }

  func write(_ data: Data) async throws {
    for frame in try decoder.append(data) where frame.dataType == TandemFrame.table1DataType {
      let bytes = [UInt8](frame.payload)
      writes.append(bytes)
      guard bytes.count >= 2 else { continue }
      let inquiry = bytes[1]
      switch bytes[0] {
      case 0x50:
        try reply([0x51, inquiry, 2, 11, 3, 0, 0, 1, 0, 0xA0, 0])
      case 0x56:
        let response = [UInt8](arrayLiteral: 0x57, inquiry, preset, UInt8(bands.count)) + bands
        if delayEqualizerReadback {
          delayedEqualizerReply = response
          delayEqualizerReadback = false
        } else { try reply(response) }
      case 0x5A: try reply([0x5B, inquiry])
      case 0x58:
        if !cinema && !background {
          preset = bytes[2]
          if bytes[3] > 0 { bands = Array(bytes.dropFirst(4)) }
        }
      case 0x60: try reply([0x61, inquiry, 1, 0, 0, 10, 1])
      case 0x66: try reply([0x67, inquiry] + noise)
      case 0x68:
        if !rejectsNoise { noise = Array(bytes.dropFirst(2)) }
        let response = [UInt8](arrayLiteral: 0x69, inquiry) + noise
        if delayNoiseReply {
          delayedNoiseReply = response
          delayNoiseReply = false
        } else { try reply(response) }
      case 0xE6:
        if inquiry == 3 { try reply([0xE7, inquiry, background ? 0 : 1, room]) }
        else { try reply([0xE7, inquiry, cinema ? 0 : 1]) }
      case 0xE8:
        if !rejectsListening {
          if inquiry == 3 { background = bytes[2] == 0; room = bytes[3] }
          else { cinema = bytes[2] == 0 }
        }
      default: break
      }
    }
  }

  func close() async { inbound.finish() }

  func reply(_ bytes: [UInt8]) throws {
    inbound.yield(try TandemFrame(
      dataType: TandemFrame.table1DataType, sequence: 0, payload: Data(bytes)
    ).encoded())
  }

  func releaseNoiseReply() throws {
    if let delayedNoiseReply {
      try reply(delayedNoiseReply)
      self.delayedNoiseReply = nil
    }
  }

  func releaseEqualizerReply() throws {
    if let delayedEqualizerReply {
      try reply(delayedEqualizerReply)
      self.delayedEqualizerReply = nil
    }
  }
}

private struct RuleOpener: TandemChannelOpening {
  let channels: [DeviceIdentity: OpenedChannel]
  func open(_ device: DeviceIdentity) async throws -> OpenedChannel {
    guard let channel = channels[device] else { throw RuleFixtureError.unknownDevice }
    return channel
  }
}

private enum RuleFixtureError: Error { case unknownDevice }

private struct RuleVerifier: DeviceVerifying {
  let codes: [UInt8]
  func verify(over requests: SessionRequesting) async throws -> VerificationOutcome {
    .verified(TandemVerifiedDeviceRegistry.profiles[0], TandemDeviceFingerprint(
      protocolIdentifier: 1, protocolFirstFlag: 0, protocolSecondFlag: 0,
      capabilityCode: 6, capabilityIdentifierLength: 17, modelName: "RULE-SYNTHETIC",
      firmwareVersion: "1.0", table1Functions: codes.map { .init(code: $0, version: 1) },
      table2Functions: []
    ))
  }
}

private func ruleEventually(_ condition: @Sendable () async -> Bool) async -> Bool {
  let deadline = ContinuousClock.now.advanced(by: .seconds(3))
  while ContinuousClock.now < deadline {
    if await condition() { return true }
    await Task.yield()
  }
  return await condition()
}

@MainActor
private struct RuleFixture {
  let session: SessionCoordinator
  let channel: RuleChannel
  let replacement: RuleChannel
  let service: SessionService
  let model: AppModel
  let codes: [UInt8]
  static let first = DeviceIdentity("rule-target-a")
  static let second = DeviceIdentity("rule-target-b")

  static func make(
    codes: [UInt8] = [0x57, 0x6D, 0xE4, 0xE5], cinema: Bool = false,
    holdInitialEqualizer: Bool = false
  ) async throws -> Self {
    func opened() -> (RuleChannel, OpenedChannel) {
      let (stream, continuation) = AsyncStream<Data>.makeStream()
      let channel = RuleChannel(continuation)
      return (channel, OpenedChannel(channel: channel, inbound: stream, maximumTransmissionUnit: 512))
    }
    let (channel, firstOpened) = opened()
    let (replacement, secondOpened) = opened()
    await channel.configure(cinema: cinema)
    if holdInitialEqualizer { await channel.holdEqualizerReadback() }
    let session = SessionCoordinator(
      opener: RuleOpener(channels: [first: firstOpened, second: secondOpened]),
      verifier: RuleVerifier(codes: codes),
      timeouts: .init(response: .seconds(5), backoffUnit: .seconds(60))
    )
    let service = SessionService(coordinator: session)
    let fixture = Self(
      session: session, channel: channel, replacement: replacement,
      service: service, model: AppModel(), codes: codes)
    await session.handle(.defaultOutputChanged(first))
    if holdInitialEqualizer {
      try #require(await ruleEventually { await channel.hasDelayedEqualizer })
    } else { try await fixture.waitForReadings() }
    await fixture.model.refresh(from: service)
    return fixture
  }

  func waitForReadings() async throws {
    let session = session, codes = codes
    try #require(await ruleEventually {
      let snapshot = await session.snapshot
      return snapshot.phase == .ready
        && (!codes.contains(0x57) || snapshot.readings.equalizer != nil)
        && (!codes.contains(0x6D) || snapshot.readings.noiseControl != nil)
        && (!codes.contains(0xE5) || snapshot.readings.listeningMode != nil)
    })
  }

  func apply(_ rule: SoundRule?) async {
    model.applyRule(rule, using: service)
    await model.waitForDeviceWrites()
  }

  func manualNoise(_ action: SoundRule.NoiseAction) async throws {
    let reading = try #require(await session.readings.noiseControl)
    let target = try #require(AppModel.noiseTarget(action, reading))
    try await session.apply(noiseControl: target)
    await model.refresh(from: service)
  }

  func finish() async { await session.handle(.manualRelease) }
}

private func noiseRule(_ action: SoundRule.NoiseAction) -> SoundRule {
  var rule = SoundRule(trigger: .app("rule-source"))
  rule.noise = action
  return rule
}

@Test @MainActor func ruleConfirmsStandardBeforeEqualizerAndRestoresEqualizerBeforeCinema() async throws {
  let f = try await RuleFixture.make(cinema: true)
  var rule = SoundRule(trigger: .app("rule-source"))
  rule.listening = .standard
  rule.equalizerPreset = 0xA0
  await f.apply(rule)
  #expect(await f.session.readings.listeningMode?.selection == .standard)
  #expect(await f.session.readings.equalizer?.selectedPreset == 0xA0)
  let writes = await f.channel.writes
  let equalizer = try #require(writes.firstIndex { $0.first == 0x58 })
  let standard = try #require(writes.firstIndex { $0 == [0xE8, 4, 1] })
  let confirmation = try #require(writes[standard...].firstIndex { $0 == [0xE6, 4] })
  #expect(standard < confirmation && confirmation < equalizer)
  let beforeRelease = writes.count
  await f.apply(nil)
  let releaseWrites = Array(await f.channel.writes.dropFirst(beforeRelease))
  let restoreEqualizer = try #require(releaseWrites.firstIndex { $0.first == 0x58 })
  let restoreCinema = try #require(releaseWrites.firstIndex { $0 == [0xE8, 4, 0] })
  #expect(restoreEqualizer < restoreCinema)
  #expect(await f.session.readings.equalizer?.selectedPreset == 0)
  #expect(await f.session.readings.listeningMode?.selection == .cinema)
  await f.finish()
}

@Test @MainActor func ruleFailedStandardSkipsEqualizerAndRetriesOnlyFailedFields() async throws {
  let f = try await RuleFixture.make(cinema: true)
  await f.channel.configure(cinema: true, rejectListening: true)
  var rule = noiseRule(.ambient)
  rule.listening = .standard
  rule.equalizerPreset = 0xA0
  await f.apply(rule)
  #expect(await f.channel.count(0x58) == 0)
  #expect(await f.channel.count(0x68) == 1)
  try await f.manualNoise(.off)
  await f.channel.configure(cinema: true)
  await f.apply(rule)
  #expect(await f.session.readings.listeningMode?.selection == .standard)
  #expect(await f.session.readings.equalizer?.selectedPreset == 0xA0)
  #expect(await f.session.readings.noiseControl?.state.isActive == false)
  #expect(await f.channel.count(0x68) == 2)
  await f.apply(nil)
  #expect(await f.session.readings.noiseControl?.state.isActive == false)
  await f.finish()
}

@Test @MainActor func noisePreviewClosedBeforeWriteCompletesRestoresConfirmedBaseline() async throws {
  let f = try await RuleFixture.make()
  let original = try #require(await f.session.readings.noiseControl?.state)
  await f.channel.holdNoiseReply()
  f.model.previewNoise(.ambient, using: f.service)
  f.model.endPreview(using: f.service)
  #expect(f.model.isPreviewing)
  let channel = f.channel
  try #require(await ruleEventually { await channel.hasDelayedNoise })
  #expect(await channel.count(0x68) == 1)
  try await channel.releaseNoiseReply()
  await f.model.waitForDeviceWrites()
  #expect(await f.session.readings.noiseControl?.state == original)
  #expect(await channel.count(0x68) == 2)
  #expect(!f.model.isPreviewing)
  await f.finish()
}

@Test @MainActor func previewUsesBaselineAfterPendingRuleAndLeavesRuleOwnershipIntact() async throws {
  let f = try await RuleFixture.make()
  let original = try #require(await f.session.readings.noiseControl?.state)
  await f.channel.holdNoiseReply()
  f.model.applyRule(noiseRule(.ambient), using: f.service)
  f.model.previewNoise(.off, using: f.service)
  f.model.endPreview(using: f.service)
  let channel = f.channel
  try #require(await ruleEventually { await channel.hasDelayedNoise })
  try await channel.releaseNoiseReply()
  await f.model.waitForDeviceWrites()
  #expect(await f.session.readings.noiseControl?.state.isActive == true)
  #expect(await f.session.readings.noiseControl?.state.isNoiseCancelling == false)
  await f.apply(nil)
  #expect(await f.session.readings.noiseControl?.state == original)
  await f.finish()
}

@Test @MainActor func ruleReplacementPreservesManualNoiseBaseline() async throws {
  let f = try await RuleFixture.make()
  await f.apply(noiseRule(.ambient))
  try await f.manualNoise(.off)
  let manual = try #require(await f.session.readings.noiseControl?.state)
  await f.apply(noiseRule(.noiseCancelling))
  #expect(await f.session.readings.noiseControl?.state.isNoiseCancelling == true)
  await f.apply(nil)
  #expect(await f.session.readings.noiseControl?.state == manual)
  await f.finish()
}

@Test @MainActor func ruleReplacementPreservesManualEqualizerBaseline() async throws {
  let f = try await RuleFixture.make()
  var first = SoundRule(trigger: .app("rule-first")); first.equalizerPreset = 0xA0
  await f.apply(first)
  try await f.session.apply(equalizerPreset: 1, bandSteps: [])
  await f.model.refresh(from: f.service)
  var second = SoundRule(trigger: .app("rule-second")); second.equalizerPreset = 0
  await f.apply(second)
  #expect(await f.session.readings.equalizer?.selectedPreset == 0)
  await f.apply(nil)
  #expect(await f.session.readings.equalizer?.selectedPreset == 1)
  await f.finish()
}

@Test @MainActor func ruleReplacementPreservesManualListeningBaseline() async throws {
  let f = try await RuleFixture.make()
  var first = SoundRule(trigger: .app("rule-first")); first.listening = .cinema
  await f.apply(first)
  try await f.session.apply(listeningSelection: .backgroundMusic(.small))
  await f.model.refresh(from: f.service)
  var second = SoundRule(trigger: .app("rule-second")); second.listening = .standard
  await f.apply(second)
  #expect(await f.session.readings.listeningMode?.selection == .standard)
  await f.apply(nil)
  #expect(await f.session.readings.listeningMode?.selection == .backgroundMusic(.small))
  await f.finish()
}

@Test @MainActor func noOpRuleDoesNotAdoptLaterManualChanges() async throws {
  let f = try await RuleFixture.make()
  let rule = noiseRule(.noiseCancelling)
  await f.apply(rule)
  #expect(await f.channel.count(0x68) == 0)
  try await f.manualNoise(.off)
  await f.apply(rule)
  await f.apply(nil)
  #expect(await f.channel.count(0x68) == 1)
  #expect(await f.session.readings.noiseControl?.state.isActive == false)
  await f.finish()
}

@Test @MainActor func rapidRuleSwitchesKeepOriginalBaselineAndLatestRequest() async throws {
  let f = try await RuleFixture.make()
  let original = try #require(await f.session.readings.noiseControl?.state)
  let first = noiseRule(.ambient), second = noiseRule(.off)
  await f.channel.holdNoiseReply()
  f.model.applyRule(first, using: f.service)
  f.model.applyRule(second, using: f.service)
  f.model.applyRule(first, using: f.service)
  let channel = f.channel
  try #require(await ruleEventually { await channel.hasDelayedNoise })
  try await channel.releaseNoiseReply()
  await f.model.waitForDeviceWrites()
  #expect(await f.session.readings.noiseControl?.state.isActive == true)
  #expect(await f.session.readings.noiseControl?.state.isNoiseCancelling == false)
  await f.apply(nil)
  #expect(await f.session.readings.noiseControl?.state == original)
  await f.channel.holdNoiseReply()
  f.model.applyRule(first, using: f.service)
  f.model.applyRule(second, using: f.service)
  f.model.applyRule(nil, using: f.service)
  try #require(await ruleEventually { await channel.hasDelayedNoise })
  try await channel.releaseNoiseReply()
  await f.model.waitForDeviceWrites()
  #expect(await f.session.readings.noiseControl?.state == original)
  await f.finish()
}

@Test @MainActor func briefOutputSuspensionPreservesRuleUndo() async throws {
  let f = try await RuleFixture.make()
  let original = try #require(await f.session.readings.noiseControl?.state)
  let rule = noiseRule(.ambient)
  await f.apply(rule)
  await f.session.handle(.defaultOutputChanged(nil))
  await f.model.refresh(from: f.service)
  await f.session.handle(.defaultOutputChanged(RuleFixture.first))
  await f.model.refresh(from: f.service)
  await f.apply(rule)
  await f.apply(nil)
  #expect(await f.session.readings.noiseControl?.state == original)
  await f.finish()
}

@Test @MainActor func previewCloseWhileSuspendedReleasesItsGateWithoutWriting() async throws {
  let f = try await RuleFixture.make()
  f.model.previewNoise(.ambient, using: f.service)
  await f.model.waitForDeviceWrites()
  #expect(f.model.isPreviewing)
  await f.session.handle(.defaultOutputChanged(nil))
  await f.model.refresh(from: f.service)
  f.model.endPreview(using: f.service)
  await f.model.waitForDeviceWrites()
  #expect(!f.model.isPreviewing)
  #expect(await f.channel.count(0x68) == 1)
  await f.finish()
}

@Test @MainActor func previewFailurePreservesLastConfirmedOwnership() async throws {
  let f = try await RuleFixture.make()
  let original = try #require(await f.session.readings.noiseControl?.state)
  f.model.previewNoise(.ambient, using: f.service)
  await f.model.waitForDeviceWrites()
  await f.channel.configure(rejectNoise: true)
  f.model.previewNoise(.off, using: f.service)
  await f.model.waitForDeviceWrites()
  #expect(f.model.isPreviewing)
  await f.channel.configure()
  f.model.endPreview(using: f.service)
  await f.model.waitForDeviceWrites()
  #expect(await f.session.readings.noiseControl?.state == original)
  #expect(!f.model.isPreviewing)
  await f.finish()
}

@Test @MainActor func previewKeepThenNewPreviewCapturesFreshManualBaseline() async throws {
  let f = try await RuleFixture.make()
  f.model.previewNoise(.ambient, using: f.service)
  f.model.previewNoise(.keep, using: f.service)
  await f.model.waitForDeviceWrites()
  #expect(!f.model.isPreviewing)
  try await f.manualNoise(.off)
  let manual = try #require(await f.session.readings.noiseControl?.state)
  f.model.previewNoise(.ambient, using: f.service)
  f.model.endPreview(using: f.service)
  await f.model.waitForDeviceWrites()
  #expect(await f.session.readings.noiseControl?.state == manual)
  await f.finish()
}

@Test @MainActor func previewEndPreservesLaterManualChangesPerField() async throws {
  let f = try await RuleFixture.make()
  f.model.previewNoise(.ambient, using: f.service)
  f.model.previewEqualizerPreset(0xA0, using: f.service)
  await f.model.waitForDeviceWrites()
  try await f.manualNoise(.off)
  try await f.session.apply(equalizerPreset: 1, bandSteps: [])
  f.model.endPreview(using: f.service)
  await f.model.waitForDeviceWrites()
  #expect(await f.session.readings.noiseControl?.state.isActive == false)
  #expect(await f.session.readings.equalizer?.selectedPreset == 1)
  f.model.previewListening(.cinema, using: f.service)
  await f.model.waitForDeviceWrites()
  try await f.session.apply(listeningSelection: .backgroundMusic(.large))
  f.model.endPreview(using: f.service)
  await f.model.waitForDeviceWrites()
  #expect(await f.session.readings.listeningMode?.selection == .backgroundMusic(.large))
  await f.finish()
}

@Test @MainActor func rulePendingWritesAndHoldsCannotReachSameModelReplacement() async throws {
  let f = try await RuleFixture.make()
  let rule = noiseRule(.ambient)
  await f.apply(rule)
  await f.channel.holdEqualizerReadback()
  f.model.applyEqualizerPreset(1, using: f.service)
  let channel = f.channel
  try #require(await ruleEventually { await channel.hasDelayedEqualizer })
  f.model.applyRule(nil, using: f.service)
  f.model.previewNoise(.off, using: f.service)
  f.model.endPreview(using: f.service)
  await f.session.handle(.defaultOutputChanged(RuleFixture.second))
  try await f.waitForReadings()
  await f.model.refresh(from: f.service)
  await f.model.waitForDeviceWrites()
  #expect(await f.replacement.count(0x68) == 0)
  #expect(await f.replacement.count(0x58) == 0)
  #expect(!f.model.isPreviewing)
  #expect(f.model.panel.equalizer?.selectedPreset == 0)
  // Same rule ID must be eligible again after adopting a new session.
  await f.apply(rule)
  #expect(await f.replacement.count(0x68) == 1)
  await f.apply(nil)
  #expect(await f.session.readings.noiseControl?.state.isNoiseCancelling == true)
  await f.finish()
}

@Test(arguments: [[999, -1, 5], [4, 5, 6]])
@MainActor func invalidRememberedCurveFailsOnceWithoutPresetFallback(memory: [Int]) async throws {
  let f = try await RuleFixture.make()
  var memoryReads = 0
  f.model.bandMemory = { _ in memoryReads += 1; return memory }
  var rule = SoundRule(trigger: .app("rule-source")); rule.equalizerPreset = 0xA0
  await f.apply(rule)
  await f.apply(rule)
  #expect(memoryReads == 1)
  #expect(await f.channel.count(0x58) == 0)
  #expect(await f.session.readings.equalizer?.selectedPreset == 0)
  await f.finish()
}

@Test @MainActor func ruleWithMissingReadingRetriesWhenInitialReadCompletes() async throws {
  let f = try await RuleFixture.make(codes: [0x57], holdInitialEqualizer: true)
  var rule = SoundRule(trigger: .app("rule-source")); rule.equalizerPreset = 0xA0
  await f.apply(rule)
  #expect(await f.channel.count(0x58) == 0)
  try await f.channel.releaseEqualizerReply()
  try await f.waitForReadings()
  await f.model.refresh(from: f.service)
  await f.apply(rule)
  #expect(await f.session.readings.equalizer?.selectedPreset == 0xA0)
  await f.finish()
}

@Test @MainActor func previewRestoresEqualizerBeforeEnteringCinema() async throws {
  let f = try await RuleFixture.make()
  f.model.previewEqualizerPreset(0xA0, using: f.service)
  await f.model.waitForDeviceWrites()
  let before = await f.channel.writes.count
  f.model.previewListening(.cinema, using: f.service)
  f.model.previewEqualizerPreset(-1, using: f.service)
  await f.model.waitForDeviceWrites()
  let writes = Array(await f.channel.writes.dropFirst(before))
  let equalizer = try #require(writes.firstIndex { $0.first == 0x58 })
  let cinema = try #require(writes.firstIndex { $0 == [0xE8, 4, 0] })
  #expect(equalizer < cinema)
  #expect(await f.session.readings.equalizer?.selectedPreset == 0)
  f.model.endPreview(using: f.service)
  await f.model.waitForDeviceWrites()
  #expect(await f.session.readings.listeningMode?.selection == .standard)
  await f.finish()
}

@Test @MainActor func equalizerRuleWorksWithoutListeningCapability() async throws {
  let f = try await RuleFixture.make(codes: [0x57])
  var rule = SoundRule(trigger: .app("rule-source")); rule.equalizerPreset = 0xA0
  await f.apply(rule)
  #expect(await f.session.readings.equalizer?.selectedPreset == 0xA0)
  await f.apply(nil)
  #expect(await f.session.readings.equalizer?.selectedPreset == 0)
  await f.finish()
}
