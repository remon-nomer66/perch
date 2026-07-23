import Foundation
import Testing

@testable import TandemCore

private func frame(_ payload: [UInt8]) throws -> TandemFrame {
  try TandemFrame(
    dataType: TandemFrame.table1DataType,
    sequence: 0,
    payload: Data(payload)
  )
}

@Test func anUnknownCodecCodeStillParses() throws {
  // A future model's new codec is one display detail; refusing it would fail the
  // whole status read even though everything else in the answer is fine.
  let codec = try TandemReadOnlyStatus.parseAudioCodecResponse(
    try frame([0x13, 0x02, 0x42])
  )
  #expect(codec.rawValue == 0x42)
  #expect(!codec.isKnown)
  #expect(codec.description.contains("0x42"))
}

@Test func knownCodecCodesKeepTheirNames() {
  #expect(TandemAudioCodec.ldac.description == "LDAC")
  #expect(TandemAudioCodec.aptXHD.description == "aptX HD")
  #expect(TandemAudioCodec(rawValue: 0x02) == .aac)
  #expect(TandemAudioCodec.aac.isKnown)
}

@Test func aCodecAnswerOnTheWrongTableIsStillRefused() throws {
  // Tolerating unknown codec values must not loosen the framing checks around them.
  let table2 = try TandemFrame(
    dataType: TandemFrame.table2DataType,
    sequence: 0,
    payload: Data([0x13, 0x02, 0x10])
  )
  #expect(throws: TandemStatusError.unexpectedDataType(TandemFrame.table2DataType)) {
    _ = try TandemReadOnlyStatus.parseAudioCodecResponse(table2)
  }
  #expect(
    throws: TandemStatusError.unexpectedPayload(
      expected: [0x13, 0x02], actual: [0x13, 0x05]
    )
  ) {
    _ = try TandemReadOnlyStatus.parseAudioCodecResponse(try frame([0x13, 0x05, 0x10]))
  }
}

@Test func batteryAnswersOutsideTheDeclaredShapeAreRefused() throws {
  // A percentage past 100 cannot be a real reading.
  #expect(throws: TandemStatusError.invalidBatteryPercent(105)) {
    _ = try TandemReadOnlyStatus.parseEarbudBatteryResponse(
      try frame([0x23, 0x09, 105, 0, 59, 0, 100, 100])
    )
  }
  // A charging status byte outside the defined values.
  #expect(throws: TandemStatusError.invalidChargingStatus(9)) {
    _ = try TandemReadOnlyStatus.parseCaseBatteryResponse(
      try frame([0x23, 0x0A, 44, 9, 30])
    )
  }
  // One byte short of the declared shape.
  #expect(throws: TandemStatusError.invalidBatteryLength(expected: 8, actual: 7)) {
    _ = try TandemReadOnlyStatus.parseEarbudBatteryResponse(
      try frame([0x23, 0x09, 54, 0, 59, 0, 100])
    )
  }
}

@Test func aCurrentGenerationBatteryAnswerIsRefusedUnderTheLegacyDialect() throws {
  // The dialects answer with different command bytes; crossing them silently would
  // let one generation's layout be read as the other's.
  #expect(
    throws: TandemStatusError.unexpectedPayload(
      expected: [0x11, 0x01], actual: [0x23, 0x01]
    )
  ) {
    _ = try TandemReadOnlyStatus.parseBatteryResponse(
      try frame([0x23, 0x01, 54, 0, 59, 0]),
      query: .leftRight,
      dialect: .legacy
    )
  }
}
