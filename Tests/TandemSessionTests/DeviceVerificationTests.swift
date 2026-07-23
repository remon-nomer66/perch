import Foundation
import TandemCore
import Testing

@testable import TandemSession

/// Answers the handshake the way the older service generation does — short protocol
/// response, single-byte support codes. Throwing for table 2 proves the read never
/// asks that generation for it: in the live session an unanswered request is a
/// session fault, so the question must not be posed at all.
private struct OlderGenerationRequester: SessionRequesting {
  func request(
    _ build: @Sendable (UInt8) throws -> TandemFrame,
    matching: @Sendable @escaping (TandemFrame) -> Bool
  ) async throws -> TandemFrame {
    let sent = try build(0)
    if sent.dataType == TandemFrame.table2DataType {
      throw ChannelFailure.openTimedOut
    }
    let payload = [UInt8](sent.payload)
    func reply(_ bytes: [UInt8]) throws -> TandemFrame {
      try TandemFrame(
        dataType: TandemFrame.table1DataType,
        sequence: 1,
        payload: Data(bytes)
      )
    }
    switch payload.first {
    case 0x00:  // protocol info: the two-byte version, no flags
      return try reply([0x01, 0x00, 0x02, 0x01])
    case 0x02:  // capability: code 6, empty identifier
      return try reply([0x03, 0x00, 0x06, 0x00])
    case 0x04:  // device info, echoing the asked-for field
      let value = Array("X".utf8)
      return try reply([0x05, payload[1], UInt8(value.count)] + value)
    case 0x06:  // support functions: two codes, no versions
      return try reply([0x07, 0x00, 0x02, 0x11, 0x22])
    default:
      throw ChannelFailure.openTimedOut
    }
  }
}

@Test func fingerprintReadNeverAsksTheOlderGenerationForTable2() async throws {
  let fingerprint = try await DeviceVerification().readFingerprint(
    over: OlderGenerationRequester()
  )
  #expect(fingerprint.protocolIdentifier == 0x0201)
  #expect(fingerprint.table1Functions.map(\.code) == [0x11, 0x22])
  #expect(fingerprint.table2Functions.isEmpty)
}
