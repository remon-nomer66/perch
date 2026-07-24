import Foundation
import Testing

@testable import BoseCore

@Test func equalizerParsesCapturedThreeBands() throws {
  // Capture f60a0000 f60afe01 f60afa02 -> Bass 0, Mid -2, Treble -6, range -10...+10.
  let payload = Data([
    0xf6, 0x0a, 0x00, 0x00,
    0xf6, 0x0a, 0xfe, 0x01,
    0xf6, 0x0a, 0xfa, 0x02,
  ])
  let frame = try BmapFrame(fblock: 1, function: 7, op: .status, payload: payload)
  let bands = try BmapEqualizer.parseBands(frame)
  #expect(bands == [
    BmapEqualizerBand(bandId: 0, minimum: -10, maximum: 10, current: 0),
    BmapEqualizerBand(bandId: 1, minimum: -10, maximum: 10, current: -2),
    BmapEqualizerBand(bandId: 2, minimum: -10, maximum: 10, current: -6),
  ])
}

@Test func equalizerReadRequestIsGetTo17() throws {
  #expect(try BmapEqualizer.readRequest().encoded() == Data([0x01, 0x07, 0x01, 0x00]))
}

@Test func equalizerSetRequestMatchesCapturedValues() throws {
  // The two-byte [value & 0xFF, band_id] writes that reproduce the captured values.
  #expect([UInt8](try BmapEqualizer.setRequest(bandId: 0, value: 0).payload) == [0x00, 0x00])
  #expect([UInt8](try BmapEqualizer.setRequest(bandId: 1, value: -2).payload) == [0xFE, 0x01])
  #expect([UInt8](try BmapEqualizer.setRequest(bandId: 2, value: -6).payload) == [0xFA, 0x02])
  // A whole write frame for Mid -2: fblock 1, func 7, SETGET, len 2.
  #expect(
    try BmapEqualizer.setRequest(bandId: 1, value: -2).encoded()
      == Data([0x01, 0x07, 0x02, 0x02, 0xFE, 0x01])
  )
}

@Test func equalizerSetRequestsMakeOneFramePerBand() throws {
  let frames = try BmapEqualizer.setRequests([
    (bandId: 0, value: 0),
    (bandId: 1, value: -2),
    (bandId: 2, value: -6),
  ])
  #expect(frames.count == 3)
  #expect([UInt8](frames[2].payload) == [0xFA, 0x02])
}

@Test func equalizerRejectsValueOutsideDeclaredRange() {
  #expect(throws: BmapEqualizerError.self) {
    _ = try BmapEqualizer.setRequest(bandId: 0, value: 11, range: -10...10)
  }
}

@Test func equalizerRejectsMalformedBandPayload() throws {
  let frame = try BmapFrame(fblock: 1, function: 7, op: .status, payload: Data([0xf6, 0x0a, 0x00]))
  #expect(throws: BmapEqualizerError.malformedBandGroups(3)) {
    _ = try BmapEqualizer.parseBands(frame)
  }
}

@Test func equalizerRejectsEmptyPayload() throws {
  let frame = try BmapFrame(fblock: 1, function: 7, op: .status, payload: Data())
  #expect(throws: BmapEqualizerError.emptyPayload) {
    _ = try BmapEqualizer.parseBands(frame)
  }
}
