import Foundation
import TandemCore
import Testing

@testable import TandemSession

// MARK: - Reader doubles

/// Answers the general-setting conversation the way a device that names one of its
/// slots sidetone does, and records which path — probe or request — each message
/// took. The slot numbers are the test's own choices: the reader must find sidetone
/// by the capability's label, never by a particular slot.
private final class GeneralSettingRequester: SessionRequesting, @unchecked Sendable {
  private let lock = NSLock()
  private var probed: [[UInt8]] = []
  private var requested: [[UInt8]] = []
  private let sidetoneSlot: UInt8
  /// Capability queries left unanswered, as a declared slot that will not describe
  /// itself when asked.
  private let silentCapabilitySlots: Set<UInt8>

  init(sidetoneSlot: UInt8, silentCapabilitySlots: Set<UInt8> = []) {
    self.sidetoneSlot = sidetoneSlot
    self.silentCapabilitySlots = silentCapabilitySlots
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
    guard payload.count >= 2 else { throw ChannelFailure.openTimedOut }
    let slot = payload[1]
    func reply(_ bytes: [UInt8]) throws -> TandemFrame {
      try TandemFrame(
        dataType: TandemFrame.table1DataType,
        sequence: 1,
        payload: Data(bytes)
      )
    }
    switch payload[0] {
    case 0xD0:
      guard !silentCapabilitySlots.contains(slot) else { throw ChannelFailure.openTimedOut }
      let title = slot == sidetoneSlot ? "SIDETONE_SETTING" : "SOMETHING_ELSE"
      let text = Array(title.utf8)
      return try reply([0xD1, slot, 0x00, 0x01, UInt8(text.count)] + text + [0x00])
    case 0xD2:
      return try reply([0xD3, slot, 0x00])
    case 0xD6:
      return try reply([0xD7, slot, 0x00, 0x01])
    default:
      throw ChannelFailure.openTimedOut
    }
  }
}

private func declared(_ codes: [UInt8]) -> [TandemSupportFunction] {
  codes.map { TandemSupportFunction(code: $0, version: 0) }
}

// MARK: - Reader tests

@Test func sidetoneIsFoundByItsLabelAndSlotCapabilitiesAreProbedNotRequested() async throws {
  let requester = GeneralSettingRequester(sidetoneSlot: 0xD2)
  let readings = await FeatureReader().read(
    declaring: declared([0xD1, 0xD2]),
    over: requester
  )

  let sidetone = try #require(readings.sidetone)
  #expect(sidetone.slot == .two)
  #expect(sidetone.isControlEnabled)
  #expect(sidetone.isEnabled == false)

  // Every declared slot was asked to describe itself, and on the probe path: a
  // capability that goes unanswered must fail only itself, not fault the session.
  #expect(requester.probedPayloads.contains([0xD0, 0xD1, 0x0B]))
  #expect(requester.probedPayloads.contains([0xD0, 0xD2, 0x0B]))
  #expect(!requester.requestedPayloads.contains { $0.first == 0xD0 })

  // The status and parameter of the slot that answered follow the declared-feature
  // rule and go out as plain requests.
  #expect(requester.requestedPayloads.contains([0xD2, 0xD2]))
  #expect(requester.requestedPayloads.contains([0xD6, 0xD2]))
}

@Test func aSlotThatWillNotDescribeItselfIsSkippedForTheOnesThatDo() async throws {
  let requester = GeneralSettingRequester(sidetoneSlot: 0xD3, silentCapabilitySlots: [0xD1])
  let readings = await FeatureReader().read(
    declaring: declared([0xD1, 0xD3]),
    over: requester
  )
  #expect(readings.sidetone?.slot == .three)
}

@Test func aDeviceWhoseSlotsNameNoSidetoneReadsAsAbsent() async {
  // Both slots answer, neither label is sidetone: the values are read and discarded.
  let requester = GeneralSettingRequester(sidetoneSlot: 0xFF)
  let readings = await FeatureReader().read(
    declaring: declared([0xD1, 0xD4]),
    over: requester
  )
  #expect(readings.sidetone == nil)
}

@Test func nothingIsAskedWithoutADeclaredGeneralSettingSlot() async {
  let requester = GeneralSettingRequester(sidetoneSlot: 0xD1)
  let readings = await FeatureReader().read(declaring: [], over: requester)
  #expect(readings.sidetone == nil)
  #expect(requester.probedPayloads.isEmpty)
  #expect(requester.requestedPayloads.isEmpty)
}

// MARK: - Coordinator doubles

