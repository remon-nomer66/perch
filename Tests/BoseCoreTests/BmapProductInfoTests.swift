import Foundation
import Testing

@testable import BoseCore

@Test func initializeRequestMatchesCapturedBytes() throws {
  // QC35 connect ping [0.1] GET = 00 01 01 00.
  #expect(try BmapProductInfo.initializeRequest().encoded() == Data([0x00, 0x01, 0x01, 0x00]))
}

@Test func firmwareRequestIsGetTo05() throws {
  #expect(try BmapProductInfo.firmwareRequest().encoded() == Data([0x00, 0x05, 0x01, 0x00]))
}

@Test func deviceNameRequestIsGetTo12() throws {
  #expect(try BmapProductInfo.deviceNameRequest().encoded() == Data([0x01, 0x02, 0x01, 0x00]))
}

@Test func firmwareParsesAsciiPayload() throws {
  // A firmware version string is not PII; this is the '+g<hash>' form the parser must
  // pass through unchanged.
  let version = Array("8.2.20+g34cf029".utf8)
  let frame = try BmapFrame(fblock: 0, function: 5, op: .status, payload: Data(version))
  #expect(try BmapProductInfo.parseFirmware(frame) == "8.2.20+g34cf029")
}

@Test func deviceNameParsesPayloadAfterFlag() throws {
  // Synthetic model name; byte 0 is the flag, the remainder is UTF-8.
  let name = Array("Model X".utf8)
  let frame = try BmapFrame(fblock: 1, function: 2, op: .status, payload: Data([0x00] + name))
  #expect(try BmapProductInfo.parseDeviceName(frame) == "Model X")
}

@Test func firmwareRejectsEmptyPayload() throws {
  let frame = try BmapFrame(fblock: 0, function: 5, op: .status, payload: Data())
  #expect(throws: BmapProductInfoError.emptyPayload) {
    _ = try BmapProductInfo.parseFirmware(frame)
  }
}

@Test func firmwareRejectsWrongAddress() throws {
  let frame = try BmapFrame(fblock: 1, function: 2, op: .status, payload: Data([0x31]))
  #expect(throws: BmapProductInfoError.unexpectedAddress(fblock: 1, function: 2)) {
    _ = try BmapProductInfo.parseFirmware(frame)
  }
}
