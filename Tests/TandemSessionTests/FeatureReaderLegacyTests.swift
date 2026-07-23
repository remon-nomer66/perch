import Foundation
import TandemCore
import Testing

@testable import TandemSession

/// Answers the way a WF-1000XM3-era device does: old battery and codec commands,
/// the NC/ASM conversation on its fixed type byte, the equaliser on inquiry 0x01,
/// and silence for everything else. Which path — probe or request — each message
/// took is recorded, because the two differ in what a timeout costs the session.
private final class LegacyDeviceRequester: SessionRequesting, @unchecked Sendable {
  private let lock = NSLock()
  private var probed: [[UInt8]] = []
  private var requested: [[UInt8]] = []
  /// True for earbuds, which answer the dual battery query; a headband answers the
  /// single one instead and leaves the dual query hanging.
  private let answersDualBattery: Bool

  init(answersDualBattery: Bool = true) {
    self.answersDualBattery = answersDualBattery
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
    func reply(_ bytes: [UInt8]) throws -> TandemFrame {
      try TandemFrame(
        dataType: TandemFrame.table1DataType,
        sequence: 1,
        payload: Data(bytes)
      )
    }
    switch (payload.first, payload.count > 1 ? payload[1] : 0xFF) {
    case (0x10, 0x00) where !answersDualBattery: return try reply([0x11, 0x00, 0x5A, 0x00])
    case (0x10, 0x01) where answersDualBattery:
      return try reply([0x11, 0x01, 0x50, 0x00, 0x46, 0x01])
    case (0x10, 0x02) where answersDualBattery: return try reply([0x11, 0x02, 0x64, 0x00])
    case (0x18, 0x00): return try reply([0x19, 0x00, 0x02])
    case (0x66, 0x02): return try reply([0x67, 0x02, 0x01, 0x02, 0x00, 0x01, 0x01, 0x14])
    case (0x56, 0x01): return try reply([0x57, 0x01, 0xA1, 0x06, 0x0A, 0x0C, 0x0A, 0x08, 0x0A, 0x0A])
    default: throw ChannelFailure.openTimedOut
    }
  }
}

/// The legacy table declares bare get-command codes.
private func declared(_ codes: [UInt8]) -> [TandemSupportFunction] {
  codes.map { TandemSupportFunction(code: $0, version: 0) }
}

@Test func theLegacyDialectReadsBatteryCodecNoiseAndEqualizer() async throws {
  let readings = await FeatureReader().read(
    declaring: declared([0x10, 0x18, 0x66, 0x56]),
    dialect: .legacy,
    over: LegacyDeviceRequester()
  )

  #expect(readings.leftBattery == 80)
  #expect(readings.rightBattery == 70)
  #expect(readings.caseBattery == 100)
  #expect(readings.codec == .aac)

  let noise = try #require(readings.noiseControl)
  #expect(noise.inquiry == TandemNoiseControlProtocol.legacyInquiry)
  #expect(noise.state.isActive)
  #expect(!noise.state.isNoiseCancelling)
  #expect(noise.state.ambientLevel == 20)
  #expect(noise.supportsVoiceFocus)
  #expect(noise.hasAdjustableLevel)
  #expect(noise.legacyWindKind == 2)

  let equalizer = try #require(readings.equalizer)
  #expect(equalizer.selectedPreset == 0xA1)
  #expect(equalizer.bandSteps == [10, 12, 10, 8, 10, 10])
  #expect(equalizer.flatStep == 10)
  #expect(equalizer.presets.contains { $0.identifier == 0xA1 })
}

@Test func theLegacyReaderOnlyAsksWhatTheDeviceDeclared() async {
  // Only the battery command is declared. Asking about the others regardless was
  // not harmless: an unanswered request times out and tears down the session, once
  // per poll cycle, for every function the device does not have.
  let requester = LegacyDeviceRequester()
  let readings = await FeatureReader().read(
    declaring: declared([0x10]),
    dialect: .legacy,
    over: requester
  )

  #expect(readings.leftBattery == 80)
  #expect(readings.codec == nil)
  #expect(readings.noiseControl == nil)
  #expect(readings.equalizer == nil)

  let sent = requester.probedPayloads + requester.requestedPayloads
  #expect(!sent.contains { $0.first == 0x18 }, "the codec was asked without being declared")
  #expect(!sent.contains { $0.first == 0x66 }, "noise control was asked without being declared")
  #expect(!sent.contains { $0.first == 0x56 }, "the equaliser was asked without being declared")
}

@Test func theLegacyBatteryShapeQueriesRideTheProbePath() async {
  // The declaration cannot say whether the device is earbuds or a headband — both
  // ride command 0x10 — so the shape detection expects one of its queries to go
  // unanswered. Those must be probes: a request's timeout faults the session.
  let requester = LegacyDeviceRequester()
  _ = await FeatureReader().read(
    declaring: declared([0x10, 0x18]),
    dialect: .legacy,
    over: requester
  )

  #expect(requester.probedPayloads.contains { $0.first == 0x10 })
  #expect(
    !requester.requestedPayloads.contains { $0.first == 0x10 },
    "a battery shape query went out as a faulting request"
  )
  // The codec is a declared conversation with exactly one shape, so it stays a
  // plain request.
  #expect(requester.requestedPayloads.contains { $0.first == 0x18 })
}

@Test func aLegacyHeadbandFallsBackToTheSingleBatteryQuery() async {
  // The dual query goes unanswered, so the reader concludes the device is a
  // headband, asks the single query, and never asks about a charging case.
  let requester = LegacyDeviceRequester(answersDualBattery: false)
  let readings = await FeatureReader().read(
    declaring: declared([0x10]),
    dialect: .legacy,
    over: requester
  )

  #expect(readings.singleBattery == 90)
  #expect(readings.leftBattery == nil)
  #expect(readings.rightBattery == nil)
  #expect(readings.caseBattery == nil)
  #expect(
    !requester.probedPayloads.contains([0x10, 0x02]),
    "a headband was asked about a charging case"
  )
}