/// A device double that keeps sidetone in one of its general-setting slots and
/// answers that conversation from its own state. `honoursSets` scripts whether a set
/// request takes effect, which is what the read-back verification distinguishes.
private actor SidetoneDevice: TandemChannel {
  private let inbound: AsyncStream<Data>.Continuation
  private var decoder = TandemStreamDecoder()
  private let honoursSets: Bool
  private var sidetoneEnabled = false

  /// Where this device happens to keep sidetone; the coordinator has to learn it
  /// from the capability rather than assume it.
  static let sidetoneSlot: UInt8 = 0xD2

  init(inbound: AsyncStream<Data>.Continuation, honoursSets: Bool) {
    self.inbound = inbound
    self.honoursSets = honoursSets
  }

  func write(_ data: Data) async throws {
    guard let frames = try? decoder.append(data) else { return }
    for frame in frames where frame.dataType == TandemFrame.table1DataType {
      let bytes = [UInt8](frame.payload)
      guard bytes.count >= 2 else { continue }
      let slot = bytes[1]
      switch bytes[0] {
      case 0xD0:
        let title = slot == Self.sidetoneSlot ? "SIDETONE_SETTING" : "SOMETHING_ELSE"
        let text = Array(title.utf8)
        try reply([0xD1, slot, 0x00, 0x01, UInt8(text.count)] + text + [0x00])
      case 0xD2:
        try reply([0xD3, slot, 0x00])
      case 0xD6:
        try reply([0xD7, slot, 0x00, sidetoneEnabled ? 0x00 : 0x01])
      case 0xD8:
        if honoursSets, bytes.count >= 4, bytes[2] == 0x00 { sidetoneEnabled = bytes[3] == 0x00 }
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

private func makeVerifiedCoordinator(
  declaring codes: [UInt8],
  honoursSets: Bool
) throws -> (SessionCoordinator, SidetoneDevice) {
  let (stream, continuation) = AsyncStream<Data>.makeStream()
  let channel = SidetoneDevice(inbound: continuation, honoursSets: honoursSets)
  let opener = ScriptedOpener { [channel] in
    OpenedChannel(channel: channel, inbound: stream, maximumTransmissionUnit: 512)
  }
  let profile = try #require(TandemVerifiedDeviceRegistry.profiles.first)
  let coordinator = SessionCoordinator(
    opener: opener,
    verifier: StubVerifier(outcome: .verified(profile, syntheticFingerprint(declaring: codes))),
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

// MARK: - Coordinator read-back tests

@Test func aSidetoneWriteTheDeviceHonoursSucceedsAndUpdatesTheReadings() async throws {
  let (coordinator, _) = try makeVerifiedCoordinator(declaring: [0xD1, 0xD2], honoursSets: true)
  await coordinator.handle(.defaultOutputChanged(DeviceIdentity("test-target")))
  #expect(await eventually { await coordinator.readings.sidetone != nil })
  #expect(await coordinator.readings.sidetone?.slot == .two)
  #expect(await coordinator.readings.sidetone?.isEnabled == false)

  try await coordinator.apply(sidetoneEnabled: true)
  #expect(await coordinator.readings.sidetone?.isEnabled == true)
  await coordinator.handle(.manualRelease)
}

@Test func aSidetoneWriteTheDeviceIgnoresIsReportedNotSwallowed() async throws {
  let (coordinator, _) = try makeVerifiedCoordinator(declaring: [0xD1, 0xD2], honoursSets: false)
  await coordinator.handle(.defaultOutputChanged(DeviceIdentity("test-target")))
  #expect(await eventually { await coordinator.readings.sidetone != nil })

  do {
    try await coordinator.apply(sidetoneEnabled: true)
    Issue.record("a write the device ignored was reported as success")
  } catch let failure as SessionCoordinator.WriteFailure {
    guard case .notAppliedSidetone(let held) = failure else {
      Issue.record("unexpected failure \(failure)")
      return
    }
    // The failure carries what the device actually holds.
    #expect(held.isEnabled == false)
  }
  await coordinator.handle(.manualRelease)
}

@Test func aSidetoneWriteWithoutAReadingIsUnsupported() async throws {
  // The device declares no general-setting slot, so no reading exists and the write
  // must refuse before anything reaches the wire.
  let (coordinator, _) = try makeVerifiedCoordinator(declaring: [], honoursSets: true)
  await coordinator.handle(.defaultOutputChanged(DeviceIdentity("test-target")))
  #expect(await eventually { await coordinator.phase == .ready })

  await #expect(throws: SessionCoordinator.WriteFailure.unsupported) {
    try await coordinator.apply(sidetoneEnabled: true)
  }
  await coordinator.handle(.manualRelease)
}
